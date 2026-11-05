# 시나리오 2-03: 부하 하의 P/D 분리 동작

**모듈:** 분산 환경 활용 > 추론 단계 분리
**대상:** `llmd-pd/qwen38-int4-pd`, 부하 생성기 GuideLLM(시나리오 2-01)
**상태:** 설계, 미실행

## 목적

동시 요청을 늘려도 모든 요청이 prefill pod → decode pod로 분리되어 처리되는지, KV 전달 실패와 오류가 없는지 확인한다.
아울러 P/D의 핵심 이점인 "긴 prefill이 진행 중인 decode를 방해하지 않음"이 토큰 간 지연(ITL)으로 나타나는지 본다.

## 부하

GuideLLM, MaaS 경로(`GUIDELLM_VIA=maas`), 동시 1·4·8·16, 단계별 60초.

| 부하 | 프롬프트 / 응답 | 의도 |
|---|---|---|
| L1 | 2,000 / 256토큰 | prefill과 decode가 모두 일하는 기본 조건 |
| L2 | 8,000 / 128토큰 | prefill 집약. decode의 ITL이 유지되는지 |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno LLMD_NAMESPACE=llmd-pd LLMD_NAME=qwen38-int4-pd GUIDELLM_VIA=maas \
  GUIDELLM_STREAMS=1,4,8,16 GUIDELLM_PROMPT_TOKENS=2000 GUIDELLM_OUTPUT_TOKENS=256 ./harness.sh guidellm
HARNESS_PROFILE=sno LLMD_NAMESPACE=llmd-pd LLMD_NAME=qwen38-int4-pd GUIDELLM_VIA=maas \
  GUIDELLM_STREAMS=1,4,8,16 GUIDELLM_PROMPT_TOKENS=8000 GUIDELLM_OUTPUT_TOKENS=128 ./harness.sh guidellm
```

## 관측

| 지표 | 출처 | 기대 |
|---|---|---|
| 완료 요청 수 | GuideLLM | 오류 0 (MaaS 인증 기한 초과 500은 별도 집계) |
| 요청 분리율 | prefill `request_success_total` 증가량 / GuideLLM 완료 수 | 1.0 (모든 요청이 prefill을 거침) |
| 생성 위치 | decode `generation_tokens_total` 증가량 / GuideLLM 출력 토큰 합 | 1.0 |
| KV 전달 | NIXL 지표·로그 | 실패 0 |
| TTFT, ITL, 처리량 | GuideLLM | 동시성별 추이 |
| 대기 | `vllm:num_requests_waiting`(역할별) | 병목 역할 식별 |

Grafana 대시보드 `llmd-pd-latency`(`gpu-monitoring/gpu-grafana`)로 역할별 추이를 함께 본다.

```sh
oc exec -n llmd-pd <prefill-pod> -c main -- curl -sk https://localhost:8000/metrics | grep -E '^vllm:(request_success_total|num_requests_waiting)'
oc exec -n llmd-pd <decode-pod>  -c main -- curl -sk https://localhost:8001/metrics | grep -E '^vllm:(generation_tokens_total|num_requests_running)'
```

## 판정 기준

- 모든 동시성에서 분리율과 생성 위치 비율이 1.0이고 KV 전달 실패가 0이다.
- L2에서 동시성이 늘어도 decode ITL의 증가가 TTFT 증가보다 작다(prefill 부하가 decode에 전이되지 않음).

## 해석상 유의점

- prefill 1 + decode 1 구성이므로 처리량 상한은 어느 한쪽의 포화로 정해진다. 대기가 쌓이는 역할이 병목이다.
- 통합 구성(TP2 단일 인스턴스)과의 비교는 같은 GPU 수(4장)에서 별도 시나리오로 수행한다.
