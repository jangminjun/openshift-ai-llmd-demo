# 시나리오 2-06-1: 역할별 `gpu-memory-utilization`

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd`(prefill TP2 + decode TP2, L4 24GB)
**상태:** 실행 완료(2026-11-12~13)

## 목적

prefill은 KV cache를 잠시만 보관하고 활성화 메모리가 크며, decode는 KV cache가 처리량을 정한다. 두 역할에 같은 util(0.85)을
주는 대신 prefill은 낮추고 decode는 높여, prefill의 OOM 여유와 decode의 KV 용량을 함께 늘릴 수 있는지 확인한다.

## 조건

| 단계 | prefill util | decode util | 의도 |
|---|---|---|---|
| 기준 | 0.85 | 0.85 | 현재 운영값 |
| R1 | 0.75 | 0.90 | 역할별 배분 |
| R2(한계) | 0.75 | 0.95 | decode util의 상한(vLLM 밖 여유 약 1.1GiB) |

GPU 1장 22.49GiB 기준 추정(가중치·graph·활성화 11.48GiB 고정, 1GiB ≈ 48,860토큰):

| util | vLLM 한도 | KV 추정 | KV 토큰 추정 | vLLM 밖 여유 |
|---|---|---|---|---|
| 0.75 | 16.87GiB | 5.39GiB | 약 263K | 5.62GiB |
| 0.85 | 19.12GiB | 7.64GiB | 373K(실측) | 3.37GiB |
| 0.90 | 20.24GiB | 8.76GiB | 약 428K | 2.25GiB |
| 0.95 | 21.37GiB | 9.89GiB | 약 483K | 1.12GiB |

```sh
oc edit llminferenceservice qwen38-int4-pd -n llmd-pd
# spec.prefill.template.containers[0].env VLLM_ADDITIONAL_ARGS: --gpu-memory-utilization=0.75
# spec.template.containers[0].env        VLLM_ADDITIONAL_ARGS: --gpu-memory-utilization=0.90
oc logs -n llmd-pd -l llm-d.ai/role=decode -c main | grep -E 'Available KV cache memory|GPU KV cache size|out of memory'
```

## 측정

| 항목 | 출처 |
|---|---|
| 기동 성공·OOM 시점 | pod 상태, vLLM 로그 |
| 역할별 KV 용량 | `Available KV cache memory`, `GPU KV cache size` |
| GPU 메모리 사용량 | `DCGM_FI_DEV_FB_USED` |
| 부하 시 TTFT·ITL·preemption | 2-03 L1·L2, `vllm:num_preemptions_total` |

## 판정 기준

- R1이 OOM 없이 기동하고, decode KV 토큰이 기준보다 약 15% 늘어난다.
- R1의 L2(prefill 집약)에서 prefill OOM·재기동이 없다.
- R2는 기동 성공 여부와 실패 시점을 기록하여 decode util의 상한을 정한다.

## 결과

기동(2026-11-12). 세 단계 모두 OOM·재기동이 없었다.

| 단계 | prefill KV | decode KV | GPU 사용(prefill / decode) |
|---|---|---|---|
| 기준 | 7.64GiB, 373,321토큰 | 7.64GiB, 373,321토큰 | 18,860 / 18,794MiB |
| R1 | 5.44GiB, 265,654토큰 | 8.74GiB, 427,154토큰(+14.4%) | 15,944 / 19,910MiB |
| R2 | 5.44GiB, 265,654토큰 | 9.84GiB, 480,987토큰(+28.8%) | 16,518 / 21,030MiB |

KV 토큰은 추정치(428K, 483K)와 1% 이내로 일치했다. R2 decode의 남은 GPU 메모리는 약 2.0GiB(23,034 − 21,030MiB)이다.

부하(2-03 L1·L2, 같은 세션):

| 단계 | L1 동시 16 TTFT p50 | L1 ITL p50 | L1 출력 tok/s | L2 동시 1 TTFT p50 | L2 동시 4+ 출력 tok/s | preemption |
|---|---|---|---|---|---|---|
| 기준 | 10.40초 | 51.5ms | 136.5 | 6.56초 | 19.2 | 0 |
| R1 | 10.45초 | 51.3ms | 136.5 | 6.60초 | 19.2 | 0 |
| R2 | 10.40초 | 51.5ms | 136.5 | 6.64초 | 19.2 | 0 |

## 결론

- R1은 판정 기준을 모두 충족했다. decode KV가 14.4% 늘고, L2에서 prefill OOM이 없었다.
- R2(0.95)도 기동과 L1·L2 부하를 견뎠다. 단, KV를 채우는 장시간 부하에서는 검증하지 않았다.
- L1·L2는 decode KV를 채우지 않으므로 지연 차이가 없다. KV 증가의 이득은 장문 동시 요청이 KV를 채울 때만 나타난다(2-06-6 F0에서 KV 99%).
- 권장값은 R1(prefill 0.75, decode 0.90)이다. 0.95는 vLLM 밖 여유가 약 1.1GiB이므로 운영값으로 쓰지 않는다.
