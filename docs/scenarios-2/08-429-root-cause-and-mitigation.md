# 시나리오 2-08: 장문 호출 429의 원인 검증과 완화 방안 평가

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`, MaaS 구독 `llmd-demo-sub`, `llmd-demo-sub-chat`
**상태:** 원인 검증 실행 중, 완화 방안은 하위 문서(2-08-1~2-08-7)에 기록

## 목적

고객 측 분석 문서는 장문(약 100K 토큰) 에이전트 호출 뒤의 429를 세 가지 원인(H1~H3)으로 설명하고, 단기 방안(M1~M6)과
중장기 방안(S1~S2)을 제시한다. 본 시나리오는 각 원인을 RHOAI 3.5.2 MaaS·llm-d 구성에서 실측으로 판정하고, 방안별 효과를
하위 시나리오에서 측정한다.

## 원인 가설과 판정

| # | 주장 | 판정 (근거) | 실험 |
|---|---|---|---|
| H1 | 토큰 버킷이 단일 대형 요청으로 고갈되고, 재충전 전 후속 호출이 429 | **부분 수정.** 연속 재충전이 아니라 사용자별 **고정 구간 카운터**이다. 구간은 첫 차감 시점에 시작하고 끝나면 한 번에 초기화된다(2-07 E1). 요청 시작 시 잔량만 확인하고 응답 후 차감하므로, 단일 대형 요청은 거부되지 않고 통과한 뒤 후속 호출을 막는다 | `single`: 한도 8,000/15초에서 12K 요청 1건 + 단문 1초 간격 |
| H2 | 입력·출력 토큰 합산으로 RAG 입력만으로 할당량 소진 | 합산은 확인(차감량 = `usage.total_tokens`, 2-07). 입력·출력 가중치 분리 설정은 `MaaSSubscription`에 없다 | `io`: 한도 5,000/5분에서 (a) 입력 약 2.4K·출력 32, (b) 입력 약 60·출력 2,400을 각 3건 |
| H3 | vLLM KV 부족·대기 큐 포화가 429로 반환 | vLLM은 429를 반환하지 않고 대기열에 쌓는다. 포화 시 429를 낼 수 있는 주체는 EPP Flow Control(`utilization-detector`)이다 | `saturate`: 한도 없음, 약 6K 토큰 요청 48건 동시, 응답 코드와 EPP 로그 |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS="single io saturate" ./harness.sh scenario2-08-mitigation
```

## 완화 방안과 하위 시나리오

| # | 방안 | 검토 의견 | 하위 시나리오 (실험) |
|---|---|---|---|
| M1 | Burst Capacity를 평균의 2~3배로 증설 | MaaS에는 burst 파라미터가 없다. **구간 한도 자체가 버스트 용량**이다 | [2-08-1](08-1-limit-sizing.md) (`limit`) |
| M2 | 분 단위 또는 Sliding Window | Sliding Window는 지원되지 않는다. **2단 한도**(단기 + 장기)로 버스트 흡수와 예산 통제를 분리한다 | [2-08-1](08-1-limit-sizing.md) (`limit`) |
| M3 | EPP Prefix Caching 라우팅 | prefix 캐시는 prefill 시간을 줄이지만 캐시 적중 토큰도 `prompt_tokens`에 포함되므로 차감량은 줄지 않는다. 본 모델(하이브리드)은 vLLM 기본값에서 prefix 캐시가 꺼져 있다 | [2-08-2](08-2-prefix-cache.md) (`prefix`) |
| M4 | `max_num_batched_tokens` 4096~8192 | 429와 무관하다. 장문 prefill 중 다른 요청의 대기(TTFT)에 영향 | [2-08-3](08-3-batched-tokens.md) (`chunk`) |
| M5 | 지수 백오프와 지터 재시도 | `Retry-After`가 없으므로 클라이언트 재시도가 필수이다 | [2-08-4](08-4-retry-backoff.md) (`retry`) |
| M6 | 세션당 동시 실행 1~2개 제한 | 동시 요청이 함께 통과해 한도를 넘는 현상(2-07 E2)을 줄인다 | [2-08-5](08-5-concurrency-cap.md) (`conc`) |
| S1 | 대용량 에이전트 전용 엔드포인트·풀 분리 | 카운터가 구독 + 사용자 + 모델 단위이므로 구독 분리만으로 한도 간섭이 사라진다. GPU 간섭은 별도 `LLMInferenceService`가 필요하다 | [2-08-6](08-6-subscription-split.md) (`split`) |
| S2 | RAG 컨텍스트 요약·reranker로 입력 압축 | 차감 토큰이 입력에 비례하므로 효과가 직접적이다. 애플리케이션 영역이므로 `io` 결과로 효과를 산정한다 | [2-08-7](08-7-input-compression.md) |

모든 실험은 클러스터 내 Job(API 키는 Secret)으로 수행하며, 종료 시 한도와 vLLM 인자를 원래대로 되돌린다. 요청 크기는
`--max-model-len=16384`에 맞춰 축소하였다(장문 약 12K 토큰, 고객 사례 100K는 비율로 환산).

## 결과

(원인 검증 실행 후 기록)
