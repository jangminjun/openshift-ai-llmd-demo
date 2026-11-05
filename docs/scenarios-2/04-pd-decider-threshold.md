# 시나리오 2-04: P/D 분리 결정 임계값

**모듈:** 분산 환경 활용 > 추론 단계 분리
**대상:** `llmd-pd/qwen38-int4-pd`
**상태:** 설계, 미실행

## 목적

짧은 프롬프트는 prefill pod를 거치는 이득보다 KV 전달 비용이 크다. EPP의 P/D decider가 캐시되지 않은 프롬프트 토큰 수를
기준으로 분리 여부를 결정하는지 확인한다.

## 배경: EPP 설정의 변환

RHOAI 3.5.2의 EPP는 이전 형식 `pd-profile-handler`(`threshold`)를 새 구조로 변환한다. `threshold: 0`은 다음과 같이 적용되었다.

```
disagg-profile-handler  deciders: {prefill: always-disagg-pd-decider}
```

임계값을 쓰려면 prefix 기반 decider(이름과 파라미터는 첫 실행에서 EPP 로그로 확인)를 지정한다.

```sh
oc logs deploy/qwen38-int4-pd-kserve-router-scheduler -n llmd-pd | grep 'Effective raw configuration'
```

## 조건

| 조건 | decider | 짧은 요청(약 100토큰) | 긴 요청(약 2,000토큰) |
|---|---|---|---|
| T0 | always (현재, `threshold: 0`) | prefill 경유 | prefill 경유 |
| T1 | prefix 기반, 임계값 1,000토큰 | **prefill 생략**(decode가 직접 계산) | prefill 경유 |

조건마다 짧은 요청과 긴 요청을 각각 20건 보내고, prefill pod의 `request_success_total` 증가량을 센다.
EPP 설정은 `spec.router.scheduler.config.inline`을 전체 교체한다(부분 병합은 EPP CrashLoop을 유발한다).

```sh
oc patch llminferenceservice qwen38-int4-pd -n llmd-pd --type=json \
  -p '[{"op":"replace","path":"/spec/router/scheduler/config/inline","value":<새 설정 JSON>}]'
oc rollout status deploy/qwen38-int4-pd-kserve-router-scheduler -n llmd-pd
```

## 판정 기준

- T0: 짧은 요청과 긴 요청 모두 prefill 증가량 20.
- T1: 짧은 요청의 prefill 증가량 0, 긴 요청 20. 짧은 요청은 decode의 `prompt_tokens_total`과 prefill 시간이 증가한다.
- 짧은 요청의 TTFT는 T1이 T0보다 짧다(KV 전달 생략).

## 원복

T0 설정(`threshold: 0`)으로 되돌린다. 매니페스트: [manifests/pd/qwen38-int4-pd.yaml](../../manifests/pd/qwen38-int4-pd.yaml)
