# 시나리오 2-06-4: prefill의 동시 요청 축소(`--max-num-seqs`)

**모듈:** 분산 환경 활용 > 자원 계획
**대상:** `llmd-pd/qwen38-int4-pd` prefill pod
**상태:** 설계, 미실행

## 목적

`--max-num-seqs`는 한 번에 처리하는 요청 수의 상한이다. 이 값은 CUDA graph 캡처 크기와 샘플러 등의 버퍼 크기를 정하므로
메모리 예산에 영향을 준다. prefill은 요청을 사실상 순차로 처리하므로(2-03, 약 1,210토큰/초) 많은 동시 요청을 들고 있을
필요가 없다. prefill의 값을 64에서 8로 줄여 메모리를 회수하면서 처리량이 유지되는지 확인한다.

## 조건

| 단계 | prefill `--max-num-seqs` | decode |
|---|---|---|
| 기준 | 64 | 64 |
| S1 | 8 | 64 |

```sh
oc edit llminferenceservice qwen38-int4-pd -n llmd-pd
# spec.prefill.template.containers[0].env VLLM_ADDITIONAL_ARGS: --max-num-seqs=8
oc logs -n llmd-pd -l llm-d.ai/role=prefill -c main | grep -E 'max_num_seqs|cudagraph_capture_sizes|CUDA graph memory|Available KV cache memory'
```

## 측정

| 항목 | 출처 |
|---|---|
| CUDA graph 캡처 크기·메모리 | 기동 로그 |
| prefill KV 용량 | `Available KV cache memory` |
| L1 동시 16의 TTFT·처리량, prefill 대기열 | 2-03 L1, `vllm:num_requests_waiting`(prefill) |

## 판정 기준

- S1에서 prefill의 graph 메모리가 줄고 KV 용량이 늘어난다.
- L1 동시 16의 처리량 차이가 5% 이내이다. 동시 요청이 8을 넘으면 prefill 대기열이 쌓이는데, 처리량이 같으면 대기 위치만
  vLLM 안에서 밖(EPP·sidecar)으로 옮겨진 것이다.
