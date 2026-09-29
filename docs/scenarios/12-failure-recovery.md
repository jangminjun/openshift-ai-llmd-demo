# 시나리오 12: 장애 및 복구 (Failure & Recovery)

**모듈:** 분산 환경 활용 > 장애 대응
**관련 컴포넌트:** `LLMInferenceService` workload pod, Kubernetes 스케줄러, `kserve_http_requests_total`

## 목적

llm-d로 서빙 중인 모델의 워크로드 pod가 죽었을 때(장애 상황을 인위적으로 유발) **① 요청이 얼마나
실패하는지(blast radius), ② 새 pod가 뜨기까지 얼마나 걸리는지(복구 시간)**를 실측한다. llm-d 공식
문서에 따르면 Kubernetes API 기반 서비스 디스커버리 덕분에 장애 pod에는 자동으로 트래픽이 안 가도록
격리되는데, 이걸 우리 환경에서 직접 확인한다.

## 요청 흐름 (MaaS 경유) — 장애 시 어디가 끊기나

```mermaid
flowchart LR
    C["클라이언트\n(1초 간격 지속 요청)"] --> MG["MaaS Gateway"]
    MG --> AU["Authorino"] --> LI["Limitador"] --> RT["HTTPRoute"] --> EPP["EPP"]
    EPP -->|정상| P1["vLLM pod\n(workload)"]
    EPP -.->|"❌ pod 삭제 직후\nConnection refused"| P1
    P1 -.->|"K8s가 새 pod\n스케줄→이미지풀→모델로드"| P1new["새 vLLM pod\n(Ready 전까지 여기로 못 감)"]
```

**이 시나리오가 확인하는 지점: EPP/Service가 죽은 pod로 트래픽을 계속 보내지는 않는지(격리), 그리고
새 pod가 Ready 되기까지의 공백(위 점선 구간)에 요청이 얼마나 실패하는지.** replica가 1개뿐이면 이 공백
= 전체 다운타임이다. `scenario12-llmd-failure-trigger.sh`도 자동화를 위해 워크로드 Service에 직접
요청을 보낸다 — MaaS 게이트웨이 앞단(토큰 발급, Authorino, Limitador)은 이 pod 장애와 무관하게 항상
정상 응답하므로 시나리오의 핵심(EPP 이후 구간의 장애 격리)에는 영향이 없다.

## 사전 조건

- 대상 `LLMInferenceService`가 이미 Ready 상태 (`scenario12-llmd-failure-start`가 배포)
- `openshift-ai-llmd-demo` 체크아웃, `oc login` 완료
- Thanos-querier 접근 가능 (모니터링 스택 활성화되어 있어야 함)

## 절차

```sh
cd openshift-ai-llmd-demo/harness  # 리포 루트 기준

# 1) 모델 배포 (1 replica)
LLMD_NAMESPACE=llmd-scenario12 LLMD_NAME=llmd-failure-demo ./harness.sh scenario12-llmd-failure-start

# 2) 배경 트래픽 시작 + 워크로드 pod 강제 삭제 + 복구 시간/에러 측정 (자동)
LLMD_NAMESPACE=llmd-scenario12 LLMD_NAME=llmd-failure-demo ./harness.sh scenario12-llmd-failure-trigger

# 3) 정리
LLMD_NAMESPACE=llmd-scenario12 LLMD_NAME=llmd-failure-demo ./harness.sh scenario12-llmd-failure-stop
```

`scenario12-llmd-failure-trigger`는 1초 간격 트래픽을 20초 워밍업 후 워크로드 pod를 `oc delete pod`로
강제 종료하고, 새 pod가 `Ready`가 될 때까지의 시간과 그 구간의 `kserve_http_requests_total{status=...}`
분포를 출력한다.

## 예상 결과

- pod 삭제 즉시: 해당 pod로 가던 트래픽은 실패(연결 거부/타임아웃) — 새 pod가 스케줄→이미지풀→모델
  로드→Ready까지 몇 분 걸릴 수 있음 (모델 크기에 비례, 특히 모델 다운로드가 캐시 안 돼 있으면 더 걸림).
- replica가 1개뿐이면 **그 구간 전체가 다운타임** — 이게 데이터 병렬화(시나리오 11)가 필요한 이유이기도
  함. replica가 여러 개면 죽은 pod로의 라우팅만 멈추고 나머지가 트래픽을 흡수해야 함(후속 실험 후보).
- `kserve_http_requests_total`의 `status` 분포에서 장애 구간 동안 실패(비-2xx 또는 요청 자체 실패로 카운트
  안 됨)가 관찰되어야 함.

## 실측 결과 (2026-09-08, myocp/sandbox3790, Qwen2.5-7B-Instruct, replica 1)

**통과 — 단, 중요한 함정 하나 발견.**

- 워크로드 pod 삭제 → 새 pod Ready까지 **384초(6분 24초)**. 지배 요인은 스케줄링이 아니라 **모델
  재다운로드** — `hf://` storage-initializer가 emptyDir을 써서 pod가 죽으면 캐시된 14GB 모델도 같이
  사라짐. replica 1개 환경에서는 이 6분 24초 전체가 순수 다운타임.
- 장애 구간의 `kserve_http_requests_total{status=...}` 조회 결과, **`2xx` 33건만 잡히고 실패는 전혀
  안 잡힘.** 처음엔 버그(부하 스크립트가 `"model":"placeholder"`를 하드코딩해서 vLLM이 전부 404로
  거부하던 문제)로 데이터 자체가 안 나왔던 걸 고쳤는데, 고친 뒤에도 여전히 실패 카운트는 0건.
  **이유: `kserve_http_requests_total`은 vLLM 서버가 실제로 응답을 준 요청만 집계한다 — pod가 아예
  죽어서 연결 자체가 거부/타임아웃된 요청은 서버 쪽 메트릭에 절대 안 남는다.** 즉 이 메트릭만으로는
  장애 구간의 진짜 실패율을 볼 수 없고, **클라이언트 쪽 관찰(curl 종료 코드, 부하 생성기 자체의
  성공/실패 카운트)이 있어야 blast radius를 정확히 알 수 있다** — 다음 실행 때는 부하 스크립트 자체가
  요청 성공/실패를 세도록 개선할 것.

## 겪은 이슈 (하네스 버그, 이미 수정됨)

- 부하/트리거 스크립트가 `"model":"placeholder"`를 하드코딩 → vLLM이 모델명 불일치로 전부 404 거부 →
  진짜 트래픽이 한 번도 안 감. `oc get llminferenceservice -o jsonpath='{.spec.model.name}'`로 실제
  모델명을 조회해서 쓰도록 수정.
- 복구 폴링 루프가 타임아웃돼도 "Ready"라고 잘못 출력하는 버그(실제 성공 여부 미확인) → 수정, 폴링
  한도도 5분→10분으로 확대.
- Thanos 쿼리 인증에 `oc whoami -t`를 썼는데 bastion의 kubeconfig가 인증서 기반이라 토큰이 없어서 실패
  → `cluster-monitoring-view` 바인딩된 전용 ServiceAccount 토큰으로 교체.

## 후속 실험 후보

- replica 2개 이상에서 pod 하나만 죽였을 때 나머지가 트래픽을 흡수하는지 (진짜 무중단인지) 비교
- prefill/decode 분리 배포에서 decode pod 장애 시 llm-d가 재-prefill을 수행하는지 확인 (공식 문서상
  KV 전송 실패 시 동작 — 우리 환경은 아직 미분리 배포라 검증 못함, 시나리오 15 이후로 연결)

## 현재 상태 (2026-09-08)

측정 완료 후 GPU 확보를 위해 **정리됨** (`./harness.sh scenario12-llmd-failure-stop`). 다시 보려면
`./harness.sh scenario12-llmd-failure-start`부터 재실행.
