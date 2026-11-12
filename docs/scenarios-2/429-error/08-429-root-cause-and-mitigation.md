# 시나리오 2-08: 장문 호출 429의 원인 검증과 완화 방안 평가

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`, MaaS 구독 `llmd-demo-sub`, `llmd-demo-sub-chat`
**상태:** 원인 검증과 완화 방안 실측 완료(2026-11-12)

## 목적

고객 측 분석 문서는 장문(약 100K 토큰) 에이전트 호출 뒤의 429를 세 가지 원인(H1~H3)으로 설명하고, 단기 방안(M1~M6)과
중장기 방안(S1~S2)을 제시한다. 본 시나리오는 각 원인을 RHOAI 3.5.2 MaaS·llm-d 구성에서 실측으로 판정하고, 방안별 효과를
하위 시나리오에서 측정한다.

## 원인 가설과 판정

| # | 주장 | 판정 (근거) | 실험 |
|---|---|---|---|
| H1 | 토큰 버킷이 단일 대형 요청으로 고갈되고, 재충전 전 후속 호출이 429 | **부분 수정.** 연속 재충전이 아니라 사용자별 **고정 구간 카운터**이다. 구간은 첫 차감 시점에 시작하고 끝나면 한 번에 초기화된다(2-07 E1). 요청 시작 시 잔량만 확인하고 응답 후 차감하므로, 단일 대형 요청은 거부되지 않고 통과한 뒤 후속 호출을 막는다 | `single`: 한도 8,000/15초에서 12K 요청 1건 + 단문 1초 간격 |
| H2 | 입력·출력 토큰 합산으로 RAG 입력만으로 할당량 소진 | 합산은 확인(차감량 = `usage.total_tokens`, 2-07). 입력·출력 가중치 분리 설정은 `MaaSSubscription`에 없다 | `io`: 한도 4,000/5분에서 (a) 입력 약 2.4K·출력 32, (b) 입력 약 60·출력 2,400을 각 3건 |
| H3 | vLLM KV 부족·대기 큐 포화가 429로 반환 | vLLM은 429를 반환하지 않고 대기열에 쌓는다. 포화 시 429를 낼 수 있는 주체는 EPP Flow Control(`utilization-detector`)이다 | `saturate`: 한도 없음, 약 6K 토큰 요청 48건 동시, 응답 코드와 EPP 로그 |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS="single io saturate" ./harness.sh scenario2-08-mitigation
```

## 완화 방안과 하위 시나리오

| # | 방안 | 검토 의견 | 하위 시나리오 (실험) |
|---|---|---|---|
| R | 429에 대기 시간 제공(`X-RateLimit-Reset`) | `Retry-After` 부재(2-07)의 해결책으로 Limitador의 rate-limit 헤더를 시험한다 | [2-08-0](08-0-ratelimit-headers.md) (`headers`) |
| M1 | Burst Capacity를 평균의 2~3배로 증설 | MaaS에는 burst 파라미터가 없다. **구간 한도 자체가 버스트 용량**이다 | [2-08-1](08-1-limit-sizing.md) (`limit`) |
| M2 | 분 단위 또는 Sliding Window | Sliding Window는 지원되지 않는다. **2단 한도**(단기 + 장기)로 버스트 흡수와 예산 통제를 분리한다 | [2-08-1](08-1-limit-sizing.md) (`limit`) |
| M3 | EPP Prefix Caching 라우팅 | prefix 캐시는 prefill 시간을 줄이지만 캐시 적중 토큰도 `prompt_tokens`에 포함되므로 차감량은 줄지 않는다. 본 모델(하이브리드)은 vLLM 기본값에서 prefix 캐시가 꺼져 있다 | [2-08-2](08-2-prefix-cache.md) (`prefix`) |
| M4 | `max_num_batched_tokens` 4096~8192 | 429와 무관하다. 장문 prefill 중 다른 요청의 대기(TTFT)에 영향 | [2-08-3](08-3-batched-tokens.md) (`chunk`) |
| M5 | 지수 백오프와 지터 재시도 | `Retry-After`가 없으므로 클라이언트 재시도가 필수이다 | [2-08-4](08-4-retry-backoff.md) (`retry`) |
| M6 | 세션당 동시 실행 1~2개 제한 | 동시 요청이 함께 통과해 한도를 넘는 현상(2-07 E2)을 줄인다 | [2-08-5](08-5-concurrency-cap.md) (`conc`) |
| S1 | 대용량 에이전트 전용 엔드포인트·풀 분리 | 카운터가 구독 + 사용자 + 모델 단위이므로 구독 분리만으로 한도 간섭이 사라진다. GPU 간섭은 별도 `LLMInferenceService`가 필요하다 | [2-08-6](08-6-subscription-split.md) (`split`) |
| S2 | RAG 컨텍스트 요약·reranker로 입력 압축 | 차감 토큰이 입력에 비례하므로 효과가 직접적이다. 애플리케이션 영역이므로 `io` 결과로 효과를 산정한다 | [2-08-7](08-7-input-compression.md) |
| 추가 | EPP Flow Control 우선순위 | 429 대책은 아니다(토큰 한도는 EPP 앞 Gateway에서 판정). 장문·단문 지연 간섭의 완화책으로 검토 | [2-08-8](08-8-epp-flow-control.md) (아이디어) |

모든 실험은 클러스터 내 Job(API 키는 Secret)으로 수행하며, 종료 시 한도와 vLLM 인자를 원래대로 되돌린다. 요청 크기는
`--max-model-len=16384`에 맞춰 축소하였다(장문 약 12K 토큰, 고객 사례 100K는 비율로 환산).

## 결과

### 원인 판정 (2026-11-12)

| # | 판정 | 실측 |
|---|---|---|
| H1 | **수정.** 토큰 버킷이 아니라 고정 구간 카운터 + 응답 후 차감 | `single`: 한도 8,000보다 큰 12,134토큰 요청이 **200으로 통과**하였다. 응답 직후(10.8초)부터 같은 키의 단문은 15건 연속 429였고, 25.9초(= 차감 10.8초 + 15초)에 일괄 복구되었다 |
| H2 | **확인.** 입력과 출력을 구분 없이 `total_tokens`로 차감 | `io`: 입력 위주(2,435 + 32)와 출력 위주(60 + 2,400) 모두 2건 통과(누적 약 4,930) 후 3번째가 429. 출력 2,400토큰 요청은 86초가 걸렸으나 차감 시점은 응답 종료 시점이었다 |
| H3 | **기각.** 포화 시 429는 나오지 않는다. 대신 60초 무응답 연결이 끊긴다 | `saturate`: 6K 토큰 요청 48건 동시. 429는 0건이고 EPP 로그에 거절이 없었다. prefill이 요청을 순차 처리하여 TTFT가 4.2초씩 늘었고(9.5 → 55.9초), 60초 안에 첫 토큰을 받지 못한 35건이 59.8초에 일괄 끊겼다 |

**H3의 끊김 원인.** Gateway access log에서 35건은 모두 `0 DC downstream_remote_disconnect`(Gateway 앞단이 연결을 닫음),
소요 시간 약 59.8초였다. HTTPRoute 타임아웃은 해제(`0s`)되어 있으며, MaaS Gateway의 Service는 `LoadBalancer`(AWS Classic
ELB, 유휴 타임아웃 기본 60초)이다. 스트리밍 응답은 첫 토큰 전까지 바이트가 흐르지 않으므로, prefill 대기가 60초를 넘으면
ELB가 연결을 끊는다. 클라이언트에는 429가 아닌 연결 오류로 보인다(ELB 설정값은 AWS 계정 접근 불가로 미확인).

```sh
oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway   # TYPE LoadBalancer
oc get httproute -n llmd-pd -o jsonpath='{.items[*].spec.rules[*].timeouts}'                    # request: 0s
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway | grep downstream_remote_disconnect
```

장문 대기가 60초를 넘을 수 있는 환경이면 Gateway에 `service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout`
어노테이션(Gateway `spec.infrastructure.annotations`)으로 유휴 타임아웃을 늘리거나 NLB를 쓴다(미검증).

### 완화 방안별 결과

| # | 방안 | 결과 | 문서 |
|---|---|---|---|
| R | rate-limit 헤더 | Limitador `DRAFT_VERSION_03`을 켜도 MaaS 응답에 `X-RateLimit-*` 헤더가 전달되지 않음(RHCL 1.4.3) | 2-08-0 |
| M1·M2 | 한도 크기·2단 한도 | 20K/15초: 429 26건, 작업 지연 p50 8.5초 → 25K/15초(장문 × 세션 2): 429 0건, p50 2.1초. 2단 한도(50K/15초 + 80K/2분)는 장기 한도 소진 후 48초 차단 | 2-08-1 |
| M3 | prefix 캐시 | 같은 문서 재질의 TTFT −65%(4.95 → 1.72초), 차감 토큰 변화 없음 → 429 완화책 아님 | 2-08-2 |
| M4 | `max_num_batched_tokens` | 429와 무관. 2048 vs 8192에서 단문 TTFT −13%(23.8 → 20.6초)로 효과 작음 | 2-08-3 |
| M5 | 지수 백오프 | 429 6건(즉시 재시도 36건), 완료 시간 +3%(고정 15초 대기 +29%) | 2-08-4 |
| M6 | 동시 실행 제한 | 동시 4 → 1: 장문 429 7 → 0, 단문 429 8 → 0, 단문 TTFT 24.5 → 5.7초, 완료 시간 +40% | 2-08-5 |
| S1 | 구독 분리 | 대화형을 별도 구독으로: 단문 429 6 → 0. 같은 GPU를 쓰므로 단문 지연은 남음 | 2-08-6 |
| S2 | 입력 압축 | 입력 감소분이 그대로 한도 여유가 된다(`io`). 12K → 4K 압축 시 20K/15초 구간의 통과 건수 2 → 5 | 2-08-7 |

## 결론

1. **장문 후 429는 MaaS 토큰 한도에서만 발생한다.** 한도는 사용자별 고정 구간 카운터이며, 요청 시작 시 잔량만 확인하고
   응답 후 `total_tokens`(입력 + 출력)를 차감한다(H1 수정, H2 확인). 서버 포화는 429를 만들지 않는다(H3 기각).
2. **근본 해결은 한도 설계이다.** 단기 한도를 "단일 요청 최대 토큰 × 동시 실행 수" 이상으로 두면 429가 사라진다(2-08-1).
   총량 통제는 시간 단위 장기 한도로 분리한다.
3. **한도를 늘릴 수 없으면 클라이언트 측 방안을 쓴다.** 효과 순서는 구독 분리(2-08-6, 단문 429 제거) ≈ 동시 실행 1 제한
   (2-08-5, 429 제거·완료 시간 +40%) > 입력 압축(2-08-7) 순이다. 남는 429는 지수 백오프로 재시도한다(2-08-4). 서버가 대기
   시간을 알려 주는 방법은 본 구성에서 동작하지 않았다(2-08-0).
4. **prefix 캐시와 `max_num_batched_tokens`는 429 대책이 아니다.** prefix 캐시는 재질의 지연을 65% 줄이지만 차감량은
   같고(2-08-2), 배치 토큰 조정은 지연 개선도 작다(2-08-3).
5. **서버 포화는 다른 증상으로 나타난다.** prefill 대기로 첫 토큰이 60초를 넘으면 MaaS Gateway 앞단(ELB)이 연결을 끊는다.
   장문과 단문이 같은 prefill pod를 쓰면 단문도 수십 초 대기한다(2-08-3·2-08-5·2-08-6). 이는 429 대책과 별개로 prefill
   복제본 증설, 풀 분리, LB 유휴 타임아웃으로 다룬다.
