# 시나리오 2-06: `--gpu-memory-utilization`과 OOM 구간 관측

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd`(INT4, prefill TP2 + decode TP2, L4 24GB), 부하 생성기 GuideLLM(시나리오 2-01)
**상태:** 설계, 미실행

## 목적

`--gpu-memory-utilization`(이하 util)은 vLLM이 GPU 메모리 중 쓸 수 있는 비율이다. 가중치·활성화·CUDA graph를 뺀 나머지가
KV cache가 된다. util을 높이면 KV 용량(동시 처리량)이 늘지만 vLLM 밖에 남는 메모리가 줄어 OOM 위험이 커지고, 낮추면 KV가
부족해 부하 시 preemption과 대기가 생긴다. util을 0.95 → 0.85 → 0.80 → 0.75로 바꾸며 기동 성공 여부, KV 용량, 부하 시
거동을 Grafana의 구간(행)별로 관측하여 L4에서의 운영 범위를 정한다.

## 메모리 배분 (실측 기준)

util 0.85의 decode TP0 기동 로그(GPU 1장 22.49GiB):

| 항목 | 크기 | 근거 |
|---|---|---|
| vLLM 한도 = util × 22.49GiB | 19.12GiB | `nvidia.com/gpu.memory=23034MiB` |
| 가중치(INT4, TP2 분할) | 8.51GiB | `Model loading took 8.51 GiB` |
| CUDA graph | 1.19GiB | `Estimated CUDA graph memory: 1.19 GiB` |
| KV cache | 7.64GiB(373,321토큰) | `Available KV cache memory: 7.64 GiB` |
| 활성화 등(역산) | 약 1.78GiB | 한도 − 위 세 항목 |
| vLLM 밖 여유 | 3.37GiB | CUDA 컨텍스트, NCCL, NIXL·UCX 등록 메모리, 단편화 |

같은 구성으로 각 util의 KV 용량과 vLLM 밖 여유를 추정한다(가중치·graph·활성화 11.48GiB 고정, 1GiB ≈ 48,860토큰).

| util | vLLM 한도 | KV 추정 | KV 토큰 추정 | vLLM 밖 여유 | 예상 |
|---|---|---|---|---|---|
| 0.95 | 21.37GiB | 9.89GiB | 약 483K | **1.12GiB** | 기동 또는 부하 중 OOM 위험 |
| 0.85 | 19.12GiB | 7.64GiB | 373K(실측) | 3.37GiB | 현재 운영값 |
| 0.80 | 17.99GiB | 6.51GiB | 약 318K | 4.50GiB | 정상 |
| 0.75 | 16.87GiB | 5.39GiB | 약 263K | 5.62GiB | 부하 시 KV 부족, preemption |

## 실험 설계

prefill과 decode에 같은 util을 지정한다(KV 용량이 다르면 P/D 병목이 섞인다). 단계마다 다음을 반복한다.

1. **변경:** 두 역할을 0으로 내리고 `VLLM_ADDITIONAL_ARGS`의 util을 바꾼 뒤 1로 올린다(같은 노드에 여유 GPU가 없음).
2. **기동 관측:** 성공·OOM 여부, 기동 로그의 KV 용량, OOM이면 발생 시점(가중치 적재, `torch.compile`, CUDA graph 캡처,
   NIXL 등록, 첫 요청).
3. **부하 관측:** 기동에 성공한 단계만 GuideLLM으로 부하를 준다. 프롬프트 8,000 / 응답 256토큰, 동시 8·16·32·48,
   단계별 60초, MaaS 경로. 동시 32에서 필요한 KV(약 264K 토큰)가 util 0.75의 추정 용량과 비슷하도록 정했다.
4. **원복:** util 0.85.

```sh
NS=llmd-pd; N=qwen38-int4-pd; U=0.80
oc patch llminferenceservice $N -n $NS --type=merge -p '{"spec":{"replicas":0,"prefill":{"replicas":0}}}'
sed "s/--gpu-memory-utilization=0.85/--gpu-memory-utilization=$U/" manifests/pd/qwen38-int4-pd.yaml | oc apply -f -
oc get llminferenceservice $N -n $NS -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.conditions[?(@.type=="Ready")].status}'
oc logs -n $NS -l llm-d.ai/role=decode -c main | grep -E 'Available KV cache memory|GPU KV cache size|out of memory|OutOfMemory'
oc get pods -n $NS -l 'llm-d.ai/role in (prefill,decode)'          # OOM이면 CrashLoopBackOff, RESTARTS 증가

cd harness && HARNESS_PROFILE=sno LLMD_NAMESPACE=$NS LLMD_NAME=$N GUIDELLM_VIA=maas \
  GUIDELLM_STREAMS=8,16,32,48 GUIDELLM_PROMPT_TOKENS=8000 GUIDELLM_OUTPUT_TOKENS=256 ./harness.sh guidellm
```

## 구간별 Grafana 관측 (`llmd-pd-latency`)

단계마다 같은 시간 범위로 대시보드를 캡처한다.

| 구간(행) | 패널 | 보는 것 |
|---|---|---|
| 0. Overview | TTFT p95, ITL p95, Request throughput, EPP error rate | util별 지연·처리량의 최종 결과 |
| ② Prefill compute | Prefill KV cache usage, Prefill requests waiting / running, Prefill queue wait | prefill 쪽 KV 포화 여부 |
| ③ KV cache transfer | NIXL transfer time, NIXL failures / expirations | KV 부족 시 전송 지연·실패 |
| ④ Decode scheduling & compute | **Decode KV cache usage**, **Preemption rate**, Decode requests waiting / running, Inter-Token Latency (ITL) | KV 부족의 직접 신호. 사용률 100% 도달 후 preemption과 대기가 늘어남 |
| ⑤ Errors & failures | Disagg sidecar errors by stage, EPP errors by code | OOM·재기동 중 요청 실패 |

**대시보드에 없는 지표(추가 필요).** GPU 메모리 사용량과 재기동은 현재 패널이 없다. OOM 판정을 위해 다음을 추가하거나
콘솔 Observe → Metrics로 조회한다.

```
sum by (exported_pod, gpu) (DCGM_FI_DEV_FB_USED{exported_namespace="llmd-pd"})        # GPU 메모리 사용량(MiB)
sum by (exported_pod, gpu) (DCGM_FI_DEV_FB_FREE{exported_namespace="llmd-pd"})        # 남은 메모리
increase(kube_pod_container_status_restarts_total{namespace="llmd-pd", container="main"}[10m])
```

## 판정 기준

- 기동: 단계별 성공 여부와 OOM 발생 시점(로그)을 기록한다. 0.95에서 실패하면 그 시점의 GPU 메모리 사용량을 함께 남긴다.
- KV 용량: 기동 로그의 KV 토큰 수가 위 추정과 10% 이내로 맞는지 확인한다.
- 부하: Decode KV 캐시 사용률이 100%에 도달하는 동시성, 그때의 preemption 발생률, TTFT·ITL 증가 폭을 util별로 비교한다.
- 운영 범위: OOM 없이 기동하고 동시 32에서 preemption이 없는 가장 높은 util을 권장값으로 정한다.

## 예상

- 0.95: vLLM 밖 여유가 약 1.1GiB로, NIXL·UCX 등록 메모리와 NCCL 버퍼를 더하면 CUDA graph 캡처나 첫 KV 전송 때 OOM이 날 수 있다.
- 0.75: 동시 32 이상에서 Decode KV 캐시 사용률이 100%에 닿고 preemption이 생겨 TTFT가 급증한다.
- 0.80~0.85가 L4에서 안전한 범위일 것으로 예상한다.
