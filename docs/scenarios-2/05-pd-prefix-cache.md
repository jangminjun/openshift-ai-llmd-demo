# 시나리오 2-05: prefix 캐시와 P/D

**모듈:** 분산 환경 활용 > 추론 단계 분리
**대상:** `llmd-pd/qwen38-int4-pd`, decider는 prefix 기반(시나리오 2-04의 T1)
**상태:** 설계, 미실행

## 목적

다중 턴 대화에서 2턴은 1턴의 문서와 응답을 prefix로 다시 보낸다. P/D 구성에서 1턴의 KV는 prefill pod가 계산해
decode pod로 넘어오므로, 2턴의 prefix는 decode pod의 캐시에 남아 있다. prefix 기반 decider가 캐시되지 않은 토큰만
세어 2턴의 prefill을 생략하고, decode pod가 새 질문만 계산하는지 확인한다.

## 부하

GuideLLM 다중 턴(`synthetic_text`, `turns: 2`, `prefix_tokens`로 공통 문서) 또는 시나리오 11의 다중 턴 부하
(`PROMPT_MODE=multi-turn`, 문서 3,000토큰, 2턴), 대화 50개, MaaS 경로.

## 관측

| 지표 | 1턴 기대 | 2턴 기대 |
|---|---|---|
| prefill `request_success_total` | 대화 수만큼 증가 | 증가 없음 |
| decode prefix 캐시 적중(`vllm:prefix_cache_hits_total / queries_total`) | 낮음 | 높음 |
| TTFT | KV 전달 포함 | 1턴보다 짧음 |
| EPP decode 선택 | 임의 | 1턴과 같은 decode pod(`prefix-cache-scorer`) |

decode pod가 1개인 구성에서는 decode 선택이 자명하므로, 2턴의 prefill 생략 여부가 주된 판정 대상이다.

## 판정 기준

- 2턴 요청의 대부분(90% 이상)이 prefill pod를 거치지 않는다.
- 2턴 TTFT p50이 1턴보다 짧다.

## 확장

decode를 2개로 늘리면(`spec.replicas: 2`, GPU 2장 추가) `prefix-cache-scorer`가 대화를 1턴과 같은 decode pod로 보내는지
(시나리오 11의 캐시 인지 분배와 같은 효과)도 확인할 수 있다.
