# 시나리오 2-06-3: prefill의 배치 토큰 축소(`--max-num-batched-tokens`)

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd` prefill pod
**상태:** 실행 완료(2026-11-12~13)

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

## 결과

B1(2048)만 실행했다. B2(8192)는 실행하지 않았다.

| 항목 | 기준 | B1(2048) |
|---|---|---|
| prefill KV | 7.64GiB, 373,321토큰 | 7.64GiB, 373,321토큰 |
| prefill CUDA graph | 1.26GiB | 1.26GiB |
| prefill GPU 사용 | 18,860MiB | 18,792MiB |
| L1 동시 16 TTFT p50, ITL p50, 출력 tok/s | 10.40초, 51.5ms, 136.5 | 13.37초, 45.8ms, 128.0 |
| L2 동시 1 TTFT p50 | 6.56초 | 7.24초 |
| preemption, NIXL 실패 | 0, 0 | 0, 0 |

B1의 KV·graph·GPU 메모리는 기준과 같다. 따라서 기준의 기본값도 2048로 판단한다. vLLM은 GPU 메모리가 70GiB 미만이면 API 서버의 기본값을 2048로 둔다(기동 로그에 값이 출력되지 않아 메모리 수치로 추정).

B1의 부하 수치는 기준과 다르다. 이는 설정 차이가 아니라 실행 세션 차이이다. 같은 세션의 2-06-4(S1)와 B1은 수치가 같고, 2-03의 기존 측정(13.3초, 46.0ms, 128 tok/s)과도 같다.

## 결론

- L4(24GB)에서 `--max-num-batched-tokens=2048`은 기본값과 같으므로 효과가 없다.
- 활성화 피크를 더 낮추려면 1024 이하를 시험해야 한다. 이 경우 prefill 처리 속도 손실을 함께 측정한다.
- 2-08-3의 "2048 vs 8192" 비교는 8192를 명시한 경우에 해당한다. 기본 구성에는 해당하지 않는다.
