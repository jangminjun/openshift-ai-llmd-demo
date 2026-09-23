# 시나리오 27: 스케줄러 라우팅 로직 및 Scorer 가중치 튜닝

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** `spec.router.scheduler.config` (`inline` / `ref`), `EndpointPickerConfig`

## 목적

운영자가 Scorer 가중치를 워크로드 특성에 맞게 변경했을 때 라우팅 분포와 지연이 의도대로 달라짐을
검증한다. 시나리오 22가 신규 Scorer의 효과를 보이는 데 비해, 본 시나리오는 정책 간 비교에 초점을 둔다.

## 구성

replica 2 (GPU 2), EPP 활성화. 두 정책과 두 워크로드를 교차 측정한다.

| 정책 | prefix-cache | queue | kv-cache-utilization | 의도 |
|---|---|---|---|---|
| P1 캐시 우선 | 5 | 1 | 1 | 공통 prefix 재사용 극대화 |
| P2 부하 우선 | 1 | 3 | 3 | pod 간 부하 균등화 |

| 워크로드 | 특성 |
|---|---|
| W1 | 공통 system prompt(2,000 토큰) + 짧은 질문 |
| W2 | 상호 무관한 긴 프롬프트, 높은 동시성 |

## 절차

```sh
NS=llmd-s28; NAME=llmd-tune
# 정책 적용 (P1 → P2): inline 설정 변경 후 EPP 재기동 확인
oc patch llminferenceservice $NAME -n $NS --type=merge --patch-file p1.yaml
oc rollout status deploy -n $NS ${NAME}-kserve-router-scheduler
oc logs -n $NS deploy/${NAME}-kserve-router-scheduler | grep -iE 'plugin|weight' | head
# 각 정책 × 워크로드 조합에서 90초 부하 → pod별 요청 수, TTFT p50/p95, 처리량 기록
```

```promql
sum by (pod) (increase(kserve_vllm:request_success_total{namespace="llmd-s28"}[2m]))
```

## 판정 기준

| 조합 | 기대 결과 |
|---|---|
| W1 × P1 | pod 편중 발생, TTFT 최저 |
| W1 × P2 | 분포 균등, TTFT 증가 |
| W2 × P2 | 분포 균등, p95 지연 최저 |
| W2 × P1 | 특정 pod 과부하 가능, p95 증가 |

정책 변경이 재배포 없이(EPP 재기동만으로) 반영되는지 함께 기록한다.

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-1.5B-Instruct, T4 × 2, MaaS Gateway 경유)

정책 적용: `spec.router.scheduler.config.inline` 변경 → 컨트롤러가 EPP `--config-text`를 갱신하고
EPP `Deployment`를 재기동한다(약 60초). vLLM pod는 재기동되지 않는다.

**1차: vLLM 기본 `max-num-seqs`(256)**

| 조합 | 성공 | TTFT p50 / p95 | E2E p95 | prefix 적중률 | pod 분포 |
|---|---|---|---|---|---|
| W1 × P1 캐시 우선 | 450/450 | **1.15 / 3.30 s** | 6.90 s | 68.3% | 217:233 |
| W1 × P2 부하 우선 | 450/450 | 1.50 / 3.19 s | 7.63 s | 67.2% | 235:215 |
| W2 × P1 | 89/91 | 1.84 / 10.53 s | 27.04 s | 0.5% | 44:45 |
| W2 × P2 | 87/87 | 1.85 / 10.48 s | 26.95 s | 0.5% | 43:44 |
| W3(hot-spot, 문서 1종) × P2 | 296/297 | 0.20 / 2.74 s | 6.70 s | 99.4% | **296:0** |
| W3 × P1 | 257/257 | 0.20 / 2.25 s | 8.94 s | 99.3% | **0:257** |

- W1에서 P1은 TTFT p50을 23% 단축하였다. 적중률은 두 정책 모두 이론 상한(문서당 3회 → 66.7%)에 도달하였다.
- W2(캐시 신호 없음)에서는 두 정책이 동일하게 균등 분산하였다.
- **W3에서 P2(queue·kv 가중치 3)조차 전량을 한 pod로 보냈다.** vLLM이 동시 16건을 대기열 없이 처리하여
  (`num_requests_waiting` = 0) queue·kv Scorer가 두 pod에 동일 점수를 부여했고, prefix Scorer만 차이를 만들었다.
  즉 **부하 Scorer의 가중치는 부하 신호(대기열, KV 사용률)가 실제로 발생할 때만 효과가 있다.**

**2차: `max-num-seqs=4`(대기열 발생 조건), W3 hot-spot, API 키 인증**

| 조합 | 성공 | TTFT p50 / p95 | E2E p95 | 처리량 | prefix 적중률 | pod 분포 |
|---|---|---|---|---|---|---|
| W3 × P1 캐시 우선 | 133/133 | 9.04 / 10.83 s | 14.27 s | 1.29 req/s | 98.9% | **0:133** |
| W3 × P2 부하 우선 | 204/205 | **3.65 / 7.54 s** | 11.23 s | **2.06 req/s** | 98.7% | **101:103** |

대기열이 형성되자 P2는 queue·kv Scorer로 부하를 분산하여 TTFT p50을 2.5배 단축하고 처리량을 1.6배
높였다. 적중률은 두 pod 모두 동일 문서를 캐시하여 유지되었다. 반면 P1은 prefix 친화도로 한 pod에 집중하였다.
**결론: 캐시 우선 가중치는 문서가 분산된 워크로드(W1)에, 부하 우선 가중치는 소수 hot prefix와 포화가
동반되는 워크로드(W3)에 적합하며, 기본값(prefix 3, queue 2, kv 2, lru 2)은 두 경우의 절충이다.**

## 운영상 유의 사항

- **`scheduler.config`를 제거해도 기본값으로 복귀하지 않는다.** EPP `Deployment`의 `--config-text`가
  마지막 인라인 설정으로 남는다(3.5.1 실측). 기본값으로 되돌리려면 기본 구성을 인라인으로 명시한다.
- `metrics-data-source`(`scheme: https`)는 인라인 설정에 항상 포함한다.
