# 시나리오 23: 추론 인지 Pod 라이프사이클 관리

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** EPP endpoint 관리, vLLM readiness, `Deployment` rolling update

## 목적

롤링 업데이트 및 스케일아웃 중 모델 가중치를 로딩하는 pod로 요청이 라우팅되지 않음을 검증한다.
시나리오 12(단일 replica pod 삭제, 384초 다운타임)의 대조 실험으로서, 계획된 변경 시 요청 유실이
0건임을 보이는 것이 목표이다.

## 구성

- `LLMInferenceService` replica 1 → 롤링 업데이트(maxSurge 1)로 GPU 2 사용
- EPP 활성화, 지속 트래픽 클라이언트(1초 간격, 성공/실패 자체 집계)

## 절차

```sh
NS=llmd-s24; NAME=llmd-lifecycle
# 1) 지속 트래픽 시작 (Gateway 경유, 클라이언트 측 HTTP 코드 기록)
# 2) 롤링 업데이트 유발: 엔진 인자 변경
oc patch llminferenceservice $NAME -n $NS --type=merge -p \
  '{"spec":{"template":{"containers":[{"name":"main","env":[{"name":"VLLM_ADDITIONAL_ARGS","value":"--max-model-len=8192 --enforce-eager --gpu-memory-utilization=0.85 --max-num-seqs=64"}]}]}}}'
# 3) 신규 pod 상태와 EPP의 endpoint 편입 시점 관찰
oc get pods -n $NS -l app.kubernetes.io/name=$NAME -w
oc logs -n $NS deploy/${NAME}-kserve-router-scheduler -f | grep -iE 'endpoint|pod'
# 4) 스케일아웃(replicas 1→2) 중 동일 관찰
oc patch llminferenceservice $NAME -n $NS --type=merge -p '{"spec":{"replicas":2}}'
```

## 판정 기준

| 지표 | 통과 조건 |
|---|---|
| 클라이언트 실패(비-2xx, 연결 오류) | 0건 |
| 신규 pod로의 첫 요청 시각 | 해당 pod `Ready=True` 전환 이후 |
| 구 pod 종료 | 진행 중 요청 완료 후 종료(graceful drain) |

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, T4 × 2 replica, MaaS Gateway 경유)

**통과.** 컨트롤러가 생성한 워크로드 `Deployment`의 구성은 다음과 같다.

| 항목 | 값 | 의미 |
|---|---|---|
| strategy | RollingUpdate, maxSurge 25%, maxUnavailable 25% | replica 2 → 증설 1, 감소 0 |
| readinessProbe | HTTPS `/health`, period 1s, failureThreshold 2 | 가중치 적재 완료 전 Ready 불가 |
| preStop / grace | `sleep 15` / 60s | 종료 전 진행 중 요청 소진 |

절차: 지속 트래픽(동시성 2, 0.5초 간격, 20분) 중 `VLLM_ADDITIONAL_ARGS`를 변경하여 롤링 업데이트를 유발.

| 시각(UTC) | 이벤트 |
|---|---|
| 07:52:22 | 업데이트 적용 → 신규 pod ① 생성(여유 GPU) |
| 07:54:53 | pod ① Ready(가중치 적재 2분 30초) → 즉시 기존 pod 1개 Terminating |
| 07:55:14 | 기존 pod 종료 완료(preStop 15초 포함 20초) |
| 07:55:19 | 신규 pod ② 생성(이미지 미보유 노드, 이미지 수신 약 7분) |
| 08:02:34 | pod ② Ready → 마지막 기존 pod Terminating |
| 08:03:02 | 롤아웃 완료(총 10분 40초) |

| 구간 | 요청 | 비-200 |
|---|---|---|
| 롤아웃 전 | 14 | 0 |
| 롤아웃 중(640초) | 1,056 | 1 |
| 롤아웃 후 | 916 | 2 |

- 롤아웃 중 발생한 1건(t=329s)은 pod 전환 시점(t=159s, t=620s)과 무관하며, 롤아웃 이후에도 동일 유형이 2건 발생하였다.
- 원인은 라이프사이클이 아닌 **MaaS 인증 경로의 타임아웃**이다(아래). 즉 pod 교체로 인한 요청 유실은 0건이다.
- EPP는 신규 pod를 Ready 전환 이후에만 후보로 편입하였고, 종료 중인 pod로의 신규 요청은 관측되지 않았다.

## 발견 사항: 산발적 HTTP 500의 원인

- Gateway access log에서 해당 요청은 upstream 연결 없이 약 203~207ms 후 500으로 종료되었고, 동시에
  `kuadrant_wasm_shim: gRPC status code is not OK`가 기록되었다.
- Kuadrant wasm 설정(`oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o yaml`)의
  인증 서비스는 `timeout: 200ms`, `failureMode: deny`이다.
- `oc`/ServiceAccount 토큰은 요청마다 Authorino가 kube API에 TokenReview를 수행하며, control plane
  부하 시 200ms를 초과한다.
- 대응: 클라이언트는 MaaS API 키(`sk-oai-…`)를 사용한다(`./harness.sh maas-api-key`).
  API 키 경로에서도 빈도는 낮아졌으나 발생하였다(시나리오 26: 1,300~1,400 요청당 1~6건, 약 0.1~0.4%).
  Kuadrant CR에는 인증 타임아웃 조정 필드가 없어, 클라이언트 재시도로 대응한다.

## 검증 필요 사항

- GPU 여유가 없을 때(maxSurge 불가) 동작: 신규 pod `Pending` 상태에서 구 pod 유지 여부
