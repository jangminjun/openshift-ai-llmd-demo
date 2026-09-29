# Scenario 14: latency diagnosis. Three workloads, each built to stress one stage, against
# llmd-test through MaaS (--max-num-seqs=4). For each, the vLLM histograms over exactly that
# run give queue / prefill / decode / TTFT p95, prefix-cache hit rate and peak KV-cache use;
# Two verdicts: what dominates TTFT (queue vs prefill) and what dominates the whole request
# (queue / prefill / decode), each with its share and the matching remedy.
#   W1 queue    short prompts, 16-token answers, concurrency 32 (8x the 4 slots per pod)
#   W2 prefill  unique ~5000-token prompts (2000 random words), concurrency 2 (no prefix reuse)
#   W3 decode   short prompts, exactly 512-token answers (ignore_eos), concurrency 4
# Stages are compared on the mean (_sum/_count); p95 from the coarse vLLM buckets (first bound
# 0.3 s) reads 0.285 s for anything faster and is shown for reference only.
# Prepended with lib/bench.sh.  S14_WORKLOADS ("W1 W2 W3")  S14_DURATION (60)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
require_token_limit "$NS" "$N"
D="${S14_DURATION:-60}"
wl() { case $1 in
  W1) echo "PROMPT_MODE=short CONCURRENCY=32 MAX_TOKENS=16" ;;
  W2) echo "PROMPT_MODE=unique-long PREFIX_TOKENS=2000 CONCURRENCY=2 MAX_TOKENS=16" ;;   # ~2.5 tokens/word; 6000 words exceed max-model-len 8192
  W3) echo "PROMPT_MODE=short CONCURRENCY=4 MAX_TOKENS=512 IGNORE_EOS=1" ;;
esac; }
v() {  # <promql> -> first value or NaN
  thanos "$1" | "$PY" -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "NaN")'
}
for w in ${S14_WORKLOADS:-W1 W2 W3}; do
  say "$w: $(wl "$w")"
  b=$(pod_counters "$NS")
  # shellcheck disable=SC2046
  s=$(loadgen s14 LLMD_NAMESPACE="$NS" LLMD_NAME="$N" $(wl "$w") DURATION="$D" DOC_OFFSET="$(cold_offset)" LABEL="$w")
  sleep 40; a=$(pod_counters "$NS")
  win="$((${D%.*} + 35))s"   # covers this run only (starts ~5 s after it began, see scenario doc)
  sel="namespace=\"$NS\""
  q95() { v "histogram_quantile(0.95, sum(rate(kserve_vllm:$1_bucket{$sel}[$win])) by (le))"; }
  avg() { v "sum(rate(kserve_vllm:$1_sum{$sel}[$win])) / sum(rate(kserve_vllm:$1_count{$sel}[$win]))"; }
  report "$s" "$b" "$a"
  "$PY" - "$w" "$(avg request_queue_time_seconds)" "$(avg request_prefill_time_seconds)" \
    "$(avg request_decode_time_seconds)" "$(avg time_to_first_token_seconds)" \
    "$(q95 request_queue_time_seconds)" "$(q95 request_prefill_time_seconds)" "$(q95 request_decode_time_seconds)" \
    "$(v "max(max_over_time(kserve_vllm:kv_cache_usage_perc{$sel}[$win]))")" <<'PYEOF'
import sys
w, q, p, d, t, q9, p9, d9, kv = sys.argv[1], *map(float, sys.argv[2:])
stage = {"queue": q, "prefill": p, "decode": d}
valid = {k: x for k, x in stage.items() if x == x}   # NaN != NaN: no samples in the window
if not valid:
    print("  %-24s no latency samples (all requests failed?) -> no diagnosis" % ""); sys.exit()
fix = {"queue": "requests wait for a slot -> add replicas (scenario 11) or raise --max-num-seqs",
       "prefill": "prompt processing -> raise prefix reuse / cache-aware routing, shorter prompts, faster GPU",
       "decode": "token generation -> fewer max_tokens, more replicas, larger GPU or tensor parallel (scenario 15)"}
print("  %-24s mean queue=%.3fs prefill=%.3fs decode=%.3fs ttft=%.3fs | p95 q=%.3f p=%.3f d=%.3f | kv_peak=%.1f%%" % ("", q, p, d, t, q9, p9, d9, kv * 100))
f = {k: valid.get(k, 0) for k in ("queue", "prefill")}; ft = max(f, key=f.get)
top = max(valid, key=valid.get); tot = sum(valid.values()) or 1
print("  %-24s TTFT: %s %.0f%% of queue+prefill -> %s" % ("", ft, 100 * f[ft] / (sum(f.values()) or 1), fix[ft]))
print("  %-24s request: %s %.0f%% of queue+prefill+decode -> %s" % ("", top, 100 * valid[top] / tot, fix[top]))
PYEOF
done
