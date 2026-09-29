# QA 테스트케이스: OpenShift AI + llm-d 관측성

**모듈:** 모니터링/평가 > 중앙 집중식 플랫폼 관측성
**관련 컴포넌트:** OpenShift AI Operator(RHOAI 3.5.1, 실측은 3.4.4), KServe `LLMInferenceService`, Prometheus/Alertmanager
스택(Cluster Monitoring + User Workload Monitoring) / OCP 4.22

**실측 대상 (myocp 클러스터, 2026-09-07 확인):** `LLMInferenceService qwen25-coder-7b`
(네임스페이스 `qwen25-coder-7b`), `llm-d.ai/role=both`(prefill/decode 비분리 단일 워크로드).
자세한 아키텍처 배경은 [README.md](../README.md#아키텍처-실측) 참고.

---

## TC-01. 관측성 스택 활성화 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | OpenShift AI Operator 설치 완료, DSCI CR 접근 권한 확보 |
| 절차 | 1) `oc get dsci default-dsci -o yaml`로 `spec.monitoring.managementState`가 `Managed`인지 확인 (미설정 시 `manifests/dsci-observability-patch.yaml` 참고해 패치)<br>2) `oc get pods -n redhat-ods-monitoring`, `oc get pods -n openshift-user-workload-monitoring`로 관련 Operand 배포 확인 |
| 기대결과 | prometheus-user-workload-*, thanos-ruler-user-workload-*, alertmanager-main-* Pod가 Running. DSCI status의 관련 condition이 `True`/`Ready` |
| 우선순위 | High |
| 실측 결과 (2026-09-07) | **통과.** `spec.monitoring.managementState: Managed`, `namespace: redhat-ods-monitoring`. UWM(`prometheus-user-workload-0/1`, `thanos-ruler-user-workload-0/1`), 플랫폼 `alertmanager-main-0/1` 모두 Running. |

## TC-02. llm-d 메트릭 수집 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-01 완료, `LLMInferenceService`가 배포되어 Ready 상태 |
| 절차 | 1) `oc get servicemonitor,podmonitor -n <ns>`로 컨트롤러가 자동 생성한 `kserve-llm-isvc-scheduler(-default)`/`kserve-llm-isvc-vllm-engine(-default)` 확인 (수동 적용 불필요 — 참고용 사본은 `manifests/servicemonitor-llmd.yaml`)<br>2) Thanos-querier(`oc get route thanos-querier -n openshift-monitoring`)로 `up{namespace="<ns>"}` 조회<br>3) PromQL로 핵심 메트릭 조회 (`kserve_vllm:time_to_first_token_seconds_bucket`, `kserve_vllm:request_success_total`) |
| 기대결과 | 모든 llm-d 타겟이 `up=1`, 메트릭 값이 0이 아닌 실측치로 수집됨 |
| 우선순위 | High |
| 실측 결과 (2026-09-07) | **통과 (vLLM 엔진 한정).** `kserve-llm-isvc-vllm-engine` PodMonitor로 vLLM 엔진 메트릭이 `kserve_vllm:...` 접두사로 수집됨 (예: `kserve_vllm:request_success_total{finished_reason="abort\|error\|stop"}`). `kserve-llm-isvc-scheduler` ServiceMonitor는 존재하나, 이 인스턴스가 `llm-d.ai/role=both`(비분리)라 라우터/스케줄러(EPP) 전용 pod가 없어 매칭 타겟 없음 — **결함 아님**, prefill/decode 분리 배포 시에만 채워짐. |

## TC-03. Grafana 대시보드 연결 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-02 완료 |
| 절차 | 1) Grafana에 Prometheus(Thanos-querier 또는 UWM Prometheus) 데이터소스 등록<br>2) `grafana/llmd-dashboard.json` import (쿼리는 `kserve_vllm:...` 및 `namespace="qwen25-coder-7b"` 라벨 기준으로 갱신됨) |
| 기대결과 | TTFT, 처리량, 에러율 패널에 실데이터 표시, 패널 갱신 주기(15초) 내 정상 갱신 |
| 우선순위 | Medium |
| 실측 결과 | PromQL 쿼리 레벨로는 확인함(TC-04 참고). Grafana UI 렌더링은 브라우저 접근이 필요해 이번 실행에서 CLI로는 검증하지 못함 — 사용자 확인 필요. |

## TC-04. 실시간 모니터링 검증 (TTFT·처리량·에러율)

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-03 완료, 부하 생성 도구(k6/locust/curl 반복 등) 준비 |
| 절차 | 1) 정상 부하로 추론 요청 발생<br>2) 부하를 단계적으로 증가시키며 대시보드 관찰<br>3) 의도적으로 실패 요청(잘못된 payload 등) 주입 |
| 기대결과 | 부하 증가에 따라 TTFT·처리량 지표가 지연 없이 반영, 실패 요청 발생 시 `finished_reason="error"` 기반 에러율 지표 상승 확인 |
| 우선순위 | High |
| 실측 결과 | 이번 세션 실행 결과는 `docs/test-results-2026-09-07.md` 참고. |

## TC-05. 임계값 초과 알림 검증 (TTFT + 에러율)

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-04 완료, Alertmanager 알림 채널(Slack/이메일 등) 연동 |
| 알림 규칙 | `manifests/prometheusrule-llmd-alerts.yaml` 참고 (실측 메트릭 `kserve_vllm:...` 기준으로 재작성됨)<br>- **TTFT**: p95 > 2초가 5분 이상 지속<br>- **에러율**: `finished_reason="error"` 비율 > 5%가 5분 이상 지속 |
| 절차 | 1) PrometheusRule을 `qwen25-coder-7b` 네임스페이스에 적용<br>2) 부하 과다 또는 오류 요청 주입으로 임계값 초과 상황 유발<br>3) Thanos-querier `ALERTS{alertname=~"LLMDHigh.*"}`로 firing 확인<br>4) 정상화 후 resolved 확인 |
| 기대결과 | 임계값 초과 시 alert firing, 정상화 시 알림 자동 resolved |
| 우선순위 | High |
| 실측 결과 (2026-09-07) | **통과.** 오류 요청 버스트로 에러율 93.1%까지 올린 뒤 `alertstate`가 `pending`(16:25:51)→`firing`(16:29:27, `for: 5m` 충족)→정상화 후 자동 `resolved`(16:29:58 이후 결과 없음)로 전환되는 것을 실측 확인. 상세 타임라인은 `docs/test-results-2026-09-07.md` 참고. |
| 범위 제한 (2026-09-07 확인) | 이 클러스터엔 `qwen25-coder-7b` 네임스페이스용 `AlertmanagerConfig`(채널 라우팅)가 아직 없음 (`enableUserAlertmanagerConfig: true`는 활성화되어 있어 추가는 가능). 이번 TC-05는 **firing 확인까지**를 범위로 하고, Slack/이메일 등 채널 전달 검증은 후속 과제(TC-06 후보)로 분리. |

---

## 참고: 임계값 (가정치)

실제 서비스 SLO가 확정되지 않아 아래는 초기 가정치입니다. 확정되는 대로 본 문서와
`manifests/prometheusrule-llmd-alerts.yaml`을 함께 갱신해야 합니다.

| 지표 | 임계값 | 지속시간 |
|---|---|---|
| TTFT (p95) | > 2초 | 5분 |
| 에러율 | > 5% | 5분 |

## 향후 확장 후보 (TC-06+)

- `AlertmanagerConfig`로 Slack/이메일 등 실제 채널까지 알림 전달 검증
- 처리량(throughput) 단독 임계값 알림
- GPU 사용률/메모리 지표 (DCGM exporter, `nvidia_gpu_*`), vLLM 큐 길이(`kserve_vllm:num_requests_waiting`)
- prefill/decode 분리 배포로 라우터/스케줄러(EPP) 메트릭 수집 검증
- Tempo 분산 트레이싱과 메트릭 간 상관관계(trace-to-metrics) 검증
- 3rd party 관측 도구(Grafana Cloud, Datadog) remote_write 연동
