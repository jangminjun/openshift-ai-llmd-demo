# 시나리오 2-05: prefix 캐시와 P/D

**모듈:** 분산 환경 활용 > 추론 단계 분리
**대상:** `llmd-pd/qwen38-int4-pd`
**상태:** 실행 중(2026-11-12)

## 목적

채팅에서는 질문할 때마다 지금까지의 대화 전체를 다시 보낸다. 따라서 앞의 대화는 다음 질문의 prefix(앞부분)가 된다.
2번째 질문에서 새로 계산할 부분은 끝에 붙은 질문2(약 100토큰)뿐이고, 문서와 앞의 대화(약 3,700토큰)는 1번째 질문에서
이미 계산한 KV를 캐시에서 재사용할 수 있다.

![채팅에서 앞의 대화는 다음 질문의 prefix가 된다](images/05/chat-prefix.svg)

P/D 구성에서 1번째 질문이 끝나면 앞의 대화 KV는 prefill pod(계산한 곳)와 decode pod(NIXL로 받은 곳)에 모두 남는다.
EPP가 2번째 질문을 어디로 보내느냐에 따라 처리 비용이 달라진다.

- **항상 분리(threshold 0):** 2번째 질문도 prefill pod로 간다. prefill pod는 캐시 덕분에 질문2만 계산하지만, 완성된 KV
  전체(약 3,700토큰분)를 decode pod로 다시 전송한다.
- **임계값 분리(threshold 1000):** EPP의 decider는 전체 길이가 아니라 캐시되지 않은 토큰 수를 센다. 약 100토큰으로 기준
  미만이므로 prefill pod를 건너뛰고, decode pod가 자기 캐시 위에 질문2만 계산한다. KV 전송이 없다.

![2번째 질문의 경로](images/05/turn2-routing.svg)

본 시나리오는 임계값 분리에서 2번째 질문이 prefill pod를 건너뛰는지, 그 결과 TTFT가 얼마나 줄어드는지 확인한다.
2-04가 "프롬프트가 짧아서" prefill을 건너뛰는 경우라면, 2-05는 "프롬프트는 길지만 대부분 캐시되어 있어서" 건너뛰는 경우이다.

## 사전 설정

Qwen3.8(하이브리드 모델)은 vLLM에서 prefix 캐시가 기본으로 꺼져 있다(2-08-2). decode와 prefill 모두
`--enable-prefix-caching`을 켠다. decode가 1번째 질문에서 받은 KV를 캐시로 보관해야 2번째 질문에서 재사용할 수 있다.

```sh
oc get llminferenceservice qwen38-int4-pd -n llmd-pd \
  -o jsonpath='{.spec.template.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'          # decode
oc get llminferenceservice qwen38-int4-pd -n llmd-pd \
  -o jsonpath='{.spec.prefill.template.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'  # prefill
```

## 실험 설계

| 항목 | 값 |
|---|---|
| 조건 | T0: `threshold: 0`(항상 분리), T1: `threshold: 1000`(임계값 분리). 둘 다 prefix 캐시 켬 |
| 부하 | 대화 40개 × 질문 2개, 문서 약 3,000토큰, 동시 4, 응답 64토큰, 조건마다 새 문서 |
| 측정 | 모든 대화의 1번째 질문을 보낸 뒤 40초 쉬고 2번째 질문을 보낸다. 그 사이에 카운터를 찍어 질문 차례별로 센다 |
| 기록 | prefill pod 경유 건수, decode·prefill의 prefix 캐시 적중률(`vllm:prefix_cache_hits_total / queries_total`), TTFT |

```sh
cd openshift-ai-llmd-demo/harness
HARNESS_PROFILE=sno ./harness.sh scenario2-05-pd-prefix-cache   # 종료 시 EPP 설정과 vLLM 인자 원복
```

## 판정 기준

- T1에서 2번째 질문의 90% 이상이 prefill pod를 거치지 않고, decode의 prefix 캐시 적중률이 높다.
- T1의 2번째 질문 TTFT가 T0의 2번째 질문보다 짧다(KV 재전송 생략).

## 결과

(실행 후 기록)

## 확장

decode를 2개로 늘리면(`spec.replicas: 2`) `prefix-cache-scorer`가 2번째 질문을 1번째와 같은 decode pod로 보내는지도
확인할 수 있다. decode가 1개인 본 구성에서는 decode 선택이 자명하다.
