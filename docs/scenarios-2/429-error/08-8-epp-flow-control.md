# 시나리오 2-08-8: EPP Flow Control 우선순위로 장문·단문 간섭 완화

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`(EPP `qwen38-int4-pd-kserve-router-scheduler`), MaaS 구독 `llmd-demo-sub`
**상태:** 아이디어(미실행). P/D 시나리오(2-03~2-06) 이후 진행

## 배경

EPP Flow Control은 풀이 포화되면 요청을 vLLM이 아니라 EPP 큐에 붙잡아 두고, 여유가 생기면 우선순위가 높은 큐부터 꺼내
보낸다(시나리오 21). 우선순위는 `InferenceObjective`(`llm-d.ai/v1alpha2`)의 `priority`로 정의하고 요청 헤더
`x-llm-d-inference-objective`로 선택한다. 큐에서 `defaultRequestTTL`을 넘긴 요청은 거절된다.

## MaaS 429와의 관계

Flow Control은 MaaS 토큰 한도 429의 대책이 아니다. 토큰 한도는 Gateway의 wasm 단계(Limitador)에서 판정되며, 요청이 EPP
큐에 들어가기 전에 429가 반환된다. Flow Control은 GPU 포화만 보고 사용자별 토큰 사용량은 모른다.

```
요청 → Gateway: 인증 → 토큰 한도(429) → payload-processing → EPP: Flow Control 큐 → vLLM(prefill → decode)
```

## 기대 효과

2-08에서 429와 별개로 관측된 장문·단문 간섭에 효과가 있을 것으로 본다.

| 2-08 관측 | Flow Control의 역할 |
|---|---|
| 장문 prefill 뒤에서 단문 TTFT 20~24초(2-08-3, 2-08-5, 2-08-6) | 대화형 단문을 높은 우선순위로 두어 큐에서 먼저 내보낸다 |
| 동시 실행 제한을 클라이언트가 구현해야 함(2-08-5) | `concurrency-detector`로 vLLM에 보내는 요청 수를 서버가 제한한다(풀 전체 기준, 사용자별 아님) |
| 구독 분리 후에도 단문 지연이 남음(2-08-6) | 같은 GPU 풀에서 우선순위로 단문을 먼저 처리한다 |

## 실험 설계(안)

| 항목 | 값 |
|---|---|
| 한도 | 없음(10억/1시간). 지연만 본다 |
| 장문 | 약 12K 토큰, 동시 4, priority 0(`batch`) |
| 대화형 단문 | 1초마다, priority 100(`interactive`) |
| 대조군 단문 | 1초마다, priority 0(`batch`), 요청은 대화형과 같음 |
| 비교 | Flow Control 기본 설정 vs 우선순위 적용 |
| 기록 | 단문 TTFT(대화형 vs 대조군), 장문 완료 시간, EPP 큐 대기·거절 로그, prefill 대기열 |

```sh
oc get llminferenceservice qwen38-int4-pd -n llmd-pd -o jsonpath='{.spec.router.scheduler.config.inline}'
oc logs -n llmd-pd deploy/qwen38-int4-pd-kserve-router-scheduler | grep -i 'flow control'
oc get inferenceobjective -n llmd-pd
```

## 확인할 사항

- **P/D에서의 포화 판정:** 병목은 prefill pod인데, saturation detector(`utilization-detector` 기본, `concurrency-detector`)가
  prefill 포화를 보는지 decode를 보는지 확인한다.
- **기본 활성 여부:** RHOAI 3.5.2 EPP는 Flow Control이 기본으로 켜져 있으나, 2-08 `saturate`(48건 동시)에서 EPP 거절이
  없었다. 포화 기준과 큐 동작을 먼저 확인한다.
- **60초 끊김:** EPP 큐 대기도 첫 토큰을 늦추므로 MaaS 외부 경로에서는 ELB 60초 끊김(2-08 H3)과 맞물린다. 측정은
  `hostAliases`로 Gateway에 직접 보낸다(2-03과 같음).
- **판정 기준(안):** 대화형 단문 TTFT가 대조군보다 작고, 2-08-5 동시 4의 단문 TTFT(24.5초) 대비 크게 줄어든다.
