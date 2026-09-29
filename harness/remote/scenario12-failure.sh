# Scenario 12: failure & recovery on llmd-test through MaaS + EPP. Constant light traffic;
# S12_KILL_AT seconds in, one pod is deleted:
#   A) replica 1, delete the vLLM workload pod   (full outage, recovery incl. model download)
#   B) replica 2, delete one vLLM workload pod   (does the EPP stop routing to it? in-flight loss only?)
#   C) replica 2, delete the EPP pod             (what happens to requests while no EPP runs)
# Success/failure is counted client-side per request (server metrics miss refused connections).
# Prepended with lib/bench.sh. Restores replicas.
#   S12_ARMS ("A B C") S12_DURATION (360) S12_KILL_AT (30) S12_CONCURRENCY (4) S12_MAX_TOKENS (64)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
require_single_epp "$NS"
require_token_limit "$NS" "$N"
ORIG=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.replicas}')
KILL_AT="${S12_KILL_AT:-30}"
WL_SEL=app.kubernetes.io/component=llminferenceservice-workload
EPP_SEL=app.kubernetes.io/component=llminferenceservice-router-scheduler

ready_count() {  # <selector> -> number of Ready pods
  oc get pods -n "$NS" -l "$1" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true
}
# run_fail <label> <selector-of-pod-to-delete> <ready-count-that-means-recovered>
run_fail() {
  local label=$1 sel=$2 want=$3 pod kill rec s
  s=""; loadgen_start s12 LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=short CONCURRENCY="${S12_CONCURRENCY:-4}" \
    DURATION="${S12_DURATION:-360}" MAX_TOKENS="${S12_MAX_TOKENS:-64}" TIMEOUT=30 TIMELINE=1 LABEL="$label"
  sleep "$KILL_AT"
  pod=$(oc get pods -n "$NS" -l "$sel" -o jsonpath='{.items[0].metadata.name}')
  kill=$(date +%s); oc delete pod "$pod" -n "$NS" --wait=false >/dev/null
  echo "  $(date -u +%H:%M:%S)Z deleted $pod"
  sleep 5; rec=""
  for _ in $(seq 1 180); do
    [ "$(ready_count "$sel")" -ge "$want" ] && ! oc get pod "$pod" -n "$NS" &>/dev/null && { rec=$(date +%s); break; }
    sleep 5
  done
  s=$(loadgen_wait s12)
  "$PY" - "$s" "$kill" "${rec:-0}" <<'PYEOF'
import sys, json, statistics as st
s, kill, rec = json.loads(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
k = kill - s["start_epoch"]; r = (rec - s["start_epoch"]) if rec else None
tl = s["timeline"]; err = [t for t, c, _ in tl if c != 200]
def ttft(a, b):
    xs = [f for t, c, f in tl if c == 200 and f is not None and a <= t < b]
    return "%.2fs(n=%d)" % (st.median(xs), len(xs)) if xs else "-"
end = tl[-1][0] if tl else k
okt = sorted(t for t, c, _ in tl if c == 200 and t >= k - 5)
# outage = longest stretch without a successful request start (fast 503s inflate error counts,
# and requests in flight on the killed pod still finish, so neither count nor first-ok measures it)
gap = max((b - a for a, b in zip(okt, okt[1:])), default=None)
print("  %-14s ok=%d/%d codes=%s recovery=%s" % (s["label"], s["ok"], s["n"], json.dumps(s["codes"]),
      "%ds" % (r - k) if r else "not recovered"))
print("  %-14s errors=%d window=%s max_ok_gap=%s" % ("", len(err),
      "t+%.0fs..t+%.0fs" % (min(err) - k, max(err) - k) if err else "-", "%.1fs" % gap if gap is not None else "-"))
print("  %-14s ttft50 before=%s during=%s after=%s" % ("", ttft(0, k), ttft(k, r or end + 1), ttft(r, end + 1) if r else "-"))
buckets = {}
for t, c, _ in tl:
    b = int((t - k) // 15) * 15
    if -15 <= b <= 240: buckets.setdefault(b, [0, 0])[c != 200] += 1
print("  %-14s per 15s from kill (ok/err): %s" % ("", " ".join("%+d:%d/%d" % (b, *v) for b, v in sorted(buckets.items()))))
PYEOF
}

for arm in ${S12_ARMS:-A B C}; do case $arm in
  A) say "A) replica 1, delete the vLLM workload pod"
     set_replicas "$NS" "$N" 1; run_fail r1-kill-vllm "$WL_SEL" 1 ;;
  B) say "B) replica 2, delete one vLLM workload pod"
     set_replicas "$NS" "$N" 2; run_fail r2-kill-vllm "$WL_SEL" 2 ;;
  C) say "C) replica 2, delete the EPP pod"
     set_replicas "$NS" "$N" 2; run_fail r2-kill-epp "$EPP_SEL" 1 ;;
esac; done

say "restore"
set_replicas "$NS" "$N" "$ORIG"
