# 시나리오 24: 멀티모달 입력 라우팅

**모듈:** 서빙 및 추론 > 분산 추론 (GA)
**관련 컴포넌트:** EPP `prefix-cache-scorer`(멀티모달 인지), VLM(vLLM)

## 목적

이미지와 텍스트가 결합된 프롬프트에서 EPP가 멀티모달 콘텐츠의 prefix cache를 인지하여, 동일 이미지를
포함한 재요청을 KV 캐시가 존재하는 pod로 라우팅하고 TTFT를 단축함을 검증한다.

## 구성

- 모델: `hf://Qwen/Qwen2.5-VL-3B-Instruct` (T4 적재 가능 크기), replica 2 (GPU 2), EPP 활성화
- vLLM 인자: `--max-model-len=8192 --limit-mm-per-prompt={"image":1}`
- 입력: 고정 이미지 3종(base64 data URL, 외부 네트워크 의존 제거)

## 하네스 실행

```sh
./harness.sh llmd-test-down && ./harness.sh scenario24-llmd-vlm-up
./harness.sh scenario24-llmd-vlm-run
./harness.sh scenario24-llmd-vlm-down && ./harness.sh llmd-test-up
```

수동 절차는 아래와 같으며, 하네스 명령은 동일 절차를 수행하고 설정을 원복한다.

## 절차

```sh
NS=llmd-s25; NAME=llmd-vlm
oc get pods -n $NS -l app.kubernetes.io/name=$NAME -o wide
# 1) 이미지 A + 질문 1 → 응답 pod, TTFT 기록
# 2) 이미지 A + 질문 2 (동일 이미지 재요청) → 응답 pod, TTFT 기록
# 3) 이미지 B, C로 반복
# 4) 대조군: 동일 요청을 워크로드 Service 직접 호출
```

요청 본문 예시:
```json
{"model":"Qwen2.5-VL-3B-Instruct","max_tokens":64,
 "messages":[{"role":"user","content":[
   {"type":"image_url","image_url":{"url":"data:image/png;base64,<...>"}},
   {"type":"text","text":"이 이미지를 설명하라"}]}]}
```

응답 pod 식별은 EPP 로그의 선택 endpoint 또는 pod별 `kserve_vllm:prompt_tokens_total` 증가분으로 한다.

## 판정 기준

| 지표 | 통과 조건 |
|---|---|
| 동일 이미지 재요청의 라우팅 | 첫 요청과 동일 pod (EPP 경유) |
| 재요청 TTFT | 첫 요청 대비 감소, 대조군 대비 낮음 |
| prefix cache 적중률 | EPP 경유 > 대조군 |

## 실측 결과 (2026-09-23, RHOAI 3.5.1, Qwen2.5-VL-3B-Instruct, T4 × 2 replica, MaaS Gateway 경유)

**통과.** 배포: `LLMD_MEMORY=8Gi`(12Gi는 g4dn에서 스케줄 불가), vLLM `--limit-mm-per-prompt.image=1`.
T4는 FlashAttention2 미지원으로 대체 백엔드가 자동 선택되었다. pod당 KV 캐시 95,504 토큰.

부하: 시드 고정 이미지 150종(`https://picsum.photos/seed/llmd{n}/896/896`, 이미지당 약 1,000 토큰) × 질문
무작위, 600 요청(이미지당 4회), 동시성 8, 스트리밍. 이미지 총량(약 15만 토큰)이 pod당 KV 용량을 초과하도록 설계.

| 지표 | 기본 EPP (Scorer 4종) | random-picker | 차이 |
|---|---|---|---|
| prefix cache 적중률 | **75.4%** | 51.9% | +23.5%p |
| 멀티모달 캐시(`mm_cache`) 적중률 | **76.1%** | 60.8% | +15.3%p |
| TTFT p50 / p95 | **0.30 s / 3.36 s** | 1.16 s / 3.96 s | p50 3.8배 단축 |
| E2E p95 | **4.33 s** | 5.68 s | |
| 처리량 | **4.73 req/s** | 2.90 req/s | 1.6배 |
| pod 분포 | 285 : 314 | 307 : 287 | |

기본 EPP의 적중률(75%)은 이미지당 최초 1회만 miss가 발생하는 이론 상한(3/4)과 일치한다. 동일 이미지
재요청이 해당 이미지의 KV/인코더 캐시를 보유한 pod로 라우팅되었다. 외부 토크나이저 없이 기본 구성(요청
본문의 이미지 참조를 포함한 prefix 해시)만으로 달성되었다.

## 발견 사항: MaaS 경유 non-streaming 응답 본문 유실

- `stream: false` 요청의 30~40%가 **HTTP 200, 본문 0바이트**로 응답되었다(20회 중 EPP 모델 6회, EPP 없는
  대조 모델 8회). vLLM 직접 호출은 정상이며, 스트리밍 요청은 영향이 없었다.
- Gateway access log는 `200 via_upstream`, 전송 0바이트이며 동시에 Kuadrant wasm-shim이
  `proxy_on_grpc_receive invalid context_id`를 기록하였다. llm-d(EPP)가 아닌 MaaS 토큰 집계 경로의 문제이다.
- 토큰 한도는 스트리밍(`include_usage` 유무 무관)과 non-streaming 모두 집계·적용되었다(300 토큰/1분 한도 초과 시 429).
- 운영 지침: MaaS 클라이언트는 `stream: true`를 사용한다.

## 검증 필요 사항

- 외부 토크나이저(`token-producer` + `vllm launch render`, 시나리오 28) 적용 시 멀티모달 토큰 정확도 향상 여부
