# Scenario 29: weight shift under continuous traffic on the MaaS OpenAI-compatible
# endpoint (body-based model routing). v1/v2 from 'harness.sh scenario29-llmd-canary-up'.
# Per-phase split is measured from vLLM request counters per version. Prepended with lib/bench.sh.
#   S29_STEPS ("90:10 50:50 0:100")  S29_PHASE_SECS (90)
NS="${LLMD_NAMESPACE:-llmd-s29}"; GROUP_MODEL="${S29_MODEL:-Qwen2.5-1.5B-Instruct}"
STEPS="${S29_STEPS:-90:10 50:50 0:100}"; PH="${S29_PHASE_SECS:-90}"
for n in llmd-v1 llmd-v2; do oc get llminferenceservice "$n" -n "$NS" >/dev/null || die "$NS/$n missing -- run scenario29-llmd-canary-up"; done
HOST=$(oc get llminferenceservice llmd-v1 -n "$NS" -o jsonpath='{.status.url}' | sed -E 's#(https://[^/]+).*#\1#')
weights() { for x in "llmd-v1:$1" "llmd-v2:$2"; do
  oc patch llminferenceservice "${x%%:*}" -n "$NS" --type=merge -p "{\"spec\":{\"router\":{\"route\":{\"group\":\"chat\",\"weight\":${x##*:}}}}}" >/dev/null; done; }
split() {  # <before-json> <after-json> -> v1 v2 counts
  "$PY" -c '
import sys, json
b, a = json.loads(sys.argv[1]), json.loads(sys.argv[2]); c = {"llmd-v1": 0, "llmd-v2": 0}
for p, v in a.items():
    k = "llmd-v1" if p.startswith("llmd-v1-") else "llmd-v2" if p.startswith("llmd-v2-") else None
    if k: c[k] += v[4] - b.get(p, [0] * 5)[4]
t = sum(c.values()) or 1
print("v1=%d v2=%d (v1 %.0f%%)" % (c["llmd-v1"], c["llmd-v2"], 100 * c["llmd-v1"] / t))' "$1" "$2"
}
first=${STEPS%% *}; weights "${first%%:*}" "${first##*:}"; sleep 20
nsteps=$(echo "$STEPS" | wc -w)
say "traffic: $HOST/v1/chat/completions model=publishers/$NS/models/$GROUP_MODEL"
loadgen_start s29 URL="$HOST/v1/chat/completions" MODEL="publishers/$NS/models/$GROUP_MODEL" CONCURRENCY=2 INTERVAL=0.2 \
  DURATION=$(( nsteps * (PH + 30) + 20 )) MAX_TOKENS=16 TIMELINE=1 LABEL=weight-shift
T0=$(date +%s)
for st in $STEPS; do
  weights "${st%%:*}" "${st##*:}"; echo "  t=$(( $(date +%s) - T0 ))s weights v1:v2 = $st"
  sleep 20; b=$(pod_counters "$NS"); sleep "$PH"; a=$(pod_counters "$NS")
  echo "    measured: $(split "$b" "$a")"
done
S=$(loadgen_wait s29); brief "$S"
printf '%s' "$S" | "$PY" -c 'import sys,json; s=json.load(sys.stdin); print("  non-200 at t=", [r[0] for r in s["timeline"] if r[1] != 200])'
