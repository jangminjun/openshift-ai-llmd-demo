# 시나리오 2-08-3: prefill `max_num_batched_tokens`와 단문 대기

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`(prefill pod), MaaS 구독 `llmd-demo-sub`
**상태:** 실행 대기

## 목적

고객 문서는 `max_num_batched_tokens`를 4096~8192로 조정하는 방안을 제시한다. 이 값은 한 스케줄링 단계에서 처리하는
토큰 수의 상한이며, chunked prefill의 청크 크기를 정한다. 429와는 무관하지만, 장문 prefill이 다른 요청을 얼마나
기다리게 하는지에 영향을 준다.

2-08-5·2-08-6의 1차 실행에서 장문 4건이 처리되는 동안 단문 1건이 34.5초를 기다렸다. P/D 구성에서는 모든 prefill이
prefill pod에서 일어나므로(약 1,210토큰/초), 본 시나리오는 prefill pod의 값을 바꾸어 단문 TTFT를 비교한다.

## 실험 설계

| 항목 | 값 |
|---|---|
| 한도 | 없음(10억/1시간) |
| 부하 | 장문 4건 동시(약 12K 토큰) + 단문 1초마다 새 요청 |
| 비교 | prefill `--max-num-batched-tokens` 2048 vs 8192 |
| 기록 | 단문 TTFT p50·최대, 장문 완료 시간 |

```sh
oc get llminferenceservice qwen38-int4-pd -n llmd-pd \
  -o jsonpath='{.spec.prefill.template.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS=chunk ./harness.sh scenario2-08-mitigation   # prefill 재기동 2회 + 원복
```

## 결과

(실행 후 기록)
