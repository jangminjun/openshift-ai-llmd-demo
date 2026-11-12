# Scenario 2-06-6: EPP Flow Control against decode KV saturation on a P/D model. Long requests (batch,
# priority 0) fill the decode KV cache while an interactive probe (priority 100) and a control probe (same
# requests, priority 0) run. Conditions (S26_FC_CONDS, default "f0 f1 f2"):
#   f0  decode util 0.85, EPP config as is
#   f1  decode util 0.75, EPP config as is
#   f2  decode util 0.75, Flow Control + concurrency-detector (maxConcurrency S26_FC_MAX)
# Restores the EPP config, decode util and InferenceObjectives on exit. Prepended with lib/bench.sh.
#   S26_FC_MAX (16)  S26_FC_TTL (900s)  S26_FC_LONG_WORDS (4000, ~8k tokens)  S26_FC_LONG_OUT (4096)
#   S26_FC_LONG_CONC (32)  S26_FC_LONG_SECS (600)  S26_FC_PROBE_DELAY (180)  S26_FC_PROBE_SECS (360)
#   S26_FC_UTIL_LOW (0.75)
# Requests go to the MaaS URL through the gateway ClusterIP (LOADGEN_VIA=gateway): queued requests wait
# longer than the cloud LB idle timeout (60 s) before the first token.
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"
MAXC="${S26_FC_MAX:-16}"; TTL="${S26_FC_TTL:-900s}"; LOW="${S26_FC_UTIL_LOW:-0.75}"
LONG_SECS="${S26_FC_LONG_SECS:-600}"; DELAY="${S26_FC_PROBE_DELAY:-180}"; PROBE_SECS="${S26_FC_PROBE_SECS:-360}"
require_single_epp "$NS"
require_token_limit "$NS" "$N"
POOL=$(oc get inferencepool -n "$NS" -o name | grep "/${N}" | head -1); POOL=${POOL#*/}
[ -n "$POOL" ] || die "no InferencePool for $NS/$N"
EPP_ORIG=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}')
[ -n "$EPP_ORIG" ] || die "$NS/$N has no inline EPP config"
D_ORIG=$(vllm_args "$NS" "$N" decode | grep -oE 'gpu-memory-utilization=[0-9.]+' || echo gpu-memory-utilization=default)

restore() {
  say "restore"
  [ "$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}')" = "$EPP_ORIG" ] \
    || { epp_set "$NS" "$N" "$EPP_ORIG"; echo "  EPP config restored"; }
  [ "$(set_vllm_flags "$NS" "$N" "" "$D_ORIG")" = changed ] && echo "  decode $D_ORIG: $(pd_wait_start "$NS" "$N")"
  oc delete inferenceobjective interactive batch -n "$NS" --ignore-not-found >/dev/null
}
GDIR=$(mktemp -d)
trap 'restore; rm -rf "$GDIR"' EXIT

say "InferenceObjectives on pool $POOL"
oc apply -n "$NS" -f - <<YAML
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata: {name: interactive}
spec: {priority: 100, poolRef: {name: ${POOL}}}
---
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata: {name: batch}
spec: {priority: 0, poolRef: {name: ${POOL}}}
YAML

epp_flow_control() {  # original P/D config + Flow Control with concurrency-detector
  printf '%s' "$EPP_ORIG" | "$PY" -c '
import sys, json
c = json.load(sys.stdin); maxc, ttl = int(sys.argv[1]), sys.argv[2]
c["featureGates"] = sorted(set(c.get("featureGates", []) + ["flowControl"]))
c["plugins"] = [p for p in c["plugins"] if not p["type"].endswith("-detector") and not p["type"].endswith("-policy")]
c["plugins"] += [{"type": "concurrency-detector", "parameters": {"maxConcurrency": maxc}},
                 {"type": "fcfs-ordering-policy"}, {"type": "global-strict-fairness-policy"}]
c["flowControl"] = {"defaultRequestTTL": ttl, "saturationDetector": {"pluginRef": "concurrency-detector"}}
print(json.dumps(c))' "$MAXC" "$TTL"
}

# role_gauges: one line "prefill_run prefill_wait decode_run decode_wait decode_kv" from the vLLM pods
role_gauges() {
  local role port p
  for role in prefill decode; do
    port=8000; [ "$role" = decode ] && port=8001
    for p in $(oc get pods -n "$NS" -l "llm-d.ai/role=$role" -o name | grep "/${N}-"); do
      oc exec -n "$NS" "$p" -c main -- curl -sk "https://localhost:$port/metrics" 2>/dev/null \
        | grep -E '^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc)\{' | sed "s/^/$role /"
    done
  done | "$PY" -c '
import sys, re
v = {}
for line in sys.stdin:
    role, rest = line.split(" ", 1); name, val = rest.rsplit(" ", 1)
    k = role + ":" + re.sub(r"\{.*", "", name).replace("vllm:", "")
    v[k] = v.get(k, 0.0) + float(val)
g = lambda k: v.get(k, 0)
print("%d %d %d %d %.3f" % (g("prefill:num_requests_running"), g("prefill:num_requests_waiting"),
      g("decode:num_requests_running"), g("decode:num_requests_waiting"), g("decode:kv_cache_usage_perc")))'
}

run_cond() {  # <cond>
  local c=$1 t0 before after s
  say "condition $c: long ${S26_FC_LONG_WORDS:-4000} words / ${S26_FC_LONG_OUT:-4096} out x ${S26_FC_LONG_CONC:-32}, probes after ${DELAY}s"
  T=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N" LOADGEN_VIA=gateway TIMEOUT=1500)
  before=$(pd_counters "$NS" "$N"); t0=$(date +%s)
  loadgen_start "s266-long-$c" "${T[@]}" PROMPT_MODE=unique-long PREFIX_TOKENS="${S26_FC_LONG_WORDS:-4000}" \
    CONCURRENCY="${S26_FC_LONG_CONC:-32}" DURATION="$LONG_SECS" MAX_TOKENS="${S26_FC_LONG_OUT:-4096}" IGNORE_EOS=1 \
    HEADERS='{"x-llm-d-inference-objective":"batch"}' LABEL="long-$c"
  # sample role gauges every 15 s while the long load runs (max decode KV, where requests wait)
  ( while [ -z "$(oc get job "s266-long-$c" -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]; do
      echo "GAUGE $(( $(date +%s) - t0 )) $(role_gauges)"; sleep 15; done ) > "$GDIR/gauges-$c.txt" 2>/dev/null &
  sampler=$!
  sleep "$DELAY"
  PROBE=(CONCURRENCY=1 INTERVAL=1 DURATION="$PROBE_SECS" MAX_TOKENS=64)
  loadgen_start "s266-p100-$c" "${T[@]}" "${PROBE[@]}" HEADERS='{"x-llm-d-inference-objective":"interactive"}' LABEL="interactive-$c"
  loadgen_start "s266-p0-$c" "${T[@]}" "${PROBE[@]}" HEADERS='{"x-llm-d-inference-objective":"batch"}' LABEL="control-$c"
  for j in "s266-p100-$c" "s266-p0-$c" "s266-long-$c"; do s=$(loadgen_wait "$j"); brief "$s"; done
  wait "$sampler" 2>/dev/null || true
  after=$(pd_counters "$NS" "$N")
  echo "  $(pd_delta "$before" "$after")"
  "$PY" -c '
import sys, json
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print("  preemptions decode=%d prefill=%d" % (b["decode"].get("num_preemptions_total", 0) - a["decode"].get("num_preemptions_total", 0),
      b["prefill"].get("num_preemptions_total", 0) - a["prefill"].get("num_preemptions_total", 0)))' "$before" "$after"
  "$PY" -c '
import sys
rows = [l.split()[1:] for l in open(sys.argv[1]) if l.startswith("GAUGE") and len(l.split()) == 7]
if not rows: print("  gauges: (no samples)"); sys.exit()
col = lambda i: [float(r[i]) for r in rows]
print("  gauges max: prefill running=%d waiting=%d | decode running=%d waiting=%d kv=%.1f%% (%d samples)" % (
  max(col(1)), max(col(2)), max(col(3)), max(col(4)), 100 * max(col(5)), len(rows)))
for r in rows: print("    t=%4ss prefill run/wait=%s/%s decode run/wait=%s/%s kv=%.1f%%" % (r[0], r[1], r[2], r[3], r[4], 100 * float(r[5])))
' "$GDIR/gauges-$c.txt"
  W="$(( ($(date +%s) - t0) / 60 + 1 ))m"
  thanos_print "EPP flow-control queue wait, mean seconds by priority ($c)" \
    "sum by (priority)(increase(llm_d_epp_flow_control_request_queue_duration_seconds_sum{namespace=\"$NS\"}[$W])) / sum by (priority)(increase(llm_d_epp_flow_control_request_queue_duration_seconds_count{namespace=\"$NS\"}[$W]))"
  thanos_print "GPU memory used, max MiB ($c)" "max_over_time(max(DCGM_FI_DEV_FB_USED{exported_namespace=\"$NS\"})[$W:30s])"
  oc get pods -n "$NS" -l 'llm-d.ai/role in (prefill,decode)' --no-headers | awk '{print "  pod", $1, $3, "restarts=" $4}'
}

for c in ${S26_FC_CONDS:-f0 f1 f2}; do
  case $c in
    f0) u=0.85 ;;
    *)  u=$LOW ;;
  esac
  say "setup $c: decode util $u, Flow Control $([ $c = f2 ] && echo on || echo 'as is')"
  [ "$(set_vllm_flags "$NS" "$N" "" "gpu-memory-utilization=$u")" = changed ] && {
    r=$(pd_wait_start "$NS" "$N"); echo "  startup: $r"
    case $r in fail:*) echo "S266_RESULT $c $r"; continue ;; esac
    oc logs -n "$NS" -l llm-d.ai/role=decode -c main --tail=-1 2>/dev/null | grep -E 'Available KV cache memory|GPU KV cache size' | sed -E 's/^.*\] /  /' | tail -2
  }
  if [ "$c" = f2 ]; then
    epp_set "$NS" "$N" "$(epp_flow_control)"
    oc logs -n "$NS" "deploy/${N}-kserve-router-scheduler" | grep -oE 'Initializing experimental Flow Control layer|Creating new ConcurrencyDetector' | sort -u | sed 's/^/  EPP: /'
  else
    [ "$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}')" = "$EPP_ORIG" ] || epp_set "$NS" "$N" "$EPP_ORIG"
  fi
  run_cond "$c"
  echo "S266_RESULT $c done"
done
