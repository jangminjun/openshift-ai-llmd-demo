# Scenario 2-05: prefix cache with P/D. Turns on vLLM prefix caching on decode and prefill (hybrid models have it
# off by default), then for each EPP pd-profile-handler threshold runs multi-turn conversations: turn 1 sends a
# fresh document, turn 2 resends it with the answer and a new question. Counters are taken before, between and after
# the turns (loadgen PAUSE_AFTER_TURN=1), so prefill hits and decode cache hits are counted per turn.
# Restores the EPP config and the vLLM args on exit. Prepended with lib/bench.sh.
#   S25_THRESHOLDS ("0 1000")  S25_SESSIONS (40)  S25_DOC_WORDS (3000, ~3k tokens)  S25_CONCURRENCY (4)
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"
EPP_ORIG=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}')
[ -n "$EPP_ORIG" ] || die "$NS/$N has no inline EPP config"
APC_DECODE=$(vllm_args "$NS" "$N" decode | grep -c -- '--enable-prefix-caching' || true)
restore() {
  epp_set "$NS" "$N" "$EPP_ORIG"; echo "  EPP config restored"
  [ "$APC_DECODE" != 0 ] || set_vllm_flag "$NS" "$N" enable-prefix-caching default both
}
trap restore EXIT

epp_with_threshold() {
  printf '%s' "$EPP_ORIG" | "$PY" -c '
import sys, json
c = json.load(sys.stdin)
for p in c["plugins"]:
    if p["type"] == "pd-profile-handler":
        p.setdefault("parameters", {})["threshold"] = int(sys.argv[1])
print(json.dumps(c))' "$1"
}
cache_line() {  # <before> <after>: prefill requests, decode prefix-cache hit rate, decode prompt tokens
  "$PY" -c '
import sys, json
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
d = {r: {k: b[r].get(k, 0) - a[r].get(k, 0) for k in b[r]} for r in b}
dq, dh = d["decode"].get("prefix_cache_queries_total", 0), d["decode"].get("prefix_cache_hits_total", 0)
pq, ph = d["prefill"].get("prefix_cache_queries_total", 0), d["prefill"].get("prefix_cache_hits_total", 0)
print("prefill_requests=%d decode_requests=%d nixl_xfers=%d decode_cache_hit=%.0f%% prefill_cache_hit=%.0f%%" % (
  d["prefill"].get("request_success_total", 0), d["decode"].get("request_success_total", 0),
  d["decode"].get("nixl_xfer_time_seconds_count", 0), 100 * dh / dq if dq else 0, 100 * ph / pq if pq else 0))' "$1" "$2"
}

say "enable prefix caching on decode and prefill"
set_vllm_flag "$NS" "$N" enable-prefix-caching on both

for th in ${S25_THRESHOLDS:-0 1000}; do
  say "threshold $th: ${S25_SESSIONS:-40} conversations x 2 turns, document ~${S25_DOC_WORDS:-3000} tokens"
  epp_set "$NS" "$N" "$(epp_with_threshold "$th")"
  c0=$(pd_counters "$NS" "$N")
  loadgen_start "s25-$th" LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=multi-turn TURNS=2 \
    SESSIONS="${S25_SESSIONS:-40}" CONCURRENCY="${S25_CONCURRENCY:-4}" PREFIX_TOKENS="${S25_DOC_WORDS:-3000}" \
    MAX_TOKENS=64 PAUSE_AFTER_TURN=1 PAUSE_SECONDS=40 DOC_OFFSET="$(cold_offset)"
  until oc logs "job/s25-$th" -n "$BENCH_NS" 2>/dev/null | grep -q PHASE_PAUSE; do   # turn 1 of every conversation done
    [ -z "$(oc get job "s25-$th" -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}')" ] || break; sleep 3
  done
  c1=$(pd_counters "$NS" "$N")
  sum=$(loadgen_wait "s25-$th")
  c2=$(pd_counters "$NS" "$N")
  echo "  turn1 $(cache_line "$c0" "$c1")"
  echo "  turn2 $(cache_line "$c1" "$c2")"
  printf '%s' "$sum" | "$PY" -c 'import sys,json; s=json.load(sys.stdin); print("  ok=%s/%s ttft_p50_turn1=%s ttft_p50_turn2=%s" % (s["ok"], s["n"], s.get("ttft_p50_turn1"), s.get("ttft_p50_later")))'
done
