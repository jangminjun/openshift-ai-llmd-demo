# llm-d GA 기능 데모 시나리오 개요 (21~29)

RHOAI 3.5에서 GA된 llm-d 분산 추론 기능 9종을 시나리오 21~29로 정리한다. 29(Controlled
Deployment)는 EPP 모델 2개를 동시에 요구하므로 마지막에 별도로 올리고 내린다. 각 문서는
목적 / 구성 / 사전 조건 / 절차 / 판정 기준 / 실측 결과 / 검증 필요 사항의 구조를 따른다.

## 기능–시나리오 대응

| # | 기능 | 핵심 리소스 | 최소 GPU | 문서 |
|---|---|---|---|---|
| 21 | 우선순위 기반 Flow Control | `InferenceObjective` (`llm-d.ai`) | 1 | [21](21-flow-control-priority.md) |
| 22 | EPP Scorer 개선 (4종) | `spec.router.scheduler.config` | 2 | [22](22-epp-scorers.md) |
| 23 | 추론 인지 Pod 라이프사이클 | EPP endpoint 관리, readiness | 2 | [23](23-inference-aware-lifecycle.md) |
| 24 | 멀티모달 입력 라우팅 | prefix-cache-scorer + VLM | 2 | [24](24-multimodal-routing.md) |
| 25 | E2E 분산 트레이싱 | `spec.tracing` | 1 | [25](25-e2e-tracing.md) |
| 26 | TLS 비활성화 | DSC `kserve.enableLLMInferenceServiceTLS` | 1 | [26](26-tls-disable.md) |
| 27 | Scorer 가중치 튜닝 | `EndpointPickerConfig` | 2 | [27](27-scheduler-scorer-weights.md) |
| 28 | 외부 토크나이저 분리 | `baseRefs`(tokenizer preset) + `token-producer` | 1 | [28](28-external-tokenizer.md) |
| 29 | Controlled Deployment | `spec.router.route.group` / `weight` | 2 | [29](29-controlled-deployment.md) |

## 공통 전제 (2026-09-23, RHOAI 3.5.1 클러스터 실측)

1. **EPP(스케줄러) 활성화 필수.** `spec.router`에 `scheduler`가 없으면 EPP와 `InferencePool`이
   생성되지 않고 `HTTPRoute`가 워크로드 `Service`로 직접 연결된다. 하네스 `llmd-deploy-model`은
   기본으로 EPP를 활성화한다(`LLMD_SCHEDULER=false`로 비활성).
   ```sh
   oc get httproute -n <ns> -o jsonpath='{.items[*].spec.rules[0].backendRefs[0].kind}'  # InferencePool이어야 함
   oc get inferencepool,deploy -n <ns>                                                    # *-epp 확인
   ```
   시나리오 21~24, 27~29는 다음 설정을 전제로 한다.
   ```yaml
   spec:
     router:
       gateway: {refs: [{name: maas-default-gateway, namespace: openshift-ingress}]}
       route: {}
       scheduler: {}
   ```
2. **기본 preset.** 컨트롤러는 `redhat-ods-applications`의 `LLMInferenceServiceConfig`
   (`v3-5-1-kserve-config-llm-{scheduler,tokenizer,tracing,...}`)를 기본값으로 병합한다.
   ```sh
   oc get llminferenceserviceconfig -n redhat-ods-applications
   ```
3. **GPU 예산.** g4dn.xlarge(T4 16GB × 1) 기준, 시나리오 21~28은 `llmd-test`(replica 2)로 GPU 2장,
   시나리오 29는 v1/v2로 GPU 2장을 사용한다(동시 운영 불가). 스케일 아웃 시 MachineAutoscaler 범위를 함께 조정한다.
   ```sh
   oc scale machineset <gpu-machineset> -n openshift-machine-api --replicas=N
   oc patch machineautoscaler <name> -n openshift-machine-api --type=merge -p '{"spec":{"minReplicas":N,"maxReplicas":N}}'
   ```
4. **모델.** T4 기준 텍스트 모델은 `Qwen/Qwen2.5-1.5B-Instruct`, 멀티모달은
   `Qwen/Qwen2.5-VL-3B-Instruct`를 기본으로 한다. 포화 유도가 필요한 시나리오는
   `--max-num-seqs`를 낮춰 적은 부하로 포화 상태를 재현한다.
5. **관측.** `./harness.sh llmd-prereq`로 User Workload Monitoring과 Grafana를 준비한다.
   실패율은 서버 메트릭이 아닌 클라이언트 측 집계로 판정한다(시나리오 12 교훈).

## 하네스 (2026-09-23 구현·검증)

| 명령 | 용도 |
|---|---|
| `llmd-prereq` | UWM, Grafana, CRD, Gateway, 여유 GPU 점검·준비 |
| `maas` / `maas-register-model` / `maas-api-key` | MaaS 설치(버전 자동 판별), 모델 등록, API 키 발급 |
| `llmd-deploy-model` | `LLMInferenceService` 배포(EPP 기본 활성, `LLMD_SCHEDULER=false`로 비활성) |
| `llmd-loadgen` | 클러스터 내 부하 Job(스트리밍 TTFT/E2E, 클라이언트 측 코드 집계) |
| `llmd-promql` | Thanos 즉시 조회 |
| `tracing` | Tempo + Jaeger UI(operator 관리 Route), MinIO 자동 배포 |
| `llmd-test-down` / `llmd-test-up` | 데모 모델 내리기·복구(`manifests/llmd-test-llminferenceservice.json`) |
| `scenario21-…` ~ `scenario29-…` | 시나리오별 측정 자동화(각 문서 "하네스 실행"). 종료 시 EPP 설정 원복 |
| `maas-checks` | `MAAS_CHECK=nonstream`(빈 본문 발생률), `MAAS_CHECK=token-limit`(한도 적용, 원복) |

시나리오 스크립트는 `remote/lib/bench.sh`를 앞에 붙여 실행되며, 다른 EPP 모델 존재(`require_single_epp`)와
롤링 재기동용 여유 GPU(`require_free_gpu`)를 사전 점검한다. `S2x_*` 환경변수로 규모를 조정한다.

## 시연 시 공통 제약 (실측)

1. **Gateway당 EPP 활성 모델 1개.** 2개 이상이면 ext_proc이 마지막 EPP로 오배정된다(시나리오 29 참조).
2. **MaaS 클라이언트는 `stream: true`와 API 키를 사용한다.** non-streaming 응답의 30~40%가 빈 본문으로
   반환되며(Kuadrant wasm-shim), `oc`/SA 토큰은 인증 200ms 타임아웃으로 산발적 500을 유발한다.
3. **EPP 인라인 설정은 JSON 패치 `replace`로 전체 교체한다.** merge 패치는 이전 키를 남겨 EPP를
   CrashLoop에 빠뜨릴 수 있고, `config` 제거는 기본값으로 복귀시키지 않는다.
4. **포화 기반 기능(21)은 `concurrency-detector`를 사용한다.**

## 하네스 검증 (2026-09-23, 축소 규모 1회 실행)

| 명령 | 결과 | 재현된 핵심 지표 |
|---|---|---|
| `scenario21-llmd-flow-control` | 통과 | 대화형 TTFT 1.97 s vs 대조군 25.9 s, EPP 큐 1.4 s vs 21.0 s |
| `scenario22-llmd-epp-scorers` | 통과 | prefix 적중률 74.6% vs 56.3%, TTFT p50 0.46 s vs 1.86 s |
| `scenario23-llmd-lifecycle` | 통과 | 롤아웃 353 s, 교체로 인한 유실 0 (비-200 3건은 MaaS 인증 타임아웃) |
| `scenario24-llmd-vlm-{up,run,down}` | 통과 | mm 캐시 적중률 74.8% vs 55.6%, TTFT p50 0.33 s vs 1.12 s |
| `scenario25-llmd-tracing` | 통과 | EPP 5 span + vLLM 1 span 단일 trace, 거부 요청은 vLLM span 없음 |
| `scenario26-llmd-tls` | 통과 | on → off(ssl 인자 제거, probe HTTP) → 원복 |
| `scenario27-llmd-scorer-weights` | 통과 | W3: P1 49:0 (TTFT 8.1 s) vs P2 37:32 (TTFT 3.5 s) |
| `scenario28-llmd-tokenizer` | 통과 | render 200, prefix 미스 0 |
| `scenario29-llmd-canary-{up,shift,down}` | 통과 | 90:10 → 88%, 0:100 → 0% |
| `maas-checks` (nonstream) | 통과 | non-streaming 빈 본문 6/15 재현 |
| `maas-checks` (token-limit) | 하네스 미실행 | 동일 절차를 수동으로 검증(300 토큰/1분 초과 시 429, 스트리밍 포함) |
| `llmd-test-{down,up}` | 통과 | 복구 후 MaaS→EPP 20/20 |

검증 중 수정한 결함: Git Bash 경로 변환(`token-producer.modelName`), 직전 롤아웃의 Terminating pod가 GPU를
점유하여 여유 GPU 점검이 실패하던 문제(최대 3분 대기).

