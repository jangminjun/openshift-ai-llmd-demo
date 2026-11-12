# 시나리오 2-06: P/D 역할별 GPU 메모리 설정과 OOM 회피

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd`(INT4, prefill TP2 + decode TP2, L4 24GB), 부하 생성기 GuideLLM(시나리오 2-01)
**상태:** 실행 완료(2026-11-12~13). 하위 시나리오 2-06-1~2-06-6

## 목적

`--gpu-memory-utilization`(이하 util)은 vLLM이 GPU 메모리 중 쓸 수 있는 비율이다. 가중치·활성화·CUDA graph를 뺀 나머지가
KV cache가 된다. 통합 구성에서는 하나의 util로 활성화 여유와 KV 용량을 절충해야 하지만, P/D 구성에서는 prefill과 decode가
메모리를 쓰는 방식이 다르므로 역할마다 다른 설정을 줄 수 있다. 본 시나리오는 역할별 설정으로 OOM 여유와 KV 용량을 함께
얻을 수 있는지 측정한다.

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

## 역할별 메모리 성격

| | prefill pod | decode pod |
|---|---|---|
| 하는 일 | 긴 프롬프트를 한 번에 계산 | 여러 요청의 토큰을 하나씩 생성 |
| 활성화 메모리 | 큼(프롬프트 길이 × 청크 크기) | 작음(요청당 토큰 1개) |
| KV cache 필요량 | 작음(decode가 가져갈 때까지만 보관) | 큼(동시 대화 수 × 문맥 길이) |
| CUDA graph 효과 | 작음(큰 덩어리 계산) | 큼(토큰 단위 반복 실행) |
| 메모리 부족 시 | 활성화 피크에서 OOM | KV 부족 시 OOM 대신 preemption·대기 |

NIXL·UCX가 KV 전송용으로 등록하는 메모리는 vLLM 예산(util) 밖에서 잡힌다. 따라서 P/D는 util을 높일수록 통합 구성보다
OOM 위험이 크다.

## 하위 시나리오

| # | 방안 | 대상 | 변경 | 문서 |
|---|---|---|---|---|
| 2-06-1 | 역할별 util | prefill·decode | prefill 0.75, decode 0.90(한계 확인 0.95) | [06-1](06-1-role-memory-utilization.md) |
| 2-06-2 | prefill CUDA graph 끄기 | prefill | `--enforce-eager` | [06-2](06-2-prefill-enforce-eager.md) |
| 2-06-3 | prefill 배치 토큰 축소 | prefill | `--max-num-batched-tokens=2048` | [06-3](06-3-prefill-batched-tokens.md) |
| 2-06-4 | prefill 동시 요청 축소 | prefill | `--max-num-seqs=8` | [06-4](06-4-prefill-max-num-seqs.md) |
| 2-06-5 | 통합 | prefill·decode | 2-06-1~4를 모두 적용 | [06-5](06-5-role-memory-combined.md) |
| 2-06-6 | EPP Flow Control로 KV 포화 회피 | decode·EPP | decode util 0.75 + `concurrency-detector` | [06-6](06-6-epp-flow-control.md) |

기준(baseline)은 현재 운영값(두 역할 모두 util 0.85, 그 밖의 값은 기본)이다. 각 단계는 해당 역할만 재기동하며, 부하는
2-03의 L1(2,000/256)·L2(8,000/128)를 쓴다.

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

## 공통 측정

```sh
oc logs -n llmd-pd -l llm-d.ai/role=prefill -c main | grep -E 'Model loading took|Available KV cache memory|GPU KV cache size|CUDA graph memory|torch.compile took|out of memory'
oc logs -n llmd-pd -l llm-d.ai/role=decode  -c main | grep -E 'Available KV cache memory|GPU KV cache size|CUDA graph memory|out of memory'
oc get pods -n llmd-pd -l 'llm-d.ai/role in (prefill,decode)'      # OOM이면 CrashLoopBackOff, RESTARTS 증가
cd openshift-ai-llmd-demo/harness && HARNESS_PROFILE=sno ./harness.sh scenario2-06-memory   # 설정별 재기동 + L1·L2 부하
# 일부만: S26_CONFIGS="base r1" ./harness.sh scenario2-06-memory
```

## 결과 요약

모든 구성이 OOM·재기동 없이 기동했다. L1·L2 부하에서 preemption과 NIXL 실패는 0이었다.

| # | 구성 | 메모리 변화 | 지연·처리량 | 판정 |
|---|---|---|---|---|
| 2-06-1 R1 | prefill 0.75, decode 0.90 | decode KV +14.4%, prefill GPU −2.9GiB | 변화 없음 | 권장 |
| 2-06-1 R2 | decode 0.95 | decode KV +28.8%, 남은 GPU 약 2.0GiB | 변화 없음 | 한계 확인만 |
| 2-06-2 E1 | prefill `--enforce-eager` | prefill graph 0, KV +2.19GiB, 기동 145→64초 | L2 처리량 −13~22% | 비권장 |
| 2-06-3 B1 | prefill 배치 토큰 2048 | 변화 없음(기본값과 같음) | 변화 없음 | 효과 없음 |
| 2-06-4 S1 | prefill `--max-num-seqs=8` | prefill graph −0.68GiB, KV +7.2% | 변화 없음 | 권장 |
| 2-06-5 C1 | 1~4 통합 | decode KV +14.4%, prefill GPU −1.7GiB | L2 처리량 −13%(eager 때문) | eager 제외 시 권장 |
| 2-06-6 F2 | decode 0.75 + Flow Control(16) | decode KV −29% | 장문 부하에서 preemption 83→0, 처리량 +76% | 권장(장문 부하) |

**실행 세션 간 편차.** 같은 기본 구성의 L1 동시 16 TTFT p50이 10.4초(11-12)와 13.4초(11-13)로 달랐다. 따라서 각 구성은 같은 세션의 기준과만 비교한다.

## 결론

- L4 P/D의 권장 설정: prefill util 0.75 + `--max-num-seqs=8`, decode util 0.90. 이 조합 자체는 미실행이다.
- 장문 출력이 decode KV를 채우는 부하에서는 decode util을 올리기보다 Flow Control로 입장 수를 제한한다(2-06-6).
- prefill `--enforce-eager`는 기동 시간만 줄이고 처리량을 떨어뜨린다.
- L4에서 `--max-num-batched-tokens` 기본값은 이미 2048이다.

결과 로그는 `harness/results/scenario2-06/`(git 제외)에 있다.
