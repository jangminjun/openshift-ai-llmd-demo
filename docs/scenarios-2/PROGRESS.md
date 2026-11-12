# scenarios-2 진행 상황

**최종 갱신:** 2026-11-12
**클러스터:** RHDP sandbox1343 (`AGENT.md` 참조), `llmd-pd/qwen38-int4-pd` P/D 가동 중

## 재개 전 확인

```sh
oc whoami --show-server
oc get maassubscription -n models-as-a-service \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.modelRefs[*].tokenRateLimits}{"\n"}{end}'   # 모두 1e9/1h
oc get llminferenceservice qwen38-int4-pd -n llmd-pd \
  -o jsonpath='{.spec.prefill.template.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'   # prefix/batched 플래그 없음
oc get secret loadgen-token loadgen-token-chat -n llmd-bench
```

API 키 Secret이 없으면 `oc login` 후 다음으로 다시 발급한다(새 PC에서는 사용자 토큰이 필요하다).

```sh
cd harness
HARNESS_PROFILE=sno ./harness.sh maas-api-key
HARNESS_PROFILE=sno KEY_NAME=llmd-loadgen-chat KEY_SECRET=loadgen-token-chat KEY_SUBSCRIPTION=llmd-demo-sub-chat ./harness.sh maas-api-key
```

## 2-08 상태

2-07·2-08 문서는 `docs/scenarios-2/429-error/`에 있다.

| 문서 | 실험(`MAAS_MIT_ARMS`) | 상태 |
|---|---|---|
| 08 원인 검증 | `single` `io` `saturate` | 완료(2026-11-12). H1 수정, H2 확인, H3 기각(대신 ELB 60초 끊김) |
| 08-0 rate-limit 헤더 | `headers` | 완료. Limitador v2.4.2 `CheckRateLimit`이 헤더 미생성(v2.6.0부터 지원) |
| 08-1 한도 재설계 | `limit` | 완료 |
| 08-2 prefix 캐시 | `prefix` | 완료 |
| 08-3 배치 토큰 | `chunk` | 완료 |
| 08-4 재시도 | `retry` | 완료 |
| 08-5 동시 실행 제한 | `conc` | 완료(open-loop probe 재실행) |
| 08-6 구독 분리 | `split` | 완료(open-loop probe 재실행) |
| 08-7 입력 압축 | - | 산정 완료 |
| 08-8 EPP Flow Control | - | 아이디어 문서만 작성. P/D 시나리오 후 진행 |

실행 로그는 `harness/results/scenario2-08/`(git 제외)에 있으며, 핵심 수치는 각 문서에 옮긴다.

## 남은 일

- 2-08 실험은 모두 완료되었다. 미확인 항목: 2-08-5 동시 2의 단문 502 1건, ELB 유휴 타임아웃 실제 값.
- 2-08-8 EPP Flow Control 실행 계획(예상 1.5~2시간, Flow Control이 동작하지 않으면 최대 약 3시간):

  | 단계 | 내용 | 예상 |
  |---|---|---|
  | 1. 사전 확인 | Flow Control 활성 여부, P/D에서 포화 판정 대상(prefill/decode), `InferenceObjective` CRD 존재 | 20~30분 |
  | 2. 스크립트 | `scenario2-08-mitigation.sh`에 `flowctl` arm 추가: InferenceObjective 2개(interactive 100, batch 0), probe에 `x-llm-d-inference-objective` 헤더, EPP 설정 원복 | 30~40분 |
  | 3. 실행 | 기본 vs 우선순위 적용, 조건당 약 5분. EPP만 재기동(1~2분), vLLM 재기동 없음 | 15~20분 |
  | 4. 문서 | 템플릿(목적·설정·실험설계·결과·결론)으로 결과 표, TTFT 그래프, 결론 작성 | 20~30분 |

  위험 요소: 2-08 `saturate`(동시 48)에서도 EPP 큐잉이 없었다. 기본 포화 기준으로 큐가 생기지 않으면 `concurrency-detector`로
  바꾸고 기준값을 조정한다(+30~60분).

## 기타 미완

- 2-05(P/D prefix 캐시): prefix 캐시가 기본 꺼짐이므로 설계에 `--enable-prefix-caching` 반영 필요(2-08-2에서 켜도 정상 기동·TTFT −65% 확인).
- 2-03, 2-04, 2-05 완료(2026-11-12). 2-05: 하이브리드 블록 1,568토큰 때문에 decider 기준은 블록 크기 이상 필요.
- 2-06은 역할별 메모리 설정으로 재설계(2-06-1~2-06-5), 미실행. 재기동마다 약 8분(torch.compile) 소요.
- 2-04 짧은 요청 전송량(NIXL bytes) 측정은 미실시(0.4초 고정 비용의 원인 추정 확인용). 에이전트 E2E 시나리오는 보류.
