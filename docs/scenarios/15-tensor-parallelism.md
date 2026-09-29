# 시나리오 15: 텐서 병렬화 (Tensor Parallelism) — 설계, 보류

**모듈:** 분산 환경 활용 > 병렬화 전략
**상태:** 설계 완료, 측정 보류(GPU 간 NVLink 부재). 하네스 미구현.

## 목적

텐서 병렬화(TP)는 모델의 각 층 가중치를 GPU 여러 장에 나누어, 한 GPU에 들어가지 않는 모델을 서빙하거나 토큰당
지연을 줄인다. 대신 층마다 GPU 간 all-reduce 통신이 발생하므로 GPU 연결 대역폭에 성능이 좌우된다.

## 환경 제약

| 항목 | 현재 환경 | 영향 |
|---|---|---|
| GPU 연결 | A10G × 4, 모두 PCIe 호스트 브리지 경유(`PHB`), NVLink 미지원 | all-reduce가 PCIe를 거쳐 TP의 지연 단축 효과가 제한됨 |
| 디스크 | 노드 `/var` 여유 약 75GB, 모델은 pod의 `model-cache`(노드 디스크)로 다운로드 | 약 30GB 이하 모델만 안전 |
| GPU 예산 | 노드 1대 4장, `llmd-test`가 2장 사용 | TP4는 `llmd-test`를 내려야 함 |

```sh
oc exec -n nvidia-gpu-operator <driver-daemonset-pod> -c nvidia-driver-ctr -- nvidia-smi topo -m      # PHB
oc exec -n nvidia-gpu-operator <driver-daemonset-pod> -c nvidia-driver-ctr -- nvidia-smi nvlink -s    # 미지원
```

NVLink가 있는 인스턴스(예: `p4d.24xlarge`, A100 × 8)에서는 같은 설계로 TP의 본래 효과를 측정할 수 있다.

## 설계 (보류)

설정은 `LLMInferenceService.spec.parallelism.tensor`로 지정한다(vLLM 0.24, RHOAI 3.5.1). 현재 `llmd-deploy-model.sh`는
GPU 1장으로 고정되어 있어 수정이 필요하다.

| 조건 | 모델 | 구성 | 확인 사항 |
|---|---|---|---|
| A | Qwen2.5-14B (약 30GB, GPU 1장 초과) | TP1 vs TP2 | TP1 적재 실패, TP2 동작(용량 확보) |
| B | Qwen2.5-7B (약 15GB) | TP1 / TP2 / TP4 | 토큰 간 지연(ITL) 단축 폭과 PCIe 통신 비용 |
| C | Qwen2.5-7B, GPU 2장 | TP2 × 1 vs TP1 × 2(데이터 병렬화) | TP는 지연, 데이터 병렬화는 처리량(시나리오 11) |

지표: TTFT, ITL, 초당 생성 토큰 수(저동시성·고동시성).

## 예상

- A는 PCIe 환경에서도 성립한다(용량 문제의 해결).
- B는 NVLink 환경보다 ITL 단축 폭이 작고, TP4에서는 통신 비용이 이득을 상쇄할 수 있다.
- C는 같은 GPU 수에서 데이터 병렬화가 처리량에서 앞설 것으로 예상한다.
