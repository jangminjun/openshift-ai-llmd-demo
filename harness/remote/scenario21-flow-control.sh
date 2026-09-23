# Scenario 21: priority flow control. Batch (priority 0) saturates the pool while an
# interactive probe (priority 100) and a control probe (same requests, priority 0)
# run concurrently. Prepended with lib/bench.sh.
#   S21_DETECTOR   concurrency (default, works) | utilization (reproduces priority inversion)
#   S21_MAX_NUM_SEQS vLLM --max-num-seqs used to reach saturation (default 4)
#   S21_BATCH_SECS / S21_PROBE_SECS  durations (default 420 / 300)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
DET="${S21_DETECTOR:-concurrency}"; SEQS="${S21_MAX_NUM_SEQS:-4}"
BATCH_SECS="${S21_BATCH_SECS:-420}"; PROBE_SECS="${S21_PROBE_SECS:-300}"
require_single_epp "$NS"

say "1) saturation setup: vLLM --max-num-seqs=$SEQS"
set_max_num_seqs "$NS" "$N" "$SEQS"

say "2) InferenceObjectives (header x-llm-d-inference-objective)"
oc apply -n "$NS" -f - <<YAML
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata: {name: interactive}
spec: {priority: 100, poolRef: {name: ${N}-inference-pool}}
---
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata: {name: batch}
spec: {priority: 0, poolRef: {name: ${N}-inference-pool}}
YAML

say "3) EPP flow control on ($DET-detector)"
CFG=$("$PY" -c '
import sys, json
c = json.loads(sys.argv[1]); det, seqs = sys.argv[2], int(sys.argv[3])
c["featureGates"] = ["flowControl"]
if det == "concurrency":
    c["plugins"].append({"type": "concurrency-detector", "parameters": {"maxConcurrency": seqs}})
else:
    c["plugins"].append({"type": "utilization-detector", "parameters": {"queueDepthThreshold": 2, "kvCacheUtilThreshold": 0.8}})
c["plugins"] += [{"type": "fcfs-ordering-policy"}, {"type": "global-strict-fairness-policy"}]
c["flowControl"] = {"defaultRequestTTL": "300s", "saturationDetector": {"pluginRef": det + "-detector"}}
print(json.dumps(c))' "$(epp_default "$(tls_scheme)")" "$DET" "$SEQS")
epp_set "$NS" "$N" "$CFG"
oc logs -n "$NS" "deploy/${N}-kserve-router-scheduler" | grep -oE 'Initializing experimental Flow Control layer|Creating new (Concurrency|Utilization)Detector' | sort -u | sed 's/^/  /'

say "4) batch load ${BATCH_SECS}s, probes after 60s"
T=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N")
loadgen_start s21-batch "${T[@]}" PROMPT_MODE=unique-long PREFIX_TOKENS=1500 CONCURRENCY=24 DURATION="$BATCH_SECS" \
  MAX_TOKENS=256 HEADERS='{"x-llm-d-inference-objective":"batch"}' LABEL=batch-p0
sleep 60
PROBE=(CONCURRENCY=1 INTERVAL=2 DURATION="$PROBE_SECS" MAX_TOKENS=32)
loadgen_start s21-p100 "${T[@]}" "${PROBE[@]}" HEADERS='{"x-llm-d-inference-objective":"interactive"}' LABEL=interactive-p100
loadgen_start s21-p0 "${T[@]}" "${PROBE[@]}" HEADERS='{"x-llm-d-inference-objective":"batch"}' LABEL=control-p0
for j in s21-p100 s21-p0 s21-batch; do brief "$(loadgen_wait $j)"; done
W="$(( BATCH_SECS / 60 + 1 ))m"
thanos_print "EPP flow-control queue wait, mean seconds by priority" \
  "sum by (priority)(increase(llm_d_epp_flow_control_request_queue_duration_seconds_sum{namespace=\"$NS\"}[$W])) / sum by (priority)(increase(llm_d_epp_flow_control_request_queue_duration_seconds_count{namespace=\"$NS\"}[$W]))"
thanos_print "vLLM waiting queue, max" "max_over_time(sum(kserve_vllm:num_requests_waiting{namespace=\"$NS\"})[$W:15s])"

say "5) restore"
[ "${S21_KEEP:-false}" = true ] || epp_restore_default "$NS" "$N"
echo "  (InferenceObjectives and --max-num-seqs=$SEQS kept; S21_MAX_NUM_SEQS=default to reset via scenario27/23 helpers)"
