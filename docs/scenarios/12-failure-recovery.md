# 시나리오 12: 장애 및 복구

**모듈:** 분산 환경 활용 > 장애 대응
**관련 컴포넌트:** `LLMInferenceService`(vLLM workload, EPP), `InferencePool`, MaaS Gateway

## 목적

llm-d 서빙 중 구성 요소 하나가 중단될 때 요청이 얼마나 실패하고(blast radius), 언제 정상으로 돌아오는지를
클라이언트 관점에서 측정한다. vLLM pod와 EPP는 역할이 달라 중단의 영향도 다르다.

| 구성 요소 | 역할 | 중단 시 예상 |
|---|---|---|
| vLLM pod | 추론 수행, KV 캐시 보유 | replica 1이면 전체 중단, 2 이상이면 남은 pod가 처리 |
| EPP | 요청마다 pod 선택 | 분배 불가. `InferencePool`의 장애 처리 방식에 따라 실패 또는 우회 |

## 실험 설계

| 조건 | replica | 삭제 대상 | 확인 사항 |
|---|---|---|---|
| A | 1 | vLLM pod | 전체 중단 시간, 복구 시간(모델 재다운로드 포함) |
| B | 2 | vLLM pod 1개 | EPP의 장애 pod 제외 속도, 처리 중 요청 외 실패 여부, 남은 pod의 지연 |
| C | 2 | EPP pod | EPP 부재 중 요청 처리 방식, EPP 복구 시간 |

- **부하:** MaaS Gateway 경유 짧은 채팅 요청, 동시 4, 6분, 응답 64토큰, 요청 타임아웃 30초.
- **장애:** 부하 시작 30초 후 `oc delete pod`로 대상 pod를 삭제한다.
- **집계:** 부하 생성기가 요청마다 시각·응답 코드·TTFT를 기록한다. 연결 거부·타임아웃은 서버 지표에 남지 않으므로
  실패는 클라이언트 기준으로 센다.
- **복구 시점:** 삭제된 pod가 사라지고 대상 구성 요소의 Ready pod 수가 원래 값으로 돌아온 시각.

## 측정 지표

| 지표 | 의미 |
|---|---|
| `errors`, `window` | 실패 요청 수와 삭제 시점 기준 발생 구간 |
| `max_ok_gap` | 성공 요청이 끊긴 최장 구간(서비스 중단 시간). 즉시 반환되는 503은 건수를 부풀리므로 시간으로 본다 |
| `recovery` | 삭제부터 복구까지의 시간 |
| TTFT p50 before / during / after | 삭제 전, 장애 중, 복구 후의 지연 |
| 15초 단위 ok/err | 장애 전후의 성공·실패 추이 |

## 사전 조건

- `llmd-test` Ready(EPP 활성, `maas-default-gateway`), 여유 GPU 1장 이상(삭제된 vLLM pod 재기동)
- MaaS 토큰 한도 5,000만 토큰/시간 이상, API 키 Secret `llmd-bench/loadgen-token`(시나리오 11 사전 조건과 동일)

## 절차

```sh
cd openshift-ai-llmd-demo/harness
./harness.sh scenario12-llmd-failure                     # A~C 순차 실행, 종료 시 replica 원복
S12_ARMS="B" S12_DURATION=240 ./harness.sh scenario12-llmd-failure
```

조정 변수: `S12_ARMS`("A B C"), `S12_DURATION`(360), `S12_KILL_AT`(30), `S12_CONCURRENCY`(4), `S12_MAX_TOKENS`(64).

장애 중 상태는 다음으로 확인한다.

```sh
oc get pods -n llmd-test -o wide -w
oc get inferencepool llmd-test-inference-pool -n llmd-test -o yaml
```

## 실측 결과 (2026-09-29, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, A10G)

동시 4, 6분, 부하 30초 후 삭제, 조건별 1회.

| 조건 | 서비스 중단 | 복구 시간 |
|---|---|---|
| A: r1, vLLM 삭제 | **약 2분** (즉시 503) | 116초 |
| B: r2, vLLM 1개 삭제 | 없음 | 125초 |
| C: r2, EPP 삭제 | 없음 | 32초 (새 EPP Ready) |

- **replica 1은 모델 재적재 시간만큼 전면 중단된다.**
- **replica 2는 vLLM pod 장애에 무중단이다.** 남은 pod가 처리하며 지연 변화도 없었다(경부하).
- **EPP 장애도 무중단이다.** 32초간 모든 EPP 호출이 실패했으나(`ext_proc` gRPC 14) Envoy가 EPP 없이 pod로
  분배했다(FailOpen). 이 구간의 분배는 캐시를 인지하지 않는다.
- 500 오류(0.3~0.5%)는 삭제와 무관한 MaaS 인증 기한 초과이다.

## Summary: 운영 가이드

1. **가용성이 필요하면 replica를 2 이상 둔다.** replica 1은 장애 시 모델 재적재 시간만큼 전면 중단된다.
2. **EPP 장애 시 동작은 Envoy의 `ext_proc` 설정이 결정한다.** EPP가 아니라 Gateway가 적용하므로 EPP가 죽어도
   유효하다. 선언 위치와 실제 적용값은 다음과 같다.
   ```yaml
   # LLMInferenceService (InferencePool은 컨트롤러가 생성하므로 직접 수정하지 않는다)
   spec:
     router:
       scheduler:
         pool:
           spec:              # 현재 InferencePool spec 전체를 복사한 뒤 failureMode만 변경
             endpointPickerRef:
               failureMode: FailOpen   # 또는 FailClose
   ```
   ```sh
   oc get inferencepool <name>-inference-pool -n <ns> -o jsonpath='{.spec.endpointPickerRef.failureMode}'
   oc exec -n openshift-ingress <gateway-pod> -- pilot-agent request GET config_dump | grep -c '"failure_mode_allow": true'
   ```
   **주의:** OCP 4.22 Gateway(`istiod-openshift-gateway`)에서는 `FailClose`로 바꾸어도 `InferencePool`만 변경되고
   Envoy는 `failure_mode_allow: true`를 유지하였다(3분 이상 관찰). 즉 현재 환경은 항상 FailOpen으로 동작한다.
3. **장애 여부는 클라이언트 지표로 판단한다.** 서버 지표는 거부된 연결을 집계하지 않는다.
