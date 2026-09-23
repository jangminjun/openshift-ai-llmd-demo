# 시나리오 26: TLS 비활성화 옵션

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** `inferenceservice-config`(`enableLLMInferenceServiceTLS`), EPP/vLLM 인증서, Service Mesh mTLS

## 목적

llm-d 내부 구간(EPP ↔ vLLM, Gateway ↔ vLLM)의 자체 TLS를 비활성화했을 때, 서비스 메쉬 mTLS가 이미
적용된 환경에서 이중 암호화 없이 추론이 정상 동작하며 지연·처리량이 개선되는지 측정한다.

## 설정 위치 (3.5.1 실측)

기능 설명의 `spec.tls.enabled` 필드는 3.5.1 `LLMInferenceService` CRD에 존재하지 않는다. TLS는
**DSC의 `spec.components.kserve.enableLLMInferenceServiceTLS`**(클러스터 전역, 기본 true)로 제어된다.
operator가 이 값을 `inferenceservice-config` ConfigMap(Kserve 컴포넌트 소유)에 반영하고, preset 템플릿이
`.GlobalConfig.EnableTLS`에 따라 vLLM `--ssl-*` 인자, readiness probe scheme, EPP `--secure-serving`을 결정한다.
ConfigMap을 직접 수정하면 operator가 되돌리므로 DSC를 수정한다.
```sh
oc patch dsc default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"enableLLMInferenceServiceTLS":false}}}}'
oc get cm inferenceservice-config -n redhat-ods-applications -o jsonpath='{.data.ingress}' | grep LLMInferenceServiceTLS
```
**주의:** 전역 설정이므로 모든 `LLMInferenceService`가 재기동된다. 인라인 EPP 설정에 `metrics-data-source`
`scheme: https`를 명시한 경우 `http`로 함께 변경해야 EPP가 vLLM 메트릭을 수집한다.

## 절차

```sh
NS=llmd-s27; NAME=llmd-tls
# 1) TLS on 기준선: 동시성 8, 90초 부하 → 처리량, TTFT/E2E p50/p95 기록
oc get deploy -n $NS ${NAME}-kserve -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'ssl[^ ]*'
# 2) TLS off 전환
oc patch cm inferenceservice-config -n redhat-ods-applications --type=merge -p '{"data":{"ingress":"<enableLLMInferenceServiceTLS=false로 수정한 JSON>"}}'
oc rollout restart deploy -n $NS
# 3) 동일 부하 재측정, EPP 인자(--secure-serving=false)와 vLLM 인자(ssl 미사용) 확인
# 4) (선택) 네임스페이스에 Service Mesh mTLS 적용 후 2)~3) 반복
# 5) 원복: enableLLMInferenceServiceTLS=true
```

## 판정 기준

| 지표 | 통과 조건 |
|---|---|
| 기능 | TLS off에서 추론 요청 성공률 100% |
| 설정 반영 | EPP `--secure-serving=false`, vLLM TLS 인자 제거 확인 |
| 성능 | TLS off 시 E2E 지연 감소 또는 동등 (차이 수치 기록) |

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, T4 × 2, `max-num-seqs=4`, MaaS Gateway 경유)

**통과(기능). 성능 이득은 소폭.** 부하: 동시성 16, 출력 128 토큰, 120초, 조건별 2회.

| 지표 | TLS on (1회 / 2회) | TLS off (1회 / 2회) | 평균 변화 |
|---|---|---|---|
| 처리량 | 10.71 / 11.12 rps | 11.22 / 11.53 rps | +3.5% |
| TTFT p50 | 0.753 / 0.730 s | 0.729 / 0.729 s | −1.6% |
| E2E p50 | 1.414 / 1.396 s | 1.371 / 1.370 s | −2.4% |
| 설정 반영 | vLLM `--ssl-certfile/keyfile/refresh`, probe HTTPS | ssl 인자 제거, probe HTTP | |

- DSC 변경 후 ConfigMap 반영 약 30초, 워크로드 롤링 재기동 약 5분.
- 병목이 GPU 연산이므로 내부 구간 TLS 제거 효과는 3% 내외였다.
- 측정 후 기본값(TLS on)으로 복구하였다(`oc patch dsc ... --type=json -p '[{"op":"remove",...}]'`).

## 검증 필요 사항

- 클러스터에 Service Mesh(사이드카/ambient) 미설치 — mTLS와의 이중 암호화 제거 효과는 설치 후 측정
