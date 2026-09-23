# 시나리오 22: EndpointPicker Scorer 개선 (KV 캐시 인지 라우팅)

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** EPP, `prefix-cache-scorer`, `queue-scorer`, `kv-cache-utilization-scorer`, `no-hit-lru-scorer`

## 목적

기존 2종(prefix-cache, queue)에 추가된 `kv-cache-utilization-scorer`, `no-hit-lru-scorer`를 포함한
4종 Scorer 구성에서, 동일 prefix 요청이 KV 캐시가 적재된 pod로 라우팅되어 TTFT가 단축됨을 검증한다.

## 구성

- `LLMInferenceService` replica 2 (GPU 2), EPP 활성화
- 대조군: 워크로드 `Service` 직접 호출(라운드로빈, EPP 미경유)

```yaml
spec:
  replicas: 2
  router:
    scheduler:
      config:
        inline:
          apiVersion: llm-d.ai/v1alpha1          # 3.5.1 기본값과 동일한 구성
          kind: EndpointPickerConfig
          plugins:
          - type: single-profile-handler
          - type: prefix-cache-scorer
          - type: queue-scorer
          - type: kv-cache-utilization-scorer
          - type: no-hit-lru-scorer
          - type: max-score-picker
          - type: metrics-data-source
            parameters: {scheme: https}          # 누락 시 vLLM 메트릭 수집 실패
          schedulingProfiles:
          - name: default
            plugins:
            - {pluginRef: prefix-cache-scorer, weight: 3}
            - {pluginRef: queue-scorer, weight: 2}
            - {pluginRef: kv-cache-utilization-scorer, weight: 2}
            - {pluginRef: no-hit-lru-scorer, weight: 2}
            - {pluginRef: max-score-picker}
```

## 하네스 실행

```sh
./harness.sh scenario22-llmd-epp-scorers             # S22_DOCS / S22_REQUESTS 로 규모 조정
```

수동 절차는 아래와 같으며, 하네스 명령은 동일 절차를 수행하고 설정을 원복한다.

## 절차

```sh
NS=llmd-s22; NAME=llmd-scorer
oc get pods -n $NS -l app.kubernetes.io/name=$NAME -o wide         # replica 2 확인
# 1) 공통 system prompt(약 2,000 토큰) + 상이한 질문 10종 × 5회 → Gateway 경유
# 2) 동일 요청 집합 → 워크로드 Service 직접 호출(대조군)
# 3) pod별 prefix cache 적중률 및 TTFT 비교 (Thanos)
```

```promql
sum by (pod) (rate(kserve_vllm:prefix_cache_hits_total{namespace="llmd-s22"}[5m]))
  / sum by (pod) (rate(kserve_vllm:prefix_cache_queries_total{namespace="llmd-s22"}[5m]))
histogram_quantile(0.5, sum by (le) (rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llmd-s22"}[5m])))
```

## 판정 기준

| 지표 | 통과 조건 |
|---|---|
| 동일 prefix 요청의 pod 분포 | EPP 경유 시 한 pod로 집중(선호 pod 존재) |
| prefix cache 적중률 | EPP 경유 > 대조군 |
| TTFT p50 | EPP 경유 < 대조군 |
| 신규 prefix 요청 | `no-hit-lru-scorer`에 의해 최근 미사용 pod로 분산 |

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, T4 × 2 replica, MaaS Gateway 경유)

**통과.** RHOAI 3.5.1의 기본 EPP 설정에 이미 Scorer 4종이 포함되어 있다
(`--config-text`: `queue-scorer` 2, `kv-cache-utilization-scorer` 2, `prefix-cache-scorer` 3,
`no-hit-lru-scorer` 2, `max-score-picker`, apiVersion `llm-d.ai/v1alpha1`).
대조군은 워크로드 `Service` 직접 호출 대신 `random-picker` 단독 구성으로 두었다(MaaS 경로 유지).

부하: 문서 150종(약 3,000 토큰) × 질문 무작위, 900 요청, 동시성 8, 출력 16 토큰.
문서 총량(약 45만 토큰)이 pod당 KV 캐시(329,920 토큰)를 초과하도록 설계하였다.
두 측정은 서로 다른 문서 집합(`DOC_OFFSET`)을 사용하여 캐시 공유를 배제하였다.

| 지표 | 기본 EPP (Scorer 4종) | random-picker | 차이 |
|---|---|---|---|
| prefix cache 적중률 | **83.2%** | 58.4% | +24.8%p |
| TTFT p50 / p95 | **0.17 s / 2.48 s** | 1.70 s / 5.06 s | p50 10배 단축 |
| E2E p50 / p95 | **0.67 s / 5.55 s** | 3.52 s / 10.06 s | |
| 처리량 | **4.25 req/s** | 2.06 req/s | 2.1배 |
| pod 분포 | 453 : 447 | 416 : 482 | |
| 실패 | 0 | 500 × 2 | |

기본 EPP의 적중률 83.2%는 문서당 최초 1회만 miss가 발생하는 이론 상한(5/6 = 83.3%)과 일치한다.
즉 동일 문서 요청이 KV 캐시를 보유한 pod로 일관되게 라우팅되었으며, 분포는 균등하게 유지되었다.

재현: `./harness.sh scenario22-llmd-epp-scorers` (기본 EPP → random-picker → 기본값 원복).

## 운영상 유의 사항

- 인라인 설정은 기본 설정을 **대체**한다. `metrics-data-source`(`scheme: https`)를 빠뜨리면 EPP가 vLLM
  메트릭을 수집하지 못한다.
- 설정 변경 시 EPP `Deployment`가 재기동된다(약 60초).
- 동일 Gateway에 EPP 모델을 2개 이상 두면 ext_proc 오배정이 발생한다(`lessonlearn.md` 2026-09-23).
