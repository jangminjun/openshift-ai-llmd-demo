#!/usr/bin/env bash
# Scenario 14: llm-d latency diagnosis. Runs a short load burst against an
# already-deployed LLMInferenceService, then queries the metrics that
# distinguish *why* a request was slow -- queue wait vs prefill vs decode
# vs low cache hit rate -- instead of just reporting an aggregate TTFT.
# Metric names verified live 2026-09-07 against a real llm-d deployment
# (kserve_vllm: prefix; see monitoring-llmd-rhoai/lessonlearn.md). Runs ON
# the bastion. Requires the LLMInferenceService already deployed and Ready.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
# python3 may be a non-functional Store alias on Windows (local mode) -> fall back to python.
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE}"
LLMD_NAME="${LLMD_NAME:-llmd-demo}"
SVC="${LLMD_NAME}-kserve-workload-svc.${LLMD_NAMESPACE}.svc.cluster.local:8000"
MODEL_NAME=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')
CONCURRENCY="${CONCURRENCY:-6}"
DURATION="${DURATION:-60}"

oc delete pod llmd-latency-load -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
echo "=== Generating load (concurrency=$CONCURRENCY, ${DURATION}s) to populate latency histograms ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: llmd-latency-load
  namespace: ${LLMD_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: load
    image: curlimages/curl:latest
    command: ["sh", "-c"]
    args:
    - |
      end=\$(( \$(date +%s) + ${DURATION} ))
      for w in \$(seq 1 ${CONCURRENCY}); do
        ( while [ "\$(date +%s)" -lt "\$end" ]; do
            curl -sk -o /dev/null -m 30 -X POST "https://${SVC}/v1/chat/completions" \
              -H "Content-Type: application/json" \
              -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Summarize the plot of a mystery novel in three sentences."}],"max_tokens":150}'
          done ) &
      done
      wait
YAML
sleep "$DURATION"
sleep 15
oc delete pod llmd-latency-load -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
oc create sa thanos-reader -n openshift-monitoring --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z thanos-reader -n openshift-monitoring >/dev/null
TOKEN=$(oc create token thanos-reader -n openshift-monitoring --duration=15m)
# ^ not `oc whoami -t`: the bastion's kubeconfig (~/ocp-install/auth/kubeconfig) authenticates via
#   client cert (system:admin), which has no bearer token to print -- hit this live 2026-09-08.
q() {
  curl -sk -H "Authorization: Bearer $TOKEN" --data-urlencode "query=$1" "https://$ROUTE/api/v1/query" \
    | "$PY" -c "import json,sys; d=json.load(sys.stdin)['data']['result']; print(d[0]['value'][1] if d else 'no data')"
}

NS="$LLMD_NAMESPACE"
echo ""
echo "=== Latency breakdown (last 5m, p95) for $LLMD_NAME ==="
echo "Queue time (scheduler wait, before the engine even starts on it):"
echo "  $(q "histogram_quantile(0.95, sum(rate(kserve_vllm:request_queue_time_seconds_bucket{namespace=\"$NS\"}[5m])) by (le))") s"
echo "Prefill time (processing the prompt):"
echo "  $(q "histogram_quantile(0.95, sum(rate(kserve_vllm:request_prefill_time_seconds_bucket{namespace=\"$NS\"}[5m])) by (le))") s"
echo "Decode time (generating the output):"
echo "  $(q "histogram_quantile(0.95, sum(rate(kserve_vllm:request_decode_time_seconds_bucket{namespace=\"$NS\"}[5m])) by (le))") s"
echo "TTFT (time to first token -- prefill + queue, from the client's perspective):"
echo "  $(q "histogram_quantile(0.95, sum(rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace=\"$NS\"}[5m])) by (le))") s"
echo ""
echo "Prefix cache hit rate (low = redundant recompute = extra prefill latency):"
HITS=$(q "sum(increase(kserve_vllm:prefix_cache_hits_total{namespace=\"$NS\"}[5m]))")
QUERIES=$(q "sum(increase(kserve_vllm:prefix_cache_queries_total{namespace=\"$NS\"}[5m]))")
echo "  hits=$HITS queries=$QUERIES"
echo ""
echo "KV cache usage (high = close to eviction/preemption, a common decode-time cause):"
echo "  $(q "avg(kserve_vllm:kv_cache_usage_perc{namespace=\"$NS\"})")"
echo "Requests waiting in the engine right now:"
echo "  $(q "sum(kserve_vllm:num_requests_waiting{namespace=\"$NS\"})")"
echo ""
echo "Reading guide: if queue time dominates -> add replicas (scenario 11) or check EPP routing/InferencePool"
echo "saturation. If prefill dominates and cache hit rate is low -> check prompt reuse / prefix caching."
echo "If decode dominates -> check KV cache usage / preemption, consider tensor parallelism for a bigger model."
