# 시나리오 2-06-2: prefill의 CUDA graph 끄기(`--enforce-eager`)

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd` prefill pod
**상태:** 실행 완료(2026-11-12~13)

## 목적

CUDA graph는 같은 연산을 반복하는 decode(토큰 단위 생성)에서 CPU 오버헤드를 줄인다. 큰 덩어리를 한 번에 계산하는 prefill은
이득이 작은데도 graph 메모리(약 1.19GiB)와 `torch.compile` 시간(약 69초)을 쓴다. prefill에 `--enforce-eager`를 주어
메모리와 기동 시간을 회수하고, prefill 속도 손실이 없는지 확인한다.

## 조건

| 단계 | prefill | decode |
|---|---|---|
| 기준 | 기본(CUDA graph 사용) | 기본 |
| E1 | `--enforce-eager` | 기본 |

```sh
oc edit llminferenceservice qwen38-int4-pd -n llmd-pd
# spec.prefill.template.containers[0].env VLLM_ADDITIONAL_ARGS: ... --enforce-eager
oc logs -n llmd-pd -l llm-d.ai/role=prefill -c main | grep -E 'enforce_eager|CUDA graph memory|torch.compile took|Available KV cache memory'
```

## 측정

| 항목 | 기준 | E1 기대 |
|---|---|---|
| prefill CUDA graph 메모리 | 1.19GiB | 0 |
| prefill KV 용량 | 7.64GiB | 약 8.8GiB(graph 메모리만큼 증가) |
| prefill 기동 시간(`torch.compile`) | 약 69초 | 0 |
| L2 TTFT p50(동시 1) | 7.19초(2-03) | ±5% 이내 |

## 판정 기준

- E1에서 prefill의 CUDA graph 메모리와 컴파일 시간이 사라진다.
- L2 TTFT 차이가 5% 이내이면 prefill에는 `--enforce-eager`를 권장한다.

## 결과

| 항목 | 기준 | E1 |
|---|---|---|
| prefill CUDA graph 메모리 | 1.26GiB(실측) | 0 |
| prefill KV | 7.64GiB, 373,321토큰 | 9.83GiB, 479,817토큰(+2.19GiB) |
| prefill GPU 사용 | 18,860MiB | 19,580MiB |
| prefill 엔진 초기화 | 145.8초(컴파일 70.9초) | 64.1초 |
| L2 동시 1 TTFT p50 | 6.56초 | 7.58초(+15.5%) |
| L2 동시 4+ 출력 tok/s | 19.2 | 14.9(−22%) |
| L1 동시 16 TTFT p50, 출력 tok/s | 10.40초, 136.5 | 15.01초, 119.5(−12%) |
| preemption, NIXL 실패 | 0, 0 | 0, 0 |

2-06-5(C1)도 E1과 같은 지연을 보였다. 같은 세션 기준 대비 L2 TTFT +4.7%, L2 처리량 −13%이다.

## 결론

- `--enforce-eager`는 CUDA graph 메모리와 컴파일 시간을 없앴다. 기동은 145초에서 64초로 줄었다.
- 회수한 메모리는 OOM 여유가 아니라 KV로 간다. util이 그대로이기 때문이다. GPU 사용량은 오히려 늘었다.
- prefill 속도가 떨어졌다. L2 TTFT는 5~15% 늘고 처리량은 13~22% 줄었다. 판정 기준(5% 이내)을 넘는다.
- 따라서 prefill에 `--enforce-eager`를 권장하지 않는다. 기동 시간 단축이 처리량보다 중요한 경우에만 쓴다.
