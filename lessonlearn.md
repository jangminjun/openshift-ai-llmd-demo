# Lessons Learned

프로젝트 수행 중 발견한 이슈와 원래 가정이 틀렸던 부분을 기록. 시간순 누적, 최신이 위로.

## 2026-09-29 — sandbox3444 신규 클러스터 준비

- **MaaS 인증 전 요청 500 (Authorino TLS 불일치).** odh-model-controller가 생성하는
  `maas-default-gateway-authn-ssl` EnvoyFilter는 Authorino(50051)에 TLS로 접속하나, `maas.sh`는 listener TLS를
  끄고 있었다. 인증이 필요한 모든 요청이 upstream 없이 500을 반환하고, Gateway 로그에 wasm-shim
  `gRPC status code is not OK`가 남는다. `/health`만 200이다. listener TLS를 켜고 service-CA 인증서
  `authorino-server-cert`를 사용하여 해결하였으며 `maas.sh`에 반영하였다.
  ```sh
  oc patch authorino authorino -n kuadrant-system --type=merge \
    -p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
  ```
- **콘솔 Observe → Traces는 멀티테넌시 Tempo만 표시한다.** 멀티테넌시 없는 TempoMonolithic은 플러그인의
  `list-tempo-resources`에서 제외된다. 멀티테넌시(`mode: openshift`) Tempo는 인증된 쓰기만 받으므로 vLLM·EPP 앞에
  OTel Collector를 두고 SA 토큰(`bearertokenauth`)과 `X-Scope-OrgID`를 붙인다. heredoc(`<<YAML`) 안의 백틱은 명령으로
  실행되므로 주석에도 쓰지 않는다.
- **InferencePool `FailClose`가 Envoy에 반영되지 않는다.** `LLMInferenceService.spec.router.scheduler.pool.spec`로
  `failureMode: FailClose`를 지정하면 `InferencePool`은 바뀌지만, `maas-default-gateway` Envoy의 라우트별 `ext_proc`
  설정은 `failure_mode_allow: true`를 유지하였다(OCP 4.22, `istiod-openshift-gateway`, 3분 이상 관찰). EPP 장애 시
  항상 FailOpen으로 동작한다(시나리오 12 C에서 32초간 무중단).
- **부하 생성기 문서 본문이 단일 단어 반복이었다.** `loadgen.py`가 단어마다 `random.Random(seed)`를 새로 만들어
  `shared-prefix`·`multi-prefix`·`multi-turn` 문서가 한 단어의 반복이 되었다(수정: 문서당 RNG 1개). 문서 번호가
  선두에 있어 prefix는 문서별로 고유하므로 캐시·분배 결과(시나리오 11, 22, 27)는 유효하나, 내용의 현실성은 낮았다.
- **MaaS 500의 실체는 Authorino 평가 기한 초과.** 500 응답은 약 200ms, 23바이트, upstream 없음이며, 같은
  request id의 Authorino 응답은 `UNAVAILABLE`(평가가 200ms 기한 초과로 취소)이다. Authorino 평가 시간은 98.1%가
  100ms 이하이나 1.6%가 100~200ms, 0.3%가 200ms를 넘는다. 주원인은 부하 시작 시의 동시 첫 요청으로, maas-api
  API 키 검증이 최대 135~210ms로 지연되었다(22건 중 19건). 나머지는 maas-api가 1ms 미만인 시점의 꼬리 지연이며
  GC(최대 12ms)는 원인이 아니다. Authorino는 replica 1, resource requests 없음이다. 추적 방법은 다음과 같다.
  ```sh
  oc logs -n openshift-ingress deploy/maas-default-gateway-maas-gateway-class | grep '" 500 '   # request id 확보
  oc logs -n kuadrant-system deploy/authorino | grep <request-id>                              # UNAVAILABLE 확인
  oc get --raw /api/v1/namespaces/kuadrant-system/services/authorino-controller-metrics:8080/proxy/server-metrics \
    | grep auth_server_response_status
  ```
- **GPU 증설 시 AZ 재고 부족.** GPU MachineSet이 단일 AZ(us-east-1c)에 고정되어 있어, 같은 타입
  g5.24xlarge의 두 번째 인스턴스가 `InsufficientInstanceCapacity`로 생성되지 않았다. Machine은 오류 없이
  `Provisioning`에 머무르므로, 원인은 `machine-api-controllers`의 `machine-controller` 로그에서 확인한다.
  증설이 필요하면 다른 AZ에 MachineSet을 복제하거나, 한 노드의 GPU 4장 안에서 시나리오를 수행한다.
- **MinIO 공개 이미지 사용 불가.** `quay.io/minio/minio`, `docker.io/minio/minio` 모두 pull이 거부된다
  (`unauthorized`). `tracing`을 TempoStack(S3) 대신 TempoMonolithic(PV 저장)으로 전환하였다. OTLP 수신은
  `tempo-llmd-tracing:4317`, Jaeger API는 `svc/tempo-llmd-tracing-jaegerui:16686`이었다(이후 멀티테넌시로 변경, 아래 항목).

## 2026-09-23 — RHOAI 3.5.1(sandbox1314)에서 하네스 재검증

- **bastion 의존 제거.** bastion SSH 키가 AWS 등록 키와 불일치하여 접속 불가. `remote/*.sh`는 `oc`만
  필요하므로 `HARNESS_EXEC=local|bastion|auto`를 도입하여 로컬 `oc login` 세션으로 실행한다.
- **기본 클러스터에 관측 스택 누락.** UWM 미활성, Grafana 미설치 상태였다(AGENT.md 기재와 불일치).
  `./harness.sh llmd-prereq`로 점검·준비한다.
- **GPU 사양 불일치.** 기본값 g5.2xlarge/16Gi는 g4dn.xlarge(할당 가능 메모리 약 14Gi)에서 스케줄 불가.
  GPU 타입은 자동 탐지, 모델·메모리 기본값은 `config.env`에서 관리한다.
- **EPP는 별도 설치 대상이 아니다.** `spec.router.scheduler`가 있어야 컨트롤러가 EPP와 `InferencePool`을
  생성한다. 없으면 `HTTPRoute`가 워크로드 `Service`로 직결된다. `llmd-deploy-model`은 이제 기본으로 EPP를 활성화한다(`LLMD_SCHEDULER`).
- **업데이트 직후 Ready는 이전 세대 값이다.** scheduler 추가 직후 Ready=True가 즉시 반환되었다.
  `metadata.generation == status.observedGeneration`을 함께 확인한다.
- **MaaS 경로의 버전 차이.** 3.5는 DSC `aigateway.modelsAsAService`, Authorino listener TLS on(2026-09-29 정정),
  `maas-default-gateway` 필수. `./harness.sh maas`가 버전을 판별하여 스크립트를 선택한다.
  MaaS 게이트웨이 호출은 `MaaSSubscription`이 없으면 403(`no matching subscription`)이다.
- **같은 Gateway의 다중 InferencePool에서 ext_proc 오배정(OCP 4.22 Gateway, istio-pilot).** EPP가 활성화된
  `LLMInferenceService` 두 개(`llmd-test`, `llmd-vlm`)를 `maas-default-gateway`에 붙이면, Envoy의 모든
  InferencePool route가 **마지막에 생성된 EPP**(`llmd-vlm-epp-service`)로 ext_proc을 보낸다. 결과적으로
  `llmd-test` 요청이 VLM EPP에서 `503 failed to find endpoint candidates`로 실패했다. 두 번째 풀을 삭제하자
  즉시 복구되었다. 확인 방법:
  `oc exec -n openshift-ingress <gateway-pod> -- pilot-agent request GET config_dump`에서 route별
  `typed_per_filter_config`의 ext_proc 대상 클러스터(`outbound|9002||<name>-epp-service...`)를 확인한다.
  운영 지침: EPP 활성 모델은 Gateway당 1개로 제한하거나, 모델별 Gateway를 분리한다.
- **MaaS 인증 주체.** `oc` 토큰의 TokenReview 그룹에는 OpenShift `Group`이 포함되지 않는다
  (`system:authenticated*`만 포함). `MaaSSubscription.owner.users`/`MaaSAuthPolicy.subjects.users`에 사용자를
  직접 지정해야 한다. ServiceAccount(`system:serviceaccount:…`)는 `Group` 멤버가 될 수 없다.
  MaaS 구독 결과는 Authorino에서 60초 캐시되므로 변경 후 60초 뒤에 검증한다.
- **EPP 인라인 설정 변경의 함정 두 가지.** (1) `spec.router.scheduler.config`를 제거해도 EPP
  `--config-text`는 마지막 인라인 값으로 남는다. (2) merge 패치로 인라인 설정을 바꾸면 새 설정에 없는 키
  (`featureGates`, `flowControl`)가 잔존하여, 존재하지 않는 plugin 참조로 EPP가 CrashLoop에 빠졌다.
  인라인 설정은 `oc patch --type=json`의 `replace`로 전체 교체한다.
- **Flow Control 우선순위와 saturation detector.** `utilization-detector`는 폴링 지연으로 vLLM 내부 대기열이
  임계값을 크게 초과(15 vs 2)하여 우선순위가 무력화되었다. `concurrency-detector`(open-loop 계수)로 해결
  (대화형 TTFT 1.7 s vs 24.3 s). `saturationDetector`는 `flowControl` 아래에 둔다.
- **외부 토크나이저는 두 단계 설정이 필요.** `tokenizer: {}`(빈 객체)는 저장 시 제거되어 무효이며
  `baseRefs: [{name: v3-5-1-kserve-config-llm-tokenizer}]`로 서비스를 띄운다. preset은 EPP를 연결하지 않으므로
  `token-producer`를 추가하고 `modelName`을 render 서버 모델 ID(`/mnt/models/base`)로 둔다. 서빙 모델명을
  쓰면 render 404 → prefix Scorer 0점으로 캐시 인지 라우팅이 무력화된다.
- **MaaS non-streaming 응답 본문 유실.** `stream: false` 응답의 30~40%가 HTTP 200, 본문 0바이트였다(EPP 유무
  무관). Gateway 로그에 Kuadrant wasm-shim `proxy_on_grpc_receive invalid context_id`가 동반된다. 스트리밍은
  정상이며 토큰 한도는 두 방식 모두 적용된다. MaaS 클라이언트는 `stream: true`를 사용한다.
- **MaaS 인증 200ms 타임아웃.** Kuadrant wasm 설정(`envoyfilter kuadrant-maas-default-gateway`)의 인증
  서비스는 `timeout: 200ms`, `failureMode: deny`이다. Authorino의 TokenReview/maas-api 호출이 지연되면 500이
  발생한다(0.1~0.4%). API 키(`./harness.sh maas-api-key`)로 빈도를 낮춘다. Kuadrant CR에는 조정 필드가 없다.
- **LLM TLS 설정 경로.** DSC `spec.components.kserve.enableLLMInferenceServiceTLS`가 공식 경로이며,
  `inferenceservice-config`는 operator 소유라 직접 수정하지 않는다.
- **Tempo Jaeger UI Route.** 수동 `oc expose` Route는 Tempo operator가 제거한다. TempoStack
  `jaegerQuery.ingress.type: route`를 사용한다(OpenShift OAuth 보호, API는 port-forward로 접근).
- **Windows(Git Bash) 로컬 실행의 경로 변환.** Git Bash는 네이티브 프로그램의 argv 중 `/`로 시작하는 값을
  Windows 경로로 바꾼다(`/mnt/models/base` → `C:/Program Files/Git/mnt/models/base`). 하네스가 EPP
  `token-producer.modelName`에 변환된 값을 넣어 render 404 → prefix Scorer 0점이 되었다. `MSYS_NO_PATHCONV=1`을
  전역으로 켜면 반대로 `oc --from-file=$HOME/...` 같은 실제 파일 경로가 깨진다. 컨테이너 내부 경로는
  argv 대신 stdin으로 전달한다(`remote/scenario28-tokenizer.sh`).
- **롤링 재기동에는 여유 GPU 1장이 필요.** 워크로드 `Deployment`는 maxSurge 1 / maxUnavailable 0이므로 GPU가
  모두 사용 중이면 신규 pod가 `Pending`으로 남아 롤아웃이 멈춘다. vLLM 인자·트레이싱·TLS 변경 전
  `require_free_gpu`로 점검한다.
- **g4dn.xlarge 메모리 한도.** 할당 가능 메모리 약 14Gi에서 데몬셋 요청을 제외하면 모델 컨테이너는
  8Gi 수준이 상한이다(12Gi는 `Insufficient memory`).
- **미해결: `openshift-ai-inference` Gateway Envoy segfault.** EPP 활성 모델의 `HTTPRoute`를 이
  Gateway로 전환한 직후(06:29) Envoy가 segfault로 재시작되고 HPA가 10개로 확장했으며, 이후 요청은 500을 반환했다
  (EPP는 대상 선택 로그를 남겼으나 vLLM에 요청 미도달). `maas-default-gateway`로 원복 후 추가 재시작은 없다.
  EPP 경유 E2E 추론 검증은 MaaS 모델 등록 후 `maas-default-gateway`에서 수행할 예정이다.

## 2026-09-09 (2) — Jaeger Route를 `harness/remote/tracing.sh`를 안 거치고 수동으로 만들어서
직접 겪은 시행착오 (하네스 자체는 문제 없었음)

Tempo Jaeger UI Route가 없길래 `./harness.sh tracing`을 다시 돌리는 대신 `oc expose
svc/tempo-llmd-tracing-query-frontend --port=jaeger-ui`를 직접 실행했다. Route는 생성됐고
`http://`는 200이 나왔지만, `https://`로 열면 라우터가 503(기본 에러 페이지)을 반환했다 —
`oc expose`는 `spec.tls`가 없는 http 전용 Route를 만들기 때문. 나중에 `harness/remote/tracing.sh`
소스를 다시 읽어보니 이미 이 문제를 알고(2026-09-08(4) 항목의 포트 이름 gotcha 옆에 주석으로
남겨둠) `oc expose` 직후 `oc patch route ... -p '{"spec":{"tls":{"termination":"edge",
"insecureEdgeTerminationPolicy":"Redirect"}}}'`를 자동으로 붙이고, 이름도
`llmd-tracing-jaeger-ui`로 고정해뒀다 — **하네스 스크립트는 이미 맞게 짜여 있었고, 내가 그
스크립트를 확인하지 않고 임의로 재현해서 시간을 낭비한 것.** **교훈: 리포에 이미 전용
스크립트/하네스 커맨드가 있는 작업은 스크립트를 다시 읽거나 그냥 하네스 커맨드를 재실행하는
쪽을 먼저 시도할 것 — 겉보기에 간단해 보이는 `oc expose` 한 줄도, 이미 과거에 겪은 gotcha를
피하려고 몇 단계가 더 붙어있을 수 있다.**

## 2026-09-09 — 프로젝트 재사용성 점검 중 발견: AGENT.md가 커밋된 적 없음

README와 lessonlearn.md 여러 곳에서 `AGENT.md`(클러스터 접속 정보, 실측 아키텍처 요약,
"다음 세션 재개용")를 핵심 참조 문서로 안내하는데, 실제로는 `.gitignore`에 등록되어 있고
git 히스토리에도 커밋된 적이 없었다 — 즉 README의 재현 절차를 그대로 따라가면 1단계부터
존재하지 않는 파일을 참고하게 되는 상태였다. 클러스터별 비밀정보(관리자 비밀번호, bastion IP
등)가 들어가서 의도적으로 gitignore한 것으로 보이지만, 그 결과 새 세션/새 사람이 이 리포만
받았을 때 "무엇을 채워야 하는지" 알 방법이 없었다. **교훈: 비밀정보가 들어가서 커밋하지 않는
파일이라도, 그 파일이 어떤 항목을 담아야 하는지 보여주는 템플릿(`*.example`)은 커밋해둬야
"불러서 바로 사용 가능"이 실제로 성립한다 — README에 파일명만 언급하는 것으로는 부족하다.**
`AGENT.md.example`을 추가해 해결.

## 2026-09-08 (4) — 하네스 리포 재구성 + UI(Grafana/Jaeger) 접근 검증

1. **GrafanaDashboard CR의 `datasources`(이름 기반) 입력 매핑이 실제로는 안 먹는다.** `datasources:
   [{ inputName: "DS_THANOS", datasourceName: "thanos-querier" }]`로 지정하면 대시보드 JSON의
   `${DS_THANOS}`가 datasource **이름 문자열 "thanos-querier"**로 치환되는데, Grafana의 실제 패널
   렌더링(`/api/ds/query`)은 **UID**를 요구한다 — 이름과 UID는 다른 값이고, UID는 Grafana가 매번 무작위로
   생성해서 클러스터를 다시 만들 때마다 바뀐다(예전 클러스터 `93691e62-...` → 이번 `ceb9310e-...`). 그
   결과 대시보드는 "정상 생성"됐다고 나오지만 실제로 열어보면 패널마다 "Data source not found"가 뜨는
   상태였다. 심지어 기존에 잘 동작한다고 믿었던 Tier1/Tier2 GPU 대시보드도 같은 패턴(`datasource:
   "thanos-querier"` 문자열)이라 원리적으로는 똑같이 깨져있을 수 있다(재확인 필요).
   **해결:** `GrafanaDatasource` CR이 실제 UID를 `.status.uid`에 발행해준다 — 이걸 직접 조회해서
   대시보드 JSON의 `${DS_THANOS}`를 `sed`로 우리가 직접 치환한 뒤 적용하도록 `llmd-monitoring.sh`를
   고쳤다(더 이상 CR의 `datasources` 매핑에 의존하지 않음). **교훈: 오퍼레이터가 제공하는 "편의
   기능"(이름→UID 자동 매핑)이 실제로 그 오퍼레이터/버전에서 동작하는지 반드시 API 레벨(`/api/ds/query`)로
   직접 검증할 것 — "대시보드가 생성됐다"는 "패널에 데이터가 뜬다"의 증거가 아니다.**

2. **Grafana admin 비밀번호는 클러스터마다 랜덤 생성된다** (`oc get secret
   gpu-grafana-admin-credentials -n gpu-monitoring`) — 예전 클러스터 문서에 있던 `admin/redhat`을 그대로
   썼다가 401을 받았다. AGENT.md에 하드코딩하지 말고 조회 명령만 남겨둘 것.

3. **Tempo의 Jaeger UI를 Route로 노출하려면 서비스 포트 이름을 정확히 써야 한다** (`jaeger-ui`, 임의로
   지은 `16686-tcp` 같은 이름 아님) — 틀린 이름으로 `oc expose --port=`를 하면 Route는 만들어지지만
   백엔드가 실제로는 살아있는데도(`oc port-forward`로는 정상 응답) 라우터가 계속 503을 준다, 에러
   메시지도 없어서 원인 파악에 시간이 걸렸다. `tracing.sh`에 올바른 포트명으로 Route 생성을 자동화해뒀다.

4. **하네스 리포 재구성:** `openshift-aws-harness`는 기본 클러스터 설치(bastion/OpenShift/GPU/RHOAI/
   모니터링/로깅)만 담당하도록 되돌리고, MaaS/llm-d 모델 배포/트레이싱/시나리오 11-14는 전부 이 리포의
   `harness/`로 옮겼다 — 같은 bastion에 SSH로 붙는 방식은 동일(`harness/config.env`의 `BASTION_IP`/
   `SSH_KEY_PATH`).

## 2026-09-08 (3) — 시나리오 11/13 실행하며 잡은 것들

1. **`LLMD_EXTRA_VLLM_ARGS`를 세팅해놓고 SSH로 전달을 안 함.** `cmd_scenario13_llmd_tracing_demo`가
   `LLMD_EXTRA_VLLM_ARGS`를 export했지만, 정작 `cmd_llmd_deploy_model`이 bastion으로 SSH 커맨드를 만들
   때 명시적으로 나열하는 env var 목록에 그 이름이 빠져 있어서 **한 번도 전달된 적이 없었다** — vLLM은
   트레이싱 플래그 없이 뜨고, trace는 0건. 겉보기엔 스크립트가 성공(exit 0)했는데 실제 동작은 의도와
   다른, 가장 발견하기 어려운 유형의 버그였다. **교훈: 새 env var를 원격 스크립트에 추가할 때마다,
   그걸 실제로 호출하는 `cmd_*` 함수의 SSH 커맨드 문자열에도 추가했는지 반드시 같이 확인할 것** —
   두 곳이 따로 놀 수 있는 구조라 한쪽만 고치기 쉽다.

2. **GPU 1장/노드 클러스터에서 LLMInferenceService spec을 바꾸면(예: 트레이싱 플래그 추가) 예전 pod만
   지워선 안 되고, 예전 ReplicaSet 자체를 0으로 스케일해야 한다.** 예전 pod를 지워도 ReplicaSet이
   즉시 새로 만들어버려서 GPU를 계속 붙잡고, 새 스펙의 ReplicaSet은 영원히 `Pending`으로 남는다 —
   `openshift-aws-harness`의 scenario8 스크립트 주석에 이미 기록돼 있던 gotcha가 `LLMInferenceService`
   (KServe v1alpha2)에서도 똑같이 재현된 것. 이 상태를 cluster-autoscaler가 "자리가 없다"고 오판해서
   불필요한 GPU 노드를 추가로 띄우기도 했다 — 진짜 원인(예전 ReplicaSet의 점유)을 안 고치면 계속
   노드만 늘어나는 악순환이 될 수 있다.

3. **DP(데이터 병렬화) 스루풋 테스트는 부하(concurrency)를 replica 수에 비례해서 늘려야 의미가 있다.**
   고정된 concurrency로 1→2 replica 비교했더니 처리량이 겨우 +10%였다 — replica를 늘려도 클라이언트가
   보내는 동시 요청 총량이 그대로면, 이미 포화 안 된 상태에서 pod 하나가 더 생겨봐야 나눠 받는 요청
   수만 줄지 총 처리량은 별로 안 늘어난다. 처음엔 "EPP가 제대로 분산 안 하나?"로 의심했지만, 실제
   원인은 테스트 설계(고정 부하) 쪽이었다.

4. **한 클러스터에서 여러 llm-d 시나리오를 동시에 돌리려면 시나리오 수만큼 GPU를 미리 확보해야 한다.**
   GPU가 노드당 1장뿐이면 시나리오 A의 모델이 떠 있는 동안 시나리오 B가 replica를 늘리려 해도 스케줄이
   안 된다 — 이미 결과를 다 뽑은 시나리오는 다음 시나리오 전에 정리(`*-stop`)해서 GPU를 돌려줘야 했다.

## 2026-09-08 (2) — 시나리오 11~14 실제 실행하며 잡은 하네스 버그들

시나리오12/14를 실제로 처음 돌려보니 전부 데이터가 텅 비어 나왔다(NaN, 0건). 만든 지 얼마 안 된
스크립트를 실행 전에 검증 없이 믿었던 게 원인 — 아래 순서로 하나씩 잡았다 (모두 `openshift-aws-harness`
커밋됨).

1. **모든 부하 스크립트가 `"model":"placeholder"`를 하드코딩.** vLLM의 OpenAI 호환 API는 `model`
   필드가 실제 로드된 모델명과 정확히 일치해야 하고, 안 맞으면 즉시 404(엔진에 진입도 안 함)로 거부한다.
   그래서 부하가 전부 404만 만들고 진짜 생성 트래픽은 단 한 건도 없었던 것 — latency 진단 리포트가 전부
   `NaN`/0으로 나온 이유. **교훈: 모델 서빙 API에 "아무 이름"을 넣고 테스트하지 말 것 — 실제 배포된
   `LLMInferenceService`의 `.spec.model.name`을 조회해서 써야 한다.** 이 실패 모드는 오히려 알아채기
   쉬웠다 (지표가 통째로 비어 나오니 뭔가 잘못됐다는 신호가 명확함) — 애매하게 "조금 이상한 값"이
   나왔다면 더 오래 못 알아챘을 수 있다.

2. **bastion에서 `oc whoami -t`는 항상 실패한다.** `~/ocp-install/auth/kubeconfig`는 설치 시 생성된
   client-cert 기반 system:admin 컨텍스트라 OAuth 토큰이 없다 (로컬에서 `oc login -u admin -p ...`로
   htpasswd 로그인했을 때와는 다름). Thanos-querier 같은 걸 bearer 토큰으로 조회하려면
   `cluster-monitoring-view` ClusterRole을 바인딩한 전용 ServiceAccount로 `oc create token`을 써야 함.

3. **LLMInferenceService의 게이트웨이 이름을 이전 클러스터 값(`maas-default-gateway`)으로 하드코딩.**
   이 클러스터(우리 `maas.sh`로 세팅)의 실제 게이트웨이는 `openshift-ai-inference`라, 모델 pod는
   `WorkloadsReady=True`로 멀쩡히 떠 있는데 `GatewaysReady=False`라 전체 `Ready`는 계속 False였다 —
   `llmd-deploy-model.sh`의 자체 10분 대기 루프가 결국 타임아웃되어 "NOT Ready"로 잘못 보고했다. **교훈:
   이전 클러스터에서 관찰한 리소스 이름을 새 클러스터에 그대로 하드코딩하지 말 것** — 이번엔
   `maas-default-gateway` 우선 탐색 → 없으면 `openshift-ai-inference` → 그래도 없으면 첫 번째 Gateway,
   순으로 자동 탐지하도록 고쳤다.

4. **재시도/폴링 루프가 타임아웃돼도 "성공"이라고 잘못 출력하는 패턴이 두 군데 있었다** —
   (a) `llmd-deploy-model.sh`의 준비 대기 루프: 마지막 반복에서 상태를 읽은 시점과 실제 조건이 True가 된
   시점 사이에 근소한 타이밍 차이가 있어서, 루프가 끝난 뒤 바로 아래의 "정보용 `oc get`"은 이미 True를
   보여주는데 루프 자체가 캡처한 값은 여전히 stale이라 "NOT Ready"로 오판 — 조건을 한 번 더 재확인하는
   걸로 고침. (b) `scenario12-llmd-failure-trigger.sh`의 복구 대기 루프: 애초에 성공 여부를 확인하지 않고
   무조건 "New pod Ready after Ns"를 출력하고 있었음 — 실제로 이번 실행에선 우연히 진짜로 성공했지만
   (384초), 실패했어도 똑같이 "Ready"라고 거짓 보고했을 것. **교훈: 폴링 루프는 성공/타임아웃 여부를
   별도 플래그로 반드시 구분해서 출력할 것 — "루프가 끝났다"와 "원하는 상태가 됐다"는 다른 이야기다.**

5. **MinIO의 `MINIO_DEFAULT_BUCKETS`는 빈 스토리지에서 최초 부팅할 때만 버킷을 만든다.** 이미 데이터가
   있는 PVC(예: `openshift-logging.sh`가 먼저 만든 `loki-logs` 버킷)를 쓰는 MinIO에 새 버킷 이름을
   env var로 추가하고 재시작해도, **기존 데이터가 있으면 새 버킷을 실제로는 안 만든다** — 그런데도 pod는
   정상적으로 뜨고 에러도 안 나서, `tracing.sh`가 "버킷 설정 완료"라고 (틀리게) 보고했다. Tempo의
   ingester/compactor/querier/query-frontend가 전부 `The specified bucket does not exist`로
   크래시루프하고 나서야 발견. **교훈: "설정값을 넣었다"와 "그 설정이 실제로 반영됐다"는 다르다 —
   idempotent 스크립트라도 부수효과(버킷 생성 등)는 최종 상태를 직접 확인하거나(`mc ls`), 매번
   실행되는 명령(`mc mb`, 이미 있으면 별 탈 없이 넘어감)으로 만들어야 한다.** `tracing.sh`를 `mc mb`로
   버킷 존재를 직접 보장하도록 고쳤다.

6. **MinIO Deployment는 `strategy: Recreate`가 필요하다** (RWO PVC를 RollingUpdate로 건드리면
   `Multi-Attach error`로 새 pod가 영원히 안 뜸) — 위 5번을 고치다가 처음 발견. 자세한 내용은
   `openshift-aws-harness/harness/README.md`의 "Known gotchas" 참고, 여기선 중복 기록 안 함.

## 2026-09-08 — 클러스터 재구축(openshift-aws-harness) 중 발견한 것들

이전 클러스터가 삭제되어 `openshift-aws-harness`로 새 AWS 계정(sandbox3790)에 재구축하면서, 하네스
자체에 몇 가지 버그/공백을 발견해 고쳤다 (`openshift-aws-harness` 리포에 커밋됨, 여기 요약만 남김).

1. **OperatorHub `stable` 채널이 RHOAI 2.x를 가리켰다.** `remote/rhoai.sh`가 `channel: stable`로
   구독했는데, 이 계정의 카탈로그 스냅샷에서는 `stable`이 `rhods-operator.2.25.8`로 풀렸다 (직전 클러스터의
   `stable-3.4` → `3.4.4`와 다름). RHOAI 2.x에는 `modelsAsService`도, llm-d 관련 자동 wiring도 없어서
   MaaS 설정 단계에서야 `Warning: unknown field "spec.components.kserve.modelsAsService"`로 드러났다.
   **교훈: OLM 채널을 `stable`처럼 뭉뚱그려 쓰지 말고, 필요한 정확한 버전을 채널명에 명시할 것**
   (`stable-3.4`). 이미 설치된 operator를 다른 메이저 버전으로 바꾸는 건 in-place 업그레이드가 아니라
   DSC/DSCI/Subscription/CSV를 지우고 재설치해야 했다 (2.x→3.x는 아키텍처가 다름).

2. **Authorino TLS는 cert-manager가 있어야 한다.** RHOAI-Toolkit의 MaaS 설치 스크립트를 포팅하면서
   빠뜨렸던 전제조건 — `Issuer`/`Certificate` CRD(`cert-manager.io/v1`)가 없어서
   `no matches for kind "Issuer"` 에러가 났다. 예전 클러스터엔 어쩌다 이미 설치돼 있어서 이 의존성을
   몰랐던 것. `openshift-cert-manager-operator`(Red Hat 공식, `stable-v1` 채널)를 `maas.sh`의 Step 0으로
   추가해서 해결. **교훈: 이전 클러스터에서 "이미 있길래" 당연했던 전제조건은 새 클러스터에서 다시
   검증해야 한다 — 무엇이 자동으로 딸려왔는지 몰랐을 뿐일 수 있다.**

3. **bash: `${VAR:?message}` 안에 아포스트로피가 있으면 파싱이 깨진다.** 실제로 겪은 버그:
   `"${LLMD_NAMESPACE:?...the LLMInferenceService's namespace}"` — 이중따옴표로 감싸져 있는데도
   `unexpected EOF while looking for matching \`''` 에러가 남. 최소 재현: `FOO="${FOO:?it's broken}"`.
   원인은 명확히 못 밝혔지만(bash의 `:?` 파싱이 이 구문에서 홑따옴표를 특별 취급하는 것으로 보임),
   **교훈: `${VAR:?message}`의 message 안에는 아포스트로피(축약형 포함)를 아예 쓰지 말 것.**

4. **unquoted heredoc(`<<YAML`) 안의 "주석"도 사실 주석이 아니다.** `remote/dcgm-alerts.sh`에 있던
   설명용 줄 `# Tier2's $namespace dropdown...`이 `oc apply -f - <<YAML`(따옴표 없는 heredoc) 안에
   있었는데, 이 안에서는 `#`이 shell 주석으로 취급되지 않고 `$namespace`가 그대로 변수 치환 대상이 됨 —
   `namespace`가 정의된 적 없어서 `set -u`에 걸려 스크립트 전체가 죽었다(`bash: line 88: namespace:
   unbound variable`). 정작 필요한 실제 코드(`${MONITORING_NAMESPACE}` 등)는 이미 여러 곳에서 잘
   동작하고 있었기 때문에 원인 찾는 데 시간이 걸렸다. **교훈: unquoted heredoc 안에 설명을 적어야 하면
   `$`를 전부 `\$`로 이스케이프할 것 — "그냥 주석이니까 괜찮겠지"는 heredoc 안에서는 틀린 가정이다.**

5. **RHOAI 3.4 대시보드 pod는 m5.xlarge 한 대에 구조적으로 안 들어간다.** `rhods-dashboard` pod 하나가
   컨테이너 9개(model-registry-ui, gen-ai-ui, maas-ui, mlflow-ui, eval-hub-ui, automl-ui, autorag-ui
   등)로 CPU 요청 합계 ~2.8 vCPU. m5.xlarge는 allocatable이 3.5 vCPU뿐이고 DaemonSet(OVN, multus, DCGM
   등) 오버헤드만으로 ~0.87 vCPU를 먹어서, **완전히 비어있는 새 m5.xlarge 노드조차 ~2.63 vCPU밖에 못 주고
   2.8 vCPU 요청을 못 받는다** — 노드를 몇 개를 추가하든 이 한 pod는 절대 못 뜬다(실제로 4개→5개로
   늘려도 계속 Pending이었음). **교훈: `Pending` + `Insufficient cpu`를 보면 먼저 "노드가 몇 개 더
   필요한가"가 아니라 "이 pod가 요구하는 양이 인스턴스 타입 하나의 allocatable을 애초에 넘는가"부터
   계산해볼 것** (`요청량 vs allocatable - 관측된 DaemonSet 오버헤드`). 이번엔 기존 워커 MachineSet을
   복제해서 `instanceType`만 `m5.2xlarge`로 바꾼 새 MachineSet을 추가해 해결.

## 2026-09-07 (2) — prefill/decode 진짜 분산 배포 조사 (미착수, 다음 세션 이어서)

`qwen25-coder-7b`가 `llm-d.ai/role=both`(비분리)라는 걸 사용자가 지적하면서, 진짜 llm-d 분산(prefill/decode
분리) 배포를 새로 띄워보려고 조사한 내용. **클러스터에는 아무 변경도 하지 않았음** — 조사만 하고 오늘은 중단.

- **GPU 여유 재확인:** `DCGM_FI_DEV_FB_FREE` 실측 **827MiB** (T4 15GB 중 14084MiB를 기존
  `qwen25-coder-7b`가 `--gpu-memory-utilization=0.90`으로 점유). 타임슬라이싱은 메모리 풀을 나누는 게
  아니라 물리 GPU를 그대로 공유하는 방식이라, 이 상태로는 아무리 작은 모델도 새로 못 띄움. 진행하려면
  기존 인스턴스의 `gpu-memory-utilization`을 낮추거나(예: 0.5) 잠시 내려야 함.
- **인터넷 egress 됨.** 클러스터에서 `https://huggingface.co` 접근 확인(HTTP 200) — `hf://<repo>` URI로
  새 모델을 바로 받아올 수 있음 (KServe storage-initializer가 `registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9`).
- **`v3-4-4-kserve-config-llm-decode-template`(및 prefill 짝)은 생각보다 무겁다.** NIXL 기반 KV 캐시
  전송 + RoCE(RDMA) 자동 감지 스크립트가 포함된 구성. RoCE는 `KSERVE_INFER_ROCE` 환경변수로 옵션 처리되어
  있어 없어도 동작은 하겠지만(TCP fallback으로 추정), 이 클러스터 GPU 노드(g4dn.xlarge)는 RDMA 미지원이라
  실제로 정상 동작할지는 검증 전. 즉 "진짜 prefill/decode 분리"는 이 인프라에서 시도해본 적 없고
  성공 여부가 불확실함.
- **중요한 발견: EPP(스케줄러)는 prefill/decode 분리 없이도 단독으로 붙일 수 있다.**
  `v3-4-4-kserve-config-llm-scheduler` 프리셋은 EPP pod + `InferencePool`을 생성하는 독립적인 조각이고,
  `v3-4-4-kserve-config-llm-router-route`는 게이트웨이 HTTPRoute를 그 InferencePool로 연결한다. 즉
  role=both(비분리) 워크로드에 이 두 프리셋만 `baseRefs`로 추가하면 지금 비어있는
  `kserve-llm-isvc-scheduler` 메트릭을 채울 수 있다 — RDMA/NIXL 복잡도 없이 가장 리스크 낮은 경로.
- **사용자에게 두 옵션 제시함:** (A) 진짜 prefill/decode 분리(리스크 높음, 미검증 인프라) vs
  (B) EPP/스케줄러만 추가(role=both 유지, 리스크 낮음). **오늘은 결정 보류하고 세션 종료** — 다음
  세션에서 이어서 결정하면 됨. 재개 시 GPU 여유(827MiB)부터 다시 확인할 것 — 그 사이 다른 워크로드가
  더 얹혔을 수 있음.

## 2026-09-07 — 초기 QA 문서화 → 실클러스터 검증 과정에서 발견한 것들

1. **`vllm:*` 메트릭 이름 가정이 틀렸음.** 리포를 처음 작성할 때는 일반적인 vLLM 메트릭 이름
   (`vllm:time_to_first_token_seconds_bucket` 등)을 그대로 가정했는데, 이 클러스터의 llm-d는 KServe
   `LLMInferenceService`로 배포되고 컨트롤러가 relabeling으로 `kserve_` 접두사를 붙여
   `kserve_vllm:...`로 스크랩한다. **교훈: PromQL을 작성하기 전에 반드시 Thanos-querier에서
   `/api/v1/label/__name__/values`로 실제 존재하는 메트릭 이름을 확인할 것.**

2. **별도 실패 카운터(`vllm:request_failure_total`)는 존재하지 않는다.** 이것도 실측 없이 가정한 것.
   대안으로 `kserve_vllm:request_success_total{finished_reason="error"}`를 썼는데, 이마저도
   틀렸다 — 실제 부하 테스트로 확인한 결과 이 메트릭은 요청이 vLLM 엔진 생성 루프에 **진입한 뒤**
   실패한 경우만 증가시킨다. 컨텍스트 초과, 잘못된 sampling 파라미터(`n:-1`) 같은 요청 검증 단계
   거부(HTTP 4xx)는 여기 안 잡힌다. **최종적으로는 `kserve_http_requests_total{status="4xx"}`가
   맞는 지표였다.** 교훈: "에러"를 나타내는 메트릭이 하나만 있을 거라 가정하지 말고, 실제로 오류
   요청을 만들어서 어느 메트릭이 반응하는지 확인해야 한다.

3. **모델명이 틀린 요청(404)과 요청 검증 실패(400)는 각각 다른 레이어에서 처리된다.** 존재하지 않는
   모델명으로 요청하면 게이트웨이/라우팅 레벨에서 404로 거부되어 vLLM 엔진 메트릭에 아예 안 잡힌다.
   컨텍스트 초과나 잘못된 파라미터는 vLLM의 OpenAI 호환 API 레이어에서 400으로 거부되고
   `kserve_http_requests_total{status="4xx"}`로는 잡힌다. 테스트 목적(에러율 알림 검증)에 맞는 실패
   유형을 고를 때 이 차이를 알아야 한다.

4. **MaaS 외부 게이트웨이(`https://maas.apps.../...`)는 OCP 사용자 토큰으로 인증되지 않는다** (401).
   Kuadrant 기반의 별도 API 키 체계로 보임. 클러스터 내부에서 직접 검증할 때는
   `oc port-forward`로 `<isvc>-kserve-workload-svc:8000`에 바로 붙는 게 훨씬 간단하고 확실하다.

5. **`oc port-forward`가 가끔 백그라운드에서 조용히 바인딩에 실패한다** (프로세스는 떠 있지만
   "Forwarding from..." 로그가 안 찍히고, 이후 curl은 전부 `HTTP 000`). 원인은 명확히 특정 못했음
   (동시에 여러 `oc` 프로세스를 돌릴 때 클라이언트 캐시/토큰 이슈로 추정 —
   `memcache.go: "couldn't get current server API group list: ... provide credentials"` 에러가
   한 번 관측됨). **교훈: 포트포워딩을 스크립트에서 쓸 때는 "Forwarding from" 로그가 실제로 찍혔는지
   확인한 뒤, 실제 curl 한 번을 테스트로 보내 200이 오는지까지 확인하고 나서 본 작업(부하 발생 등)을
   시작해야 한다.** 준비 확인 없이 바로 루프를 돌리면 전부 조용히 실패해서 "에러율 0%"라는 잘못된
   결론을 낼 수 있다.

6. **이 클러스터의 참조 배포(`qwen25-coder-7b`)는 `llm-d.ai/role=both`(prefill/decode 비분리)라
   라우터/스케줄러(EPP) 전용 메트릭이 비어 있다.** `kserve-llm-isvc-scheduler` ServiceMonitor는
   자동으로 생성되지만 매칭되는 pod가 없다. llm-d의 EPP/스케줄러 지표까지 검증하려면 별도로
   prefill/decode 분리 배포가 필요하다 — 이번 세션에서는 GPU 제약(T4 1장) 때문에 시도하지 않음.

7. **GPU가 T4 1장뿐**(타임슬라이싱으로 2 replica 공유)이라 새 모델 인스턴스를 추가로 띄우는 결정은
   반드시 기존 워크로드와의 리소스 경합을 먼저 따져야 한다. 이번엔 기존 `qwen25-coder-7b`를
   재사용하는 쪽으로 결정함.

8. **알림 채널(Slack/이메일) 라우팅은 `AlertmanagerConfig` CR로 네임스페이스별로 설정해야 하며,
   이 클러스터엔 아직 없다.** `enableUserAlertmanagerConfig: true`라 추가는 가능하지만, TC-05는
   "firing 확인"까지만 검증했고 실제 채널 전달은 별도 후속 작업.
