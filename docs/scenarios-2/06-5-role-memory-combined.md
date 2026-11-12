# 시나리오 2-06-5: 역할별 메모리 설정 통합

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd`(prefill TP2 + decode TP2, L4 24GB)
**상태:** 실행 완료(2026-11-12~13)

## 목적

2-06-1~2-06-4의 방안을 한 구성으로 묶어, 기준 구성 대비 OOM 여유·KV 용량·지연이 함께 개선되는지 확인한다. 결과는 L4에서
P/D를 운영할 때의 역할별 권장 설정이 된다.

## 구성

| 항목 | 기준 | 통합(C1) |
|---|---|---|
| prefill util | 0.85 | **0.75** (2-06-1) |
| prefill CUDA graph | 사용 | **`--enforce-eager`** (2-06-2) |
| prefill `--max-num-batched-tokens` | 기본값 | **2048** (2-06-3) |
| prefill `--max-num-seqs` | 64 | **8** (2-06-4) |
| decode util | 0.85 | **0.90** (2-06-1) |
| decode 그 밖 | 기본 | 기본 |

```sh
oc edit llminferenceservice qwen38-int4-pd -n llmd-pd
# prefill: --gpu-memory-utilization=0.75 --enforce-eager --max-num-batched-tokens=2048 --max-num-seqs=8
# decode : --gpu-memory-utilization=0.90
oc get llminferenceservice qwen38-int4-pd -n llmd-pd -o jsonpath='{.metadata.generation} {.status.observedGeneration}'
```

두 역할의 인자를 한 번에 바꾸어 재기동은 1회로 한다(P/D pod는 같은 노드에 고정되어 있어 두 역할을 0으로 내렸다 올린다).

## 측정

| 항목 | 기준 | C1 기대 |
|---|---|---|
| 기동 | 성공 | 성공, OOM 없음 |
| prefill vLLM 밖 여유 | 3.37GiB | 약 5.6GiB |
| decode KV 토큰 | 373K | 약 428K(+15%) |
| L1 동시 16: TTFT p50·ITL p50·처리량 | 13.3초·46.0ms·128 tok/s(2-03) | 처리량 유지 |
| L2 동시 1: TTFT p50 | 7.19초(2-03) | ±5% |
| preemption, NIXL 실패 | 0 | 0 |

## 판정 기준

- 기동과 L1·L2 부하에서 OOM·재기동·NIXL 실패가 없다.
- decode KV 용량이 늘고, prefill의 vLLM 밖 여유가 늘어난다.
- L1·L2의 지연·처리량이 기준 대비 5% 이내이다. 이 경우 C1을 L4 P/D의 권장 설정으로 정한다.

## 원복

기준 인자([manifests/pd/qwen38-int4-pd.yaml](../../manifests/pd/qwen38-int4-pd.yaml))로 되돌린다.

## 결과

기준은 같은 세션의 2-06-3 B1(기본값과 동일한 구성)이다.

| 항목 | 기준 | C1 |
|---|---|---|
| 기동 | 성공 | 성공(541초), OOM 없음 |
| prefill KV | 7.64GiB, 373,321토큰 | 7.63GiB, 372,150토큰 |
| prefill GPU 사용 | 18,792MiB | 17,058MiB(−1,734MiB) |
| prefill 엔진 초기화 | 145초 | 64초 |
| decode KV | 373,321토큰 | 427,154토큰(+14.4%) |
| decode GPU 사용 | 18,790MiB | 19,910MiB |
| L1 동시 16 TTFT p50, ITL p50, 출력 tok/s | 13.37초, 45.8ms, 128.0 | 15.01초, 46.7ms, 119.5(−6.6%) |
| L2 동시 1 TTFT p50 | 7.24초 | 7.58초(+4.7%) |
| L2 동시 4+ 출력 tok/s | 17.1 | 14.9(−13%) |
| preemption, NIXL 실패 | 0, 0 | 0, 0 |

## 결론

- C1은 OOM 없이 기동했다. decode KV가 14.4% 늘고, prefill의 vLLM 밖 여유가 약 1.7GiB 늘었다.
- 지연 기준(5% 이내)은 충족하지 못했다. L1 처리량 −6.6%, L2 처리량 −13%이다.
- 손실의 원인은 `--enforce-eager`이다. C1의 부하 수치는 2-06-2 E1과 같다.
- 권장 구성은 C1에서 `--enforce-eager`를 뺀 것이다(prefill util 0.75 + `--max-num-seqs=8`, decode util 0.90). 2-06-1과 2-06-4가 각각 손실 없음을 보였으나, 이 조합 자체는 실행하지 않았다.
