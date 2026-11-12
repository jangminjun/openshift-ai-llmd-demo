# 시나리오 2-08-0: rate-limit 헤더(`X-RateLimit-Reset`) 기반 재시도

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** Limitador `kuadrant-system/limitador`, MaaS 구독 `llmd-demo-sub`
**상태:** 실측 완료(2026-11-12). 헤더가 클라이언트에 전달되지 않음

## 목적

MaaS의 429에는 `Retry-After`가 없으므로(2-07) 클라이언트는 재시도 간격을 추정해야 한다(2-08-4). Limitador는 IETF
초안 03(draft-polli-ratelimit-headers-03)의 헤더를 응답에 넣는 옵션을 제공한다. 이 중 `X-RateLimit-Reset`은 구간 초기화까지
남은 초로서 `Retry-After`와 같은 정보를 준다. 본 시나리오는 이 헤더가 MaaS Gateway를 거쳐 클라이언트에 전달되는지, 그리고
헤더 값만큼 기다리는 재시도가 지수 백오프보다 나은지 측정한다.

## 설정

`Limitador.spec.rateLimitHeaders`를 `DRAFT_VERSION_03`으로 바꾸면 Limitador가 `--rate-limit-headers DRAFT_VERSION_03`으로
재기동한다. Kuadrant wasm-shim은 Limitador가 돌려준 헤더(`response_headers_to_add`)를 429 응답에 넣는다. 이 설정은
Limitador를 쓰는 모든 정책에 적용된다.

```sh
oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"rateLimitHeaders":"DRAFT_VERSION_03"}}'
oc rollout status deploy/limitador-limitador -n kuadrant-system
oc get deploy limitador-limitador -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].args}'   # --rate-limit-headers DRAFT_VERSION_03
```

| 헤더 | 의미 |
|---|---|
| `X-RateLimit-Limit` | 한도(및 구간) |
| `X-RateLimit-Remaining` | 현재 구간의 남은 양 |
| `X-RateLimit-Reset` | 구간 초기화까지 남은 초 |

## 실험 설계

| 항목 | 값 |
|---|---|
| 한도 | 20,000/15초 (2-08-4와 같음) |
| 부하 | 장문 6건(약 12,100토큰) 순차 |
| 정책 | (a) `reset`: 429의 `X-RateLimit-Reset` + 0.2초 대기, (b) 지수 백오프(1초 시작, 상한 15초, 지터) |
| 기록 | 429 응답의 헤더, 6건 완료 시간, 시도 수 |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS=headers ./harness.sh scenario2-08-mitigation   # 종료 시 rateLimitHeaders 원복
```

## 결과 (2026-11-12, RHCL 1.4.3)

| 정책 | 6건 완료 시간 | 시도 | 429 | 429 응답의 rate-limit 헤더 |
|---|---|---|---|---|
| (a) `reset` | 76.1초 | 12 | 6 | 없음 → 백오프로 대체 |
| (b) 지수 백오프 | 74.6초 | 12 | 6 | 없음 |

- Limitador는 `--rate-limit-headers DRAFT_VERSION_03`으로 재기동되었으나, MaaS Gateway를 거친 응답에는 429와 200 모두
  `X-RateLimit-*` 헤더가 없었다. (a)는 헤더가 없어 백오프로 동작하였으므로 두 정책의 결과가 같다.
### 헤더가 사라지는 지점

**Limitador가 헤더를 만들지 않는다.** MaaS의 토큰 한도(`TokenRateLimitPolicy`)는 wasm-shim이 Envoy RLS의
`ShouldRateLimit`이 아니라 Kuadrant 전용 API `CheckRateLimit`(서비스 유형 `ratelimit-check`)으로 호출한다. 배포된 Limitador
v2.4.2의 `CheckRateLimit` 구현은 `--rate-limit-headers` 설정과 무관하게 `response_headers_to_add: vec![]`(빈 목록)을 반환한다.
헤더를 지원하는 경로는 요청 수 한도(`RateLimitPolicy`)가 쓰는 `ShouldRateLimit`뿐이다.

| 확인 | 결과 |
|---|---|
| wasm-shim의 토큰 한도 호출 유형 | `ratelimit-check-service`(type `ratelimit-check`) |
| Limitador 버전 | v2.4.2 (`limitador-server --version`) |
| v2.4.2 `CheckRateLimit` | `response_headers_to_add: vec![]` 고정 |
| v2.4.2 `ShouldRateLimit` | `rate_limit_headers` 설정 시 헤더 반환 |
| 헤더 지원 추가 | 커밋 `95780c69` "RLS: return RateLimit-* headers from CheckRateLimit and Reserve"(2026-09-13), v2.6.0(2026-10-27)에 포함, v2.5.0에는 없음 |

```sh
oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o yaml | grep -o 'ratelimit-check[a-z-]*' | sort -u
oc exec -n kuadrant-system deploy/limitador-limitador -- limitador-server --version      # Limitador Server v2.4.2
oc get csv -A | grep -E 'rhcl-operator|limitador-operator'                                 # rhcl-operator.v1.4.3
```

출처: Kuadrant/limitador `limitador-server/src/envoy_rls/kuadrant_service.rs`(v2.4.2, v2.6.0 비교).

## 결론

본 구성(RHOAI 3.5.2 MaaS + RHCL 1.4.3, Limitador v2.4.2)에서는 토큰 한도 경로(`CheckRateLimit`)가 헤더를 만들지 않으므로
`X-RateLimit-Reset`을 클라이언트에 제공할 수 없다. 클라이언트 재시도는 지수 백오프(2-08-4)를 유지한다. 업스트림 Limitador
v2.6.0부터 `CheckRateLimit`이 헤더를 반환하므로, 이를 포함한 RHCL 버전에서 재시험한다. 이때 wasm-shim이 `ratelimit-check`
응답의 헤더를 429에 넣는지도 함께 확인해야 한다(미확인). 시험 후 `rateLimitHeaders`는 미지정으로 원복하였다.
