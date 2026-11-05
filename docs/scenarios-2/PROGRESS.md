# scenarios-2 진행 상황

**최종 갱신:** 2026-11-05 (2-08 실행 중 중단)
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

| 문서 | 실험(`MAAS_MIT_ARMS`) | 상태 |
|---|---|---|
| 08 원인 검증 | `single` `io` `saturate` | `single` 1회 실행(아래), `io`·`saturate` 미실행 |
| 08-1 한도 재설계 | `limit` | (a)~(c) 기록 완료. (d) 2단 한도는 `MAAS_MIT_LIMITS="50000/15s+80000/2m"`로 재실행 필요 |
| 08-2 prefix 캐시 | `prefix` | 미실행(prefill 재기동 2회) |
| 08-3 배치 토큰 | `chunk` | 미실행(prefill 재기동 2회 + 원복) |
| 08-4 재시도 | `retry` | 완료 |
| 08-5 동시 실행 제한 | `conc` | 1차 무효(closed-loop probe), 재실행 필요 |
| 08-6 구독 분리 | `split` | 1차 무효(closed-loop probe), 재실행 필요 |
| 08-7 입력 압축 | - | `io` 결과로 산정 |

## 재개 순서

```sh
cd harness
HARNESS_PROFILE=sno MAAS_MIT_ARMS="single io saturate" ./harness.sh scenario2-08-mitigation          # 약 25분
HARNESS_PROFILE=sno MAAS_MIT_ARMS="limit conc split" MAAS_MIT_LIMITS="50000/15s+80000/2m" \
  ./harness.sh scenario2-08-mitigation                                                                # 약 15분
HARNESS_PROFILE=sno MAAS_MIT_ARMS="prefix chunk" ./harness.sh scenario2-08-mitigation                 # 약 30분
```

이후 각 문서의 "결과"를 채우고 08 본문 결과, 08-7 산정, `README.md` 2-08 행을 갱신한다.

## 미분석 결과

`single`(한도 8,000/15초, 장문 1건 + 단문 1초 간격, 2026-11-05): 장문 200(12,177토큰), 단문 38건 200·2건 429.
기대(장문 차감 후 15초 차단)보다 429가 적다. 단문의 첫 차감이 구간을 먼저 열어 장문 차감 직후 구간이 끝났을 가능성이
있으므로 요청별 시각으로 확인한다.

## 기타 미완

- 2-05(P/D prefix 캐시): prefix 캐시가 기본 꺼짐이므로 설계에 `--enable-prefix-caching` 반영 필요.
- 2-03~2-06 미실행, 에이전트 E2E 시나리오는 보류.
