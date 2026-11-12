# scenarios-2: llm-d P/D 분리와 MaaS 토큰 한도

RHDP 클러스터(sandbox1343)에서 RHOAI 3.5.2의 llm-d Prefill/Decode(P/D) 분리 동작과, MaaS 토큰 한도에서 발생하는 429의
원인·완화 방안을 실측으로 검증한다. 진행 상황과 재개 절차는 [PROGRESS.md](PROGRESS.md)에 둔다.

## 환경

| 항목 | 값 |
|---|---|
| 클러스터 | OpenShift 4.20, RHOAI 3.5.2, Red Hat Connectivity Link 1.4.3(Limitador v2.4.2) |
| GPU | g6.12xlarge(L4 24GB × 4) 2대 |
| 모델 | `llmd-pd/qwen38-int4-pd`: Qwen3.8-27B INT4, prefill TP2 + decode TP2(같은 노드), KV 전송 NIXL |
| MaaS | 구독 `llmd-demo-sub`(장문), `llmd-demo-sub-chat`(대화형, 2-08-6) |
| 관측 | Grafana `llmd-pd-latency`, Tempo(`llmd-tracing`), vLLM·EPP 메트릭 |

```sh
oc get llminferenceservice qwen38-int4-pd -n llmd-pd
oc get pods -n llmd-pd -l 'llm-d.ai/role in (prefill,decode)'
oc get maassubscription -n models-as-a-service
```

## 시나리오

### P/D 분리

| # | 시나리오 | 핵심 결과 |
|---|---|---|
| 2-00 | [P/D 준비 작업](00-pd-disaggregation-setup.md) | 하이브리드 모델 P/D에 필요한 설정(`VLLM_SSM_CONV_STATE_LAYOUT=DS`, NIXL side channel = pod IP), Tempo·Grafana 구성 |
| 2-01 | [GuideLLM 부하 생성기](01-guidellm-loadgen.md) | OpenShift Job으로 GuideLLM 실행. 동시 1→4: 출력 26.0→74.9 tok/s |
| 2-02 | [P/D 요청 경로](02-pd-request-path.md) | EPP·prefill·decode가 한 trace로 연결. KV 전송당 약 103MB, 290MB/s |
| 2-03 | [부하 하 P/D 동작](03-pd-under-load.md) | KV 전달 실패 0. 8K 프롬프트에서 TTFT 7→27초에도 ITL 35.9ms 유지. 병목은 prefill |
| 2-04 | [P/D 결정 임계값](04-pd-decider-threshold.md) | 짧은 요청은 prefill 생략, TTFT 0.52→0.10초. 긴 요청은 그대로 분리 |
| 2-05 | [prefix 캐시와 P/D](05-pd-prefix-cache.md) | 2번째 질문 TTFT −40%. 하이브리드 블록(1,568토큰) 때문에 decider 기준은 블록 크기 이상 필요 |
| 2-06 | [역할별 GPU 메모리 설정](06-gpu-memory-utilization.md) | 전 구성 OOM 없음. 권장: prefill util 0.75 + max-num-seqs 8, decode util 0.90. prefill enforce-eager는 처리량 −13~22%. 장문 부하에서 Flow Control(16)이 preemption 83→0, 처리량 +76%. 하위 [06-1](06-1-role-memory-utilization.md) util, [06-2](06-2-prefill-enforce-eager.md) enforce-eager, [06-3](06-3-prefill-batched-tokens.md) 배치 토큰, [06-4](06-4-prefill-max-num-seqs.md) max-num-seqs, [06-5](06-5-role-memory-combined.md) 통합, [06-6](06-6-epp-flow-control.md) EPP Flow Control |

### MaaS 토큰 한도와 429 ([429-error/](429-error/))

| # | 시나리오 | 핵심 결과 |
|---|---|---|
| 2-07 | [장문 호출과 MaaS 토큰 한도](429-error/07-maas-token-ratelimit.md) | 응답 후 차감 + 첫 차감부터의 고정 구간. `Retry-After` 없음 |
| 2-08 | [429 원인 검증과 완화 방안](429-error/08-429-root-cause-and-mitigation.md) | 429는 토큰 한도에서만 발생. 서버 포화는 429가 아니라 ELB 60초 연결 끊김 |
| 2-08-0 | [rate-limit 헤더](429-error/08-0-ratelimit-headers.md) | Limitador v2.4.2의 토큰 한도 경로는 `X-RateLimit-*`를 만들지 않음(v2.6.0부터 지원) |
| 2-08-1 | [토큰 한도 재설계](429-error/08-1-limit-sizing.md) | 단기 한도 ≥ 단일 요청 최대 토큰 × 동시 실행 수이면 429 0건 |
| 2-08-2 | [prefix 캐시와 토큰 차감](429-error/08-2-prefix-cache.md) | TTFT −65%이나 차감량은 같음(429 대책 아님) |
| 2-08-3 | [배치 토큰](429-error/08-3-batched-tokens.md) | 429와 무관, 단문 TTFT −13% |
| 2-08-4 | [재시도 정책](429-error/08-4-retry-backoff.md) | 지수 백오프: 429 1/6, 완료 시간 +3% |
| 2-08-5 | [동시 실행 제한](429-error/08-5-concurrency-cap.md) | 동시 1이면 429 0건, 완료 시간 +40%(클라이언트 구현) |
| 2-08-6 | [구독 분리](429-error/08-6-subscription-split.md) | 대화형 별도 구독으로 단문 429 0건 |
| 2-08-7 | [입력 압축](429-error/08-7-input-compression.md) | 입력 1/3이면 구간당 처리 2→5건 |

## 주요 결론

1. **P/D는 부하에서도 정상 분리되며, 긴 prefill이 decode 속도를 떨어뜨리지 않는다(2-03).** 처리량 상한은 prefill이 정한다.
2. **짧은 요청과 캐시된 대화는 prefill을 건너뛰는 편이 빠르다(2-04, 2-05).** 하이브리드 모델은 decider 기준
   (`nonCachedTokens`)을 KV 블록 크기(`vllm:cache_config_info`의 `block_size`) 이상으로 둔다.
3. **장문 후 429는 MaaS 토큰 한도의 설계 문제이다(2-07, 2-08).** 단기 한도를 단일 요청 × 동시 실행 수 이상으로 두고, 남는
   429는 지수 백오프로 처리한다.

## 하네스

모든 명령은 `harness/`에서 `HARNESS_PROFILE=sno`로 실행하며, 종료 시 바꾼 설정(EPP, vLLM 인자, MaaS 한도)을 원복한다.

| 명령 | 시나리오 |
|---|---|
| `./harness.sh guidellm` | 2-01 |
| `./harness.sh scenario2-03-pd-load` | 2-03 |
| `./harness.sh scenario2-04-pd-decider` | 2-04 |
| `./harness.sh scenario2-05-pd-prefix-cache` | 2-05 |
| `./harness.sh scenario2-07-maas-ratelimit` | 2-07 |
| `./harness.sh scenario2-08-mitigation` (`MAAS_MIT_ARMS`) | 2-08, 2-08-0~2-08-6 |

## 문서 구성

각 시나리오 문서는 목적 → 설정 → 실험설계 → 결과 → 결론의 순서로 쓴다. 그림은 `images/<번호>/`, 429 관련 그림은
`429-error/images/`에 둔다. 버그와 트러블슈팅은 저장소 루트의 `lessonlearn.md`에 기록한다.
