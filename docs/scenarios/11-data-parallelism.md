# 시나리오 11: 데이터 병렬화와 캐시 인지 라우팅

**모듈:** 분산 환경 활용 > 병렬화 전략
**관련 컴포넌트:** `LLMInferenceService`(`spec.replicas`), EPP(`prefix-cache-scorer`, `session-affinity-*`), MaaS Gateway

## 목적

LLM 서빙의 데이터 병렬화(DP)는 모델 전체를 GPU마다 복제하고 요청을 나누어 처리하는 방식이다. 구조상
수평 확장과 같으나, 각 복제본의 KV 캐시는 공유되지 않는다. 따라서 캐시를 인지하지 않는 분배는 같은
대화의 요청을 여러 pod로 흩어 prefix 캐시 적중률을 낮추고, 모든 pod가 같은 prefix를 중복 보관하게 하여
실효 캐시 용량을 1/N로 줄인다.

본 시나리오는 다음 두 가지를 검증한다.

1. **확장 효과.** replica 1(before) 대비 replica 2(after)의 처리량과 지연.
2. **분배 방식의 효과.** 같은 replica 2에서 캐시를 모르는 분배와 llm-d의 캐시 인지 분배의 차이.

## 배경: EPP의 분배 기준과 session affinity

EPP는 요청마다 후보 pod에 scorer 점수를 가중 합산하여 최고점 pod를 고른다. filter는 점수 계산 전에 후보를
제외한다. RHOAI 3.5.1 기본 설정은 `prefix-cache-scorer`(3), `queue-scorer`(2), `kv-cache-utilization-scorer`(2),
`no-hit-lru-scorer`(2)이며, session affinity 플러그인은 이미지에 포함되어 있으나 기본 설정에는 없다.

**session affinity**는 같은 세션(대화)의 요청을 처음 처리한 pod로 계속 보내는 방식이다.

1. 첫 요청: EPP가 기존 scorer로 pod를 고르고, 응답 헤더 `x-session-token`에 그 pod의 식별 정보를 담아 반환한다.
2. 클라이언트: 토큰을 대화 단위로 저장하고 다음 요청의 헤더에 그대로 넣는다.
3. 다음 요청: EPP가 토큰을 해석해 해당 pod를 우대(scorer)하거나 해당 pod로 한정(filter)한다.

| 구분 | `session-affinity-scorer` | `session-affinity-filter` |
|---|---|---|
| 동작 | 토큰의 pod에 점수(0~1) × 가중치를 더함 | 후보를 토큰의 pod 하나로 제한 |
| 강도 | soft sticky. 다른 scorer 합이 크면 다른 pod 선택 | hard sticky. 해당 pod가 포화되어도 이동하지 않음 |
| 장점 | 고정성과 부하 균형을 함께 확보 | 고정성 최대 |
| 위험 | 가중치가 낮으면 고정성 약화 | 세션별 부하가 불균등하면 hot-spot, 대기열 증가 |
| 설정 위치 | 프로파일의 scorer 목록(`weight` 지정) | 프로파일의 맨 앞(scorer보다 먼저 평가) |

**prefix 캐시 분배와의 차이.** `prefix-cache-scorer`는 요청 내용(프롬프트 prefix)을 해시해 어느 pod로 보냈는지
EPP 메모리의 인덱스에 기록하고, 같은 prefix를 같은 pod로 모은다. session affinity는 내용과 무관하게 세션을
기준으로 하며, 상태를 EPP가 아닌 클라이언트의 토큰이 보관한다. 따라서 평상시에는 대화 이력이 곧 prefix여서
두 방식의 결과가 같지만(조건 C, D), EPP가 재시작되어 인덱스가 사라지면 토큰만 남는다(조건 F).

설정 예(기본 설정에 scorer를 추가하는 경우, 설정 전체를 교체한다):

```json
{"plugins": [{"type": "session-affinity-scorer"}, ...기본 plugins...],
 "schedulingProfiles": [{"name": "default", "plugins": [...기본 scorer...,
   {"pluginRef": "session-affinity-scorer", "weight": 3}, {"pluginRef": "max-score-picker"}]}]}
```

filter는 `{"type": "session-affinity-filter"}`를 plugins에 추가하고 프로파일 목록의 맨 앞에
`{"pluginRef": "session-affinity-filter"}`를 둔다. 토큰의 실제 인코딩 형식은 확인하지 않았다(llm-d 문서 기준).

## 실험 설계

| 조건 | replica | 분배 경로 | 분배 기준 |
|---|---|---|---|
| A | 1 | MaaS Gateway → EPP(기본) | — (before) |
| B | 2 | 워크로드 `Service` 직접 호출 | 연결 단위 부하 분산(캐시 비인지) |
| C | 2 | MaaS Gateway → EPP(기본) | prefix 캐시·대기열·KV 사용률 점수 합산 |
| D | 2 | C + `session-affinity-scorer` | 세션 토큰의 pod에 가산점(부하 균형 유지) |
| E | 2 | C + `session-affinity-filter` | 세션 토큰의 pod로 강제(hard sticky) |
| F0 / F1 / F2 | 2 | C / C / D, 1턴 후 3분 정지 | F1·F2는 정지 중 EPP pod를 삭제(재시작)하여 prefix 인덱스 제거 |

- **부하:** 다중 턴 대화 200개. 대화마다 약 3,000토큰의 고유 문서를 system 메시지로 두고, 3턴 동안 이전
  질의·응답을 모두 재전송한다(`PROMPT_MODE=multi-turn`). 동시 대화 16, 응답 32토큰.
- **포화 조건:** `llmd-test`는 `--max-num-seqs=4`이므로 동시 16에서 replica 1은 포화된다.
- **캐시 압박:** 전체 문맥 약 70만 토큰이 pod당 KV 캐시(약 58만 토큰, vLLM 로그 `GPU KV cache size`)를 넘는다.
- **세션 토큰:** EPP의 session affinity 플러그인이 응답 헤더 `x-session-token`을 발급하고, 부하 생성기가
  다음 턴에 이를 되돌려 보낸다.
- **공정성:** 조건마다 새 문서 범위(`DOC_OFFSET`)를 사용해 이전 조건의 캐시가 결과에 섞이지 않게 한다.
  B는 MaaS 인증 구간을 거치지 않으므로 인증 지연(수 ms)만큼 유리하다.
- **EPP 재시작(F):** 부하 생성기가 1턴 후 정지하고(`PAUSE_AFTER_TURN=1`), 하네스가 정지 중 지표를 기록한 뒤
  EPP pod를 삭제한다. vLLM의 KV 캐시와 클라이언트의 세션 토큰은 유지되므로 2~3턴 적중률로 영향을 본다.

## 측정 지표

| 지표 | 출처 | 해석 |
|---|---|---|
| 처리량(`rps`), TTFT p50/p95 | 부하 생성기(클라이언트 집계) | 확장·분배 효과 |
| TTFT p50 `turn1` / `later` | 부하 생성기 | 첫 턴은 콜드 문서, 이후 턴은 캐시 재사용 여부를 반영 |
| prefix 캐시 적중률 | `kserve_vllm:prefix_cache_hits_total / prefix_cache_queries_total` | 분배의 캐시 인지 정도 |
| pod별 요청 분배(`split`) | `kserve_vllm:request_success_total` (pod별) | 부하 편중 |
| `session_token_resp` | 응답 헤더 수 | session affinity 경로 동작 확인 |

## 사전 조건

- RHOAI 3.5.1, `llmd-test` Ready(EPP 활성, `maas-default-gateway`), 여유 GPU 1장(replica 1→2 전환)
- Gateway의 EPP 활성 모델은 `llmd-test` 하나(`require_single_epp`)
- MaaS 토큰 한도 5,000만 토큰/시간 이상(`require_token_limit`). 기본값 10만은 429를 유발한다.
  ```sh
  LLMD_NAMESPACE=llmd-test LLMD_NAME=llmd-test MAAS_USERS=<user>,system:serviceaccount:llmd-bench:loadgen \
    MAAS_TOKEN_LIMIT=1000000000 ./harness.sh maas-register-model
  ./harness.sh maas-api-key
  ```

## 절차

```sh
cd openshift-ai-llmd-demo/harness
./harness.sh scenario11-llmd-dp-affinity                  # A~E 순차 실행, 종료 시 replica·EPP 설정 원복
S11_ARMS="F0 F1 F2" ./harness.sh scenario11-llmd-dp-affinity   # EPP 재시작 영향
S11_ARMS="B C" S11_SESSIONS=100 ./harness.sh scenario11-llmd-dp-affinity   # 일부 조건, 규모 조정
```

조정 변수: `S11_SESSIONS`(200), `S11_TURNS`(3), `S11_PREFIX_TOKENS`(3000), `S11_CONCURRENCY`(16),
`S11_MAX_TOKENS`(32), `S11_AFFINITY_WEIGHT`(3), `S11_PAUSE`(180), `S11_ARMS`("A B C D E").

분배와 캐시 상태는 다음으로 확인한다.

```sh
oc get pods -n llmd-test -l app.kubernetes.io/component=llminferenceservice-workload -o wide
oc get llminferenceservice llmd-test -n llmd-test -o jsonpath='{.spec.router.scheduler.config.inline}'
QUERY='sum by (pod)(rate(kserve_vllm:prefix_cache_hits_total{namespace="llmd-test"}[5m])) / sum by (pod)(rate(kserve_vllm:prefix_cache_queries_total{namespace="llmd-test"}[5m]))' \
  ./harness.sh llmd-promql
```

## 예상 결과

- **A → C:** 포화 구간이므로 처리량이 약 2배로 증가한다.
- **B vs C:** 처리량은 비슷하나, B는 대화의 턴이 두 pod로 흩어져 적중률이 낮고 `later` TTFT가 길다.
- **C vs D:** 대화 이력이 다음 턴의 prefix가 되므로 C만으로도 대부분 같은 pod로 향한다. D는 캐시가
  밀려난(eviction) 경우와 점수 동률에서 고정성을 보강한다.
- **E:** 적중률은 가장 높을 수 있으나 세션이 몰린 pod의 대기열이 길어져 TTFT p95가 악화될 수 있다.

## 실측 결과 (2026-09-29, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, A10G, `--max-num-seqs=4`)

200개 대화 × 3턴, 동시 16, 조건별 1회. 문서 본문은 단일 단어 반복이었다(부하 생성기 결함, 수정됨). 문서 번호가
선두에 있어 prefix는 대화별로 고유하므로 캐시·분배 결과는 유효하다.

| 조건 | 처리량 (req/s) | TTFT p50 / p95 (s) | 캐시 적중률 | pod 분배 |
|---|---|---|---|---|
| A: r1, EPP | 5.98 | 1.98 / 2.95 | 66.3% | 593 |
| B: r2, `Service` | 9.25 (×1.55) | 1.00 / 2.11 | 41.2% | 296 : 304 |
| C: r2, EPP | **11.92 (×1.99)** | **0.72 / 1.14** | **66.7%** | 306 : 294 |
| D: C + affinity scorer | 11.99 | 0.71 / 1.26 | 66.6% | 298 : 300 |
| E: C + affinity filter | 11.91 | 0.73 / 1.17 | 66.6% | 305 : 294 |

EPP 재시작(1턴 후) 영향. 적중률·TTFT는 2~3턴 기준이다.

| 조건 | 캐시 적중률 | TTFT p50 (s) | 처리량 (req/s) |
|---|---|---|---|
| F0: EPP, 재시작 없음 | 99.3% | 0.47 | 11.90 |
| F1: EPP, 재시작 | 72.3% | 0.67 | 10.06 |
| F2: EPP + affinity scorer, 재시작 | **94.2%** | **0.54** | 11.39 |

- **캐시 인지 분배(C)만 확장 효과를 온전히 얻는다.** 처리량 ×1.99, 적중률은 이론 상한(66.7%).
- **캐시 비인지 분배(B)는 턴이 흩어져 적중률이 이론값(41.7%)까지 떨어지고 처리량은 ×1.55에 그친다.**
- **session affinity(D, E)는 평상시 추가 이득이 없다.** 대화 이력이 곧 prefix이므로 C로 충분하다.
- **EPP 재시작은 캐시 재사용의 약 1/4을 잃게 한다(F1).** prefix 인덱스가 EPP 메모리에만 있기 때문이다.
- **session affinity는 EPP 재시작 시 가치가 있다(F2).** 세션 토큰이 클라이언트에 있어 적중률 94.2%를 유지한다.
  우연이 아님은 2턴으로 확인된다. 3턴은 두 조건 모두 새 EPP가 2턴의 위치를 기록하므로 거의 적중한다고 보면,
  2턴이 원래 pod로 간 비율은 F1 약 45%(2-way 무작위 50%와 유사), F2 약 88%이다. 200개 대화가 50% 확률일 때의
  표준편차는 3.5%p이므로 88%는 평균보다 약 11 표준편차 높다. 단, 1회 측정이고 적중률(토큰 기준)로부터의
  역산이며 요청별 pod를 직접 추적하지 않았다.
- MaaS 경로의 500(0.2~1.2%)은 Authorino 인증 200ms 기한 초과이며 모델과 무관하다([lessonlearn.md](../../lessonlearn.md)).

## Summary: 운영 가이드

데이터 병렬화의 효과는 분배 방식이 결정한다. EPP 분배는 GPU 증설 효과를 온전히 얻고(×1.99), EPP 재시작으로
잃는 캐시는 session affinity가 대부분 보완한다(72.3% → 94.2%).

1. **replica 2 이상은 EPP로만 분배한다.** 워크로드 `Service` 직접 노출은 캐시를 잃는다(×1.55).
2. **채팅 서비스는 `session-affinity-scorer`를 켠다.** 채팅은 한 대화가 여러 요청으로 이어지고 매 요청이 이전
   대화 전체를 다시 보내므로, 같은 pod로 가야 캐시를 재사용한다. 단발 요청 서비스에는 이득이 없다.
   클라이언트(앱)는 응답 헤더 `x-session-token`을 대화별로 저장해 다음 요청에 넣어야 하며, 그렇지 않으면 효과가 없다.
   `session-affinity-filter`(강제 고정)보다 scorer를 우선한다. filter는 토큰의 pod가 붐벼도 다른 pod로 보내지 않아
   hot-spot(특정 pod에만 요청이 몰려 그 pod의 대기열과 지연만 커지는 현상)이 생길 수 있다. 본 측정은 대화 길이가
   균일해 hot-spot이 나타나지 않았으며(E), 불균등 부하에서의 위험은 미검증이다.
3. **EPP 설정 변경·재시작은 저부하 시간에 한다.** 재시작 직후 캐시 적중률과 TTFT가 일시적으로 나빠진다.
4. **pod별 캐시 적중률과 요청 분배를 모니터링한다.**

```sh
oc get llminferenceservice <name> -n <ns> -o jsonpath='{.spec.router.scheduler.config.inline}'
```

1.5B 모델, replica 2, 1회 측정 결과이며 대형 모델·다수 replica에서는 수치가 달라질 수 있다.
