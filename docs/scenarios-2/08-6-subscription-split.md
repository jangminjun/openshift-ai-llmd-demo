# 시나리오 2-08-6: 장문 에이전트와 대화형 요청의 구독 분리

**모듈:** 분산 환경 활용 > 서비스 거버넌스
**대상:** `llmd-pd/qwen38-int4-pd`, MaaS 구독 `llmd-demo-sub`(장문), `llmd-demo-sub-chat`(대화형)
**상태:** 실행 중

## 목적

MaaS 토큰 카운터는 구독 + 사용자 + 모델 단위이다. 장문 에이전트와 대화형 요청이 같은 카운터를 쓰면 장문의 차감이
대화형 요청까지 막는다(2-07 E2: 단문 7.2초 차단). 본 시나리오는 대화형 요청을 별도 구독으로 분리했을 때 이 연쇄 차단이
사라지는지 확인한다.

## 구성

API 키는 발급 시 하나의 구독에 묶인다(`apiKeyValidation.subscription`). 같은 사용자라도 구독이 다르면 카운터가 분리된다.

```sh
# 대화형 구독 (같은 모델, 다른 priority)
oc apply -f - <<'EOF'
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata: {name: llmd-demo-sub-chat, namespace: models-as-a-service}
spec:
  priority: 5
  owner: {groups: [{name: llmd-demo}], users: [admin]}
  modelRefs:
  - {name: qwen38-int4-pd, namespace: llmd-pd, billingRate: {perToken: "0"}, tokenRateLimits: [{limit: 20000, window: 15s}]}
EOF
oc get maassubscription -n models-as-a-service

# 구독을 지정한 API 키 발급 (maas-api, 사용자 토큰 필요)
curl -sk -X POST https://maas.<apps-domain>/maas-api/v1/api-keys -H "Authorization: Bearer $(oc whoami -t)" \
  -H 'Content-Type: application/json' -d '{"name":"llmd-loadgen-chat","subscription":"llmd-demo-sub-chat"}'
```

하네스: `KEY_NAME=llmd-loadgen-chat KEY_SECRET=loadgen-token-chat KEY_SUBSCRIPTION=llmd-demo-sub-chat ./harness.sh maas-api-key`

두 구독의 한도가 같으면 `TokenRateLimitPolicy`에는 하나의 limit로 합쳐지고 조건만 OR로 묶인다. 카운터 식에
`selected_subscription_key`가 있으므로 집계는 구독별로 분리된다.

## 실험 설계

| 항목 | 값 |
|---|---|
| 한도 | 두 구독 모두 20,000/15초 |
| 장문 | 4건 동시(키 A, `llmd-demo-sub`), 재시도 없음 |
| 단문 | 1초마다 새 요청(이전 요청 완료를 기다리지 않음), 장문 종료 후 20초까지. (a) 같은 키 A, (b) 대화형 키 B(`llmd-demo-sub-chat`) |
| 기록 | 단문의 429 수와 차단 구간, 단문 지연 |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS=split ./harness.sh scenario2-08-mitigation
```

## 결과

(실행 후 기록)
