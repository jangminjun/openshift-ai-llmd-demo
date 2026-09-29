# 시나리오 16: Expert 병렬화 (Expert Parallelism, MoE) — 계획 (미구현)

**모듈:** 분산 환경 활용 > 병렬화 전략
**상태:** 문서만 존재, 하네스 스크립트 없음 — 아래 사전 조건이 충족되면 구현

## 목적

MoE(Mixture-of-Experts) 모델의 expert들을 GPU 여러 장에 나눠 배치했을 때의 지연/처리량을 검증한다.
EP는 토큰마다 일부 expert만 활성화되지만(예: Qwen3.5-35B-A3B는 활성 파라미터 3B뿐), **전체 expert
가중치를 어딘가엔 다 올려둬야 하고**, 라우팅된 토큰을 담당 GPU로 보내는 all-to-all 통신이 발생한다 —
이 통신이 지연의 10~30%까지 차지한다는 연구 결과가 있다 ([참고](https://www.premai.io/blog/multi-gpu-llm-inference-tp-vs-pp-vs-ep-parallelism-guide-2026/)).

## 왜 지금 못 하나

1. **모델**: 우리가 검증한 소형 모델(Qwen2.5-7B 등)은 MoE가 아님. MoE 모델(Qwen3.5-35B-A3B,
   Qwen3.6-35B-A3B 등)이 필요 — 전체 가중치가 크고(~35B), 이 harness가 아직 vLLM의 Qwen3.5/3.6
   아키텍처(hybrid Gated DeltaNet + Gated Attention) 호환성을 확인하지 못했다 (`llmd-deploy-model.sh`
   주석 참고).
2. **GPU**: expert를 나눌 멀티GPU가 필요하다. 현재 g5.24xlarge(A10G × 4, 총 96GB)는 FP8/INT4 양자화 없이는
   35B급 전체 가중치 적재가 빠듯하다.

## 사전 조건 (구현 시)

1. `docs/scenarios/qwen3.5-compat-check.md`(별도 작성 필요)로 RHOAI 3.5.1의 vLLM 빌드가 Qwen3.5/3.6을
   로드할 수 있는지 먼저 확인 — 실패하면 vLLM 버전이 해당 아키텍처를 지원할 때까지 이 시나리오는 보류.
2. 멀티GPU 노드 (시나리오 15와 동일한 방식)
3. vLLM MoE 관련 인자 조사 (expert-parallel-size 등 — vLLM 버전에 따라 플래그명이 다를 수 있어 확인 필요)

## 예상 검증 항목

- EP 활성화 전/후 처리량 비교
- all-to-all 통신이 실제로 지연에 얼마나 기여하는지 (시나리오 14의 지연 진단 방법론을 확장해서 통신
  구간을 별도로 뽑아낼 수 있는지 조사 필요 — vLLM/llm-d 메트릭에 이 구간이 노출되는지부터 확인)

## 실측 결과

_(미착수 — Qwen3.5/3.6 vLLM 호환성 확인 및 멀티GPU 노드 배포 결정 후 진행)_
