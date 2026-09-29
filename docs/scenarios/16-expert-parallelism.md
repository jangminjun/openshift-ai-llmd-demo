# 시나리오 16: Expert 병렬화 (Expert Parallelism, MoE) — 설계, 보류

**모듈:** 분산 환경 활용 > 병렬화 전략
**상태:** 설계 완료, 측정 보류(GPU 간 NVLink 부재). 하네스 미구현.

## 목적

MoE(Mixture-of-Experts) 모델은 토큰마다 일부 expert만 활성화한다. Expert 병렬화(EP)는 expert들을 GPU별로 나누어
배치하며, 토큰을 담당 expert의 GPU로 보내고 받는 all-to-all 통신이 층마다 발생한다. 따라서 TP(시나리오 15)보다
GPU 간 통신에 더 민감하다.

## 환경 제약

시나리오 15와 같다. GPU 4장이 PCIe(`PHB`)로만 연결되고 NVLink가 없어 all-to-all 통신 비용이 크며, 노드 디스크 여유가
약 75GB여서 대형 MoE(예: Qwen3-30B-A3B, 약 61GB)는 제외한다. 확인 명령은 시나리오 15의 `nvidia-smi topo -m`을 따른다.

## 설계 (보류)

설정은 `LLMInferenceService.spec.parallelism`의 `tensor`와 `expert: true`로 지정한다.

| 조건 | 모델 | 구성 | 확인 사항 |
|---|---|---|---|
| A | Qwen1.5-MoE-A2.7B (전체 14.3B, 활성 2.7B, 약 29GB) | TP2 | 기준 |
| B | 같은 모델 | TP2 + expert 병렬 | 지연·처리량 변화와 all-to-all 통신 비용 |

지표: TTFT, 토큰 간 지연(ITL), 초당 생성 토큰 수.

## 예상

PCIe 환경에서는 all-to-all 통신 비용 때문에 expert 병렬이 TP보다 느릴 수 있으며, 이 경우 그 자체를 결과로 기록한다.
EP의 본래 효과(대형 MoE의 다중 노드 확장, llm-d wide-EP)는 NVLink 또는 RDMA가 있는 환경에서 검증한다.
