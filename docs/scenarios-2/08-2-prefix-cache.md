# 시나리오 2-08-2: prefix 캐시와 토큰 차감

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`(prefill pod), MaaS 구독 `llmd-demo-sub`
**상태:** 실행 대기

## 목적

고객 문서는 EPP prefix 캐시 라우팅을 429 완화책으로 제시한다. prefix 캐시는 같은 문서를 다시 보낼 때 prefill 계산을
줄인다. 본 시나리오는 prefix 캐시가 (1) MaaS 차감량을 줄이는지, (2) 지연을 얼마나 줄이는지 측정한다.

## 사전 확인

Qwen3.8-27B는 linear attention을 섞은 하이브리드 모델이며, vLLM 0.24는 이 모델에서 prefix 캐시를 기본으로 끈다.

```sh
oc logs -n llmd-pd -l llm-d.ai/role=prefill -c main | grep -o 'enable_prefix_caching=[A-Za-z]*'   # False
```

P/D 구성에서 prefill 계산은 prefill pod가 하므로 prefill의 `VLLM_ADDITIONAL_ARGS`에 `--enable-prefix-caching`을 추가한다.
복제본이 1개이므로 EPP의 prefix 라우팅은 비교 대상이 아니며, vLLM의 캐시 효과만 본다.

## 실험 설계

| 항목 | 값 |
|---|---|
| 한도 | 없음(10억/1시간) |
| 부하 | 문서 5개(약 6K 토큰), 문서마다 질문 2개를 순차 전송(같은 문서 = 같은 prefix) |
| 비교 | prefill prefix 캐시 꺼짐(기본) vs 켜짐 |
| 기록 | 질문 2의 `prompt_tokens`·`cached_tokens`(차감 기준), TTFT |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS=prefix ./harness.sh scenario2-08-mitigation   # prefill 재기동 2회
```

## 결과

(실행 후 기록)
