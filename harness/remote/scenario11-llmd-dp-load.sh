#!/usr/bin/env bash
# Scenario 11 (data parallelism) load step: drives concurrent load against
# the LLMInferenceService's workload Service from an in-cluster curl pod
# (bastion has no pod-network access, so the load generator has to run
# inside the cluster -- same pattern as scenario8-kserve-vllm-load.sh), then
# reports aggregate throughput observed via kserve_http_requests_total so a
# 1-replica run and an N-replica run can be compared directly. Runs ON the
# bastion. Idempotent (deletes/recreates its own load-generator pod).
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
# python3 may be a non-functional Store alias on Windows (local mode) -> fall back to python.
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python

LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario11}"
LLMD_NAME="${LLMD_NAME:-llmd-dp-demo}"
CONCURRENCY="${CONCURRENCY:-8}"
DURATION="${DURATION:-90}"
SVC="${LLMD_NAME}-kserve-workload-svc.${LLMD_NAMESPACE}.svc.cluster.local:8000"
MODEL_NAME=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')

REPLICAS=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.replicas}')
echo "=== Current replicas: $REPLICAS ==="

oc delete pod llmd-load-generator -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo "=== Launching load generator (concurrency=$CONCURRENCY, duration=${DURATION}s) against $SVC ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: llmd-load-generator
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
              -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Write two sentences about distributed systems."}],"max_tokens":100}'
          done ) &
      done
      wait
      echo "load generator finished"
YAML

echo "Waiting ${DURATION}s for load to run..."
sleep "$DURATION"
sleep 15  # let the last in-flight requests land and Prometheus scrape

ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
oc create sa thanos-reader -n openshift-monitoring --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z thanos-reader -n openshift-monitoring >/dev/null
TOKEN=$(oc create token thanos-reader -n openshift-monitoring --duration=15m)
# ^ not `oc whoami -t`: the bastion's kubeconfig (~/ocp-install/auth/kubeconfig) authenticates via
#   client cert (system:admin), which has no bearer token to print -- hit this live 2026-09-08.
THROUGHPUT=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "query=sum(rate(kserve_http_requests_total{namespace=\"$LLMD_NAMESPACE\"}[2m]))" \
  "https://$ROUTE/api/v1/query" | "$PY" -c "import json,sys; d=json.load(sys.stdin)['data']['result']; print(d[0]['value'][1] if d else '0')")

oc delete pod llmd-load-generator -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo ""
echo "=== Result: replicas=$REPLICAS  aggregate throughput=~${THROUGHPUT} req/s ==="
echo "Record this number, then scale (LLMD_REPLICAS=N ./harness.sh scenario11-llmd-dp-scale) and re-run this load step to compare."
