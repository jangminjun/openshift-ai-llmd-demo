# 시나리오 28: 외부 토크나이저 서비스 분리

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** `spec.router.scheduler.tokenizer`, preset `v3-5-1-kserve-config-llm-tokenizer`

## 목적

토크나이저가 EPP 내부가 아닌 독립 컨테이너/서비스로 분리되어 별도 리소스를 할당받고, 대용량 프롬프트
전처리 부하를 EPP와 독립적으로 흡수함을 검증한다.

## 구성 (3.5.1 preset 실측)

- 토크나이저 preset은 `vllm-cpu-rhel9` 이미지를 `router.scheduler.tokenizer.template`로 기동한다(GPU 불필요).
- 대상: EPP 활성화된 `LLMInferenceService` 1개 (GPU 1)

```sh
oc get llminferenceserviceconfig v3-5-1-kserve-config-llm-tokenizer -n redhat-ods-applications \
  -o jsonpath='{.spec.router.scheduler.tokenizer.template.containers[0].image}'
```

## 절차

```sh
NS=llmd-s29; NAME=llmd-tok
# 1) 토크나이저 활성화 (preset 참조 또는 tokenizer 템플릿 지정)
oc patch llminferenceservice $NAME -n $NS --type=merge -p '{"spec":{"router":{"scheduler":{"tokenizer":{}}}}}'
# 2) 토크나이저 컨테이너/서비스 기동 확인
oc get pods,svc -n $NS
oc get pod -n $NS -l app.kubernetes.io/component=router-scheduler -o jsonpath='{.items[0].spec.containers[*].name}'
# 3) 대용량 프롬프트(6,000 토큰) 동시성 16 부하 → 컨테이너별 CPU/메모리 관찰
oc adm top pod -n $NS --containers
# 4) 토크나이저 리소스(requests/limits) 상향 후 3) 반복, EPP 스케줄링 지연 비교
```

## 판정 기준

| 지표 | 통과 조건 |
|---|---|
| 분리 | 토크나이저가 EPP와 별도 컨테이너/프로세스로 기동 |
| 리소스 | 토크나이저 리소스를 독립적으로 지정·관측 가능 |
| 성능 | 토크나이저 리소스 상향 시 대용량 프롬프트의 EPP 처리 지연 감소 |

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, T4 × 2, MaaS Gateway 경유)

**분리 동작 확인. 텍스트 모델에서 성능 이득은 없음.**

활성화는 두 단계가 모두 필요하였다.

```sh
# 1) 토크나이저 서비스 기동: preset 을 baseRefs 로 명시 (tokenizer: {} 는 빈 객체로 제거되어 무효)
oc patch llminferenceservice llmd-test -n llmd-test --type=merge \
  -p '{"spec":{"baseRefs":[{"name":"v3-5-1-kserve-config-llm-tokenizer"}]}}'
oc get deploy,svc -n llmd-test | grep tokenizer        # llmd-test-tokenizer (vllm launch render, CPU 노드)
oc get llminferenceservice llmd-test -n llmd-test -o jsonpath='{.status.conditions[?(@.type=="TokenizerReady")].status}'

# 2) EPP 연결: preset 은 서비스만 띄우며 EPP 설정은 변경하지 않는다 -> token-producer 를 직접 추가
#   - type: token-producer
#     parameters: {modelName: /mnt/models/base, vllm: {url: https://llmd-test-tokenizer.llmd-test.svc.cluster.local:8000}}
```

- render 서버의 모델 ID는 `/mnt/models/base`(`vllm launch render /mnt/models/base`)이다. `modelName`에 서빙
  모델명을 넣으면 render 호출이 404가 되고, prefix Scorer가 `PrefixCacheMatchInfo not found`로 **0점**을 주어
  캐시 인지 라우팅이 무력화된다.

부하: 문서 150종 × 450 요청, 동시성 8.

| 지표 | 외부 토크나이저 | 내장 토큰 추정 |
|---|---|---|
| token-producer 지연 p95 | 36.4 ms | 0.1 ms |
| EPP 스케줄링 지연 p95 | 0.10 ms | 0.10 ms |
| TTFT p50 / p95 | 1.20 s / 3.97 s | 1.07 s / 3.35 s |
| prefix cache 적중률 | 67.7% | 68.6% |
| EPP 컨테이너 | 143m CPU / 46Mi | 135m CPU / 51Mi |
| 토크나이저 컨테이너 | 27m CPU / 950Mi (독립 Deployment) | 3m (유휴) |

- 토크나이저는 EPP와 별도의 `Deployment`/`Service`로 기동되며 리소스(요청 1 CPU / 4Gi)를 독립적으로 갖는다.
- 텍스트 전용·소형 모델에서는 내장 추정만으로 적중률이 동일하였고, 외부 호출 지연만 추가되었다.
- 외부 토크나이저의 효용은 정확한 토큰화가 필요한 멀티모달 입력(시나리오 24)에서 검증한다.

## 검증 필요 사항

- 토크나이저 `Deployment`의 replica를 `LLMInferenceService`에서 선언적으로 조정하는 방법
  (스키마상 `tokenizer`에는 `template`만 존재)
- 멀티 아키텍처(Arm/Power) 시연은 현 클러스터(x86 전용) 범위 밖
