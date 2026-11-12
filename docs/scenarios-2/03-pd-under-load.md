# 시나리오 2-03: 부하 하의 P/D 분리 동작

**모듈:** 분산 환경 활용 > 추론 단계 분리
**대상:** `llmd-pd/qwen38-int4-pd`, 부하 생성기 GuideLLM(시나리오 2-01)
**상태:** 실측 완료(2026-11-12)

## 목적

동시 요청을 늘려도 모든 요청이 prefill pod → decode pod로 분리되어 처리되는지, KV 전달 실패와 오류가 없는지 확인한다.
아울러 P/D의 핵심 이점인 "긴 prefill이 진행 중인 decode를 방해하지 않음"이 토큰 간 지연(ITL)으로 나타나는지 본다.

## 부하

GuideLLM, 동시 1·4·8·16, 단계별 60초.

| 부하 | 프롬프트 / 응답 | 의도 |
|---|---|---|
| L1 | 2,000 / 256토큰 | prefill과 decode가 모두 일하는 기본 조건 |
| L2 | 8,000 / 128토큰 | prefill 집약. decode의 ITL이 유지되는지 |

**경로.** 요청은 MaaS Gateway와 EPP를 거쳐야 P/D로 분리된다(workload Service로 직접 보내면 EPP가 prefill을 지정하지 않는다).
그러나 외부 주소(`maas.apps…`)는 AWS Classic ELB를 지나며, 첫 토큰까지 60초를 넘는 요청은 끊긴다(2-08 H3). L2 동시 16은
prefill 대기만 약 100초이므로, GuideLLM Job에 `hostAliases`를 넣어 MaaS 호스트 이름을 Gateway Service의 ClusterIP로
해석시킨다(`GUIDELLM_VIA=gateway`). URL·TLS SNI·HTTPRoute·API 키 인증은 MaaS 경로와 같고, ELB만 거치지 않는다.

```sh
oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -o jsonpath='{.items[0].spec.clusterIP}'
# Job spec.template.spec.hostAliases: [{ip: <ClusterIP>, hostnames: [maas.apps.<domain>]}]
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno ./harness.sh scenario2-03-pd-load          # L1, L2 각각 카운터 전후 수집 + GuideLLM
HARNESS_PROFILE=sno S23_LOADS="8000/128" GUIDELLM_STREAMS=1,8 ./harness.sh scenario2-03-pd-load
```

## 관측

| 지표 | 출처 | 기대 |
|---|---|---|
| 완료 요청 수 | GuideLLM | 오류 0 (MaaS 인증 기한 초과 500은 별도 집계) |
| 요청 분리율 | NIXL 전송 수 / (prefill 완료 수 × TP) | 1.0 (prefill을 마친 모든 요청이 KV를 decode로 전달) |
| 생성 위치 | decode `generation_tokens_total` 증가량 / GuideLLM 출력 토큰 합 | 1.0 |
| KV 전달 | NIXL 지표·로그 | 실패 0 |
| TTFT, ITL, 처리량 | GuideLLM | 동시성별 추이 |
| 대기 | `vllm:num_requests_waiting`(역할별) | 병목 역할 식별 |

Grafana 대시보드 `llmd-pd-latency`(`gpu-monitoring/gpu-grafana`)로 역할별 추이를 함께 본다.

```sh
oc exec -n llmd-pd <prefill-pod> -c main -- curl -sk https://localhost:8000/metrics | grep -E '^vllm:(request_success_total|nixl_num_kv_expired)'
oc exec -n llmd-pd <decode-pod>  -c main -- curl -sk https://localhost:8001/metrics | grep -E '^vllm:(generation_tokens_total|nixl_xfer_time_seconds_count|nixl_num_failed)'
```

하네스는 부하마다 이 카운터를 전후로 수집하여(`remote/lib/bench.sh`의 `pd_counters`) GuideLLM 결과와 비교한다(`tools/pd-load-report.py`).

## 판정 기준

- 분리율(prefill 완료 요청의 KV 전달)과 생성 위치 비율이 1.0이고 KV 전달 실패가 0이다. 단계 종료 시 GuideLLM이 끊은
  요청(incomplete) 중 prefill 대기열에 있던 것은 prefill 완료 수에 포함되지 않으므로, 보낸 요청 수와는 비교하지 않는다.
- L2에서 동시성이 늘어도 decode ITL의 증가가 TTFT 증가보다 작다(prefill 부하가 decode에 전이되지 않음).

## 결과 (2026-11-12)

### L1: 프롬프트 2,000 / 응답 256

| 동시 | 완료 | 미완료 | TTFT p50 | TTFT p95 | ITL p50 | 출력 처리량 |
|---|---|---|---|---|---|---|
| 1 | 5 | 1 | 2.06초 | 2.16초 | 35.3ms | 21 tok/s |
| 4 | 16 | 4 | 2.30초 | 6.71초 | 40.4ms | 68 tok/s |
| 8 | 28 | 8 | 2.38초 | 11.65초 | 45.1ms | 120 tok/s |
| 16 | 30 | 16 | 13.27초 | 24.22초 | 46.0ms | 128 tok/s |

### L2: 프롬프트 8,000 / 응답 128

| 동시 | 완료 | 미완료 | TTFT p50 | TTFT p95 | ITL p50 | 출력 처리량 |
|---|---|---|---|---|---|---|
| 1 | 5 | 1 | 7.19초 | 7.22초 | 35.9ms | 11 tok/s |
| 4 | 8 | 4 | 20.94초 | 26.82초 | 35.9ms | 17 tok/s |
| 8 | 8 | 8 | 27.05초 | 52.82초 | 35.9ms | 17 tok/s |
| 16 | 8 | 16 | 27.03초 | 52.72초 | 35.9ms | 17 tok/s |

### 분리 판정

| 항목 | L1 | L2 |
|---|---|---|
| prefill 완료 / 보낸 요청 | 99 / 108 | 32 / 58 |
| NIXL 전송(decode, TP 2) | 198 = 99 × 2 | 64 = 32 × 2 |
| NIXL 실패 / KV 만료 | 0 / 0 | 0 / 0 |
| decode 생성 토큰 / 클라이언트 출력 토큰 | 22,563 / 22,548 (1.00) | 3,800 / 3,798 (1.00) |
| preemption(prefill / decode) | 0 / 0 | 0 / 0 |

- prefill을 마친 모든 요청이 KV를 decode로 넘겼고(전송 수 = prefill 완료 × TP), 출력 토큰은 전부 decode가 생성하였다. KV 전달
  실패는 없었다. prefill 완료 수가 보낸 요청보다 적은 것은 단계 종료 시 prefill 대기열에 남아 있던 미완료 요청 때문이다.
- **L2에서 ITL은 동시 1~16 모두 35.9ms로 변하지 않았고, TTFT는 7.2초에서 27초(p95 53초)로 늘었다.** 긴 prefill 대기가
  decode의 토큰 생성 속도에 전이되지 않았다. P/D 분리의 핵심 이점이 확인되었다.
- 병목은 prefill이다. prefill 1개(약 1,210토큰/초)가 8K 프롬프트를 약 6.6초에 하나씩 처리하므로, L2 처리량은 동시 4에서
  17 tok/s로 포화되었다. L1도 동시 16에서 TTFT p50이 2.4초에서 13.3초로 뛰고 처리량은 8 → 16에서 7%만 늘었다.
- L1의 ITL은 35 → 46ms로 늘었다. 이는 decode의 동시 생성 수(배치)가 커진 데 따른 것이며, 동시 8 이후 거의 일정하다.

## 결론

부하가 늘어도 P/D 분리는 정상 동작한다. prefill을 마친 요청은 모두 KV를 decode로 넘겼고 전달 실패는 없었다. prefill
집약 부하(L2)에서 TTFT가 4배로 늘어도 ITL은 그대로였으므로, 긴 프롬프트가 다른 요청의 토큰 생성 속도를 떨어뜨리지 않는다.
본 구성(prefill 1, decode 1)의 처리량 상한은 prefill이 정하므로, 장문 비중이 큰 워크로드는 prefill 복제본을 늘려야 한다.

## 해석상 유의점

- prefill 1 + decode 1 구성이므로 처리량 상한은 어느 한쪽의 포화로 정해진다. 대기가 쌓이는 역할이 병목이다.
- 단계가 60초이므로 L2 동시 8·16의 TTFT는 60초 안에 첫 토큰을 받은 요청만 반영한다(나머지는 미완료). 실제 대기는 표보다 길다.
- 통합 구성(TP2 단일 인스턴스)과의 비교는 같은 GPU 수(4장)에서 별도 시나리오로 수행한다.
