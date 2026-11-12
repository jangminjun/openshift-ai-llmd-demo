# 시나리오 2-06-3: prefill의 배치 토큰 축소(`--max-num-batched-tokens`)

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd` prefill pod
**상태:** 설계, 미실행

## 목적

`--max-num-batched-tokens`는 한 스케줄링 단계에서 계산하는 토큰 수의 상한(chunked prefill의 청크 크기)이다. 활성화 메모리는
이 값에 비례하므로, prefill에서 값을 줄이면 긴 프롬프트의 활성화 피크가 낮아진다. vLLM은 기동 시 이 값으로 메모리를
프로파일링하므로, 줄인 만큼 KV 용량이 늘어날 수 있다. 2-08-3에서 2048은 8192 대비 처리 속도 손실이 거의 없었다.

## 조건

| 단계 | prefill `--max-num-batched-tokens` |
|---|---|
| 기준 | 기본값(기동 로그로 확인) |
| B1 | 2048 |
| B2 | 8192 |

```sh
oc edit llminferenceservice qwen38-int4-pd -n llmd-pd
# spec.prefill.template.containers[0].env VLLM_ADDITIONAL_ARGS: ... --max-num-batched-tokens=2048
oc logs -n llmd-pd -l llm-d.ai/role=prefill -c main | grep -E 'max_num_batched_tokens|Available KV cache memory|out of memory'
```

## 측정

| 항목 | 출처 |
|---|---|
| prefill KV 용량(활성화 예산 변화의 간접 지표) | `Available KV cache memory` |
| GPU 메모리 피크 | `DCGM_FI_DEV_FB_USED`(L2 부하 중 최대) |
| L2 TTFT, 처리량 | 2-03 L2 |

## 판정 기준

- B1의 prefill KV 용량이 B2보다 크거나, 부하 중 GPU 메모리 피크가 낮다.
- B1의 L2 TTFT 증가가 5% 이내이다.
