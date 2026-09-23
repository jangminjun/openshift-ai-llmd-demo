#!/usr/bin/env bash
# Scenario 12: llm-d failure & recovery. Starts continuous light background
# traffic against a (already-deployed, single-replica) LLMInferenceService,
# then kills its workload pod mid-flight and measures: how long until a new
# pod is Ready again, and what the request-level blast radius was (error
# rate during the outage window, via kserve_http_requests_total -- see
# monitoring-llmd-rhoai/lessonlearn.md for why that metric and not
# finished_reason="error"). Runs ON the bastion. Assumes
# llmd-deploy-model.sh (via `harness.sh llmd-deploy-model`) already ran.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
# python3 may be a non-functional Store alias on Windows (local mode) -> fall back to python.
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE}"
LLMD_NAME="${LLMD_NAME:-llmd-demo}"
SVC="${LLMD_NAME}-kserve-workload-svc.${LLMD_NAMESPACE}.svc.cluster.local:8000"
MODEL_NAME=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')
TRAFFIC_DURATION="${TRAFFIC_DURATION:-180}"

oc delete pod llmd-failure-traffic -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo "=== Starting background traffic (1 req/s for ${TRAFFIC_DURATION}s) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: llmd-failure-traffic
  namespace: ${LLMD_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: load
    image: curlimages/curl:latest
    command: ["sh", "-c"]
    args:
    - |
      end=\$(( \$(date +%s) + ${TRAFFIC_DURATION} ))
      while [ "\$(date +%s)" -lt "\$end" ]; do
        curl -sk -o /dev/null -m 20 -X POST "https://${SVC}/v1/chat/completions" \
          -H "Content-Type: application/json" \
          -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
        sleep 1
      done
YAML

echo "Warming up 20s before killing a pod..."
sleep 20

TARGET_POD=$(oc get pods -n "$LLMD_NAMESPACE" -l "app.kubernetes.io/name=$LLMD_NAME,kserve.io/component=workload" \
  -o jsonpath='{.items[0].metadata.name}')
KILL_TS=$(date +%s)
echo "=== $(date -u +%H:%M:%S)Z Killing workload pod: $TARGET_POD ==="
oc delete pod "$TARGET_POD" -n "$LLMD_NAMESPACE"

echo "Polling for a new pod to become Ready (up to 10m)..."
READY=false
for _ in $(seq 1 120); do
  READY=$(oc get pods -n "$LLMD_NAMESPACE" -l "app.kubernetes.io/name=$LLMD_NAME,kserve.io/component=workload" \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  [ "$READY" = "true" ] && break
  sleep 5
done
RECOVER_TS=$(date +%s)
RECOVERY_S=$((RECOVER_TS - KILL_TS))
if [ "$READY" = "true" ]; then
  echo "=== New pod Ready after ${RECOVERY_S}s ==="
else
  echo "=== Still NOT Ready after ${RECOVERY_S}s (gave up polling) ===" >&2
fi

echo "Waiting for remaining traffic + Prometheus scrape to settle..."
sleep 45

ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
oc create sa thanos-reader -n openshift-monitoring --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z thanos-reader -n openshift-monitoring >/dev/null
TOKEN=$(oc create token thanos-reader -n openshift-monitoring --duration=15m)
# ^ not `oc whoami -t`: the bastion's kubeconfig (~/ocp-install/auth/kubeconfig) authenticates via
#   client cert (system:admin), which has no bearer token to print -- hit this live 2026-09-08.
echo ""
echo "=== Request status codes around the outage window (last 5m) ==="
curl -sk -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "query=sum(increase(kserve_http_requests_total{namespace=\"$LLMD_NAMESPACE\"}[15m])) by (status)" \
  "https://$ROUTE/api/v1/query" | "$PY" -m json.tool

oc delete pod llmd-failure-traffic -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

echo ""
echo "=== Summary ==="
echo "Killed pod: $TARGET_POD at $(date -u -d "@$KILL_TS" +%H:%M:%S)Z"
echo "New pod Ready: $((RECOVERY_S))s later"
echo "See the status breakdown above for how many requests failed (5xx/connection errors) during the gap."
