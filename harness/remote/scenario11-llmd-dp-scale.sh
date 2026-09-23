#!/usr/bin/env bash
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario11}"
LLMD_NAME="${LLMD_NAME:-llmd-dp-demo}"
LLMD_REPLICAS="${LLMD_REPLICAS:?set LLMD_REPLICAS}"

oc patch llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" --type=merge -p "{\"spec\":{\"replicas\":${LLMD_REPLICAS}}}"
echo "Waiting for $LLMD_REPLICAS workload pod(s) Ready..."
for _ in $(seq 1 60); do
  READY=$(oc get pods -n "$LLMD_NAMESPACE" -l "app.kubernetes.io/name=$LLMD_NAME,kserve.io/component=workload" \
    -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || true)
  [ "$READY" -ge "$LLMD_REPLICAS" ] && break
  sleep 10
done
oc get pods -n "$LLMD_NAMESPACE" -l "app.kubernetes.io/name=$LLMD_NAME"
