#!/usr/bin/env bash
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario11}"
LLMD_NAME="${LLMD_NAME:-llmd-dp-demo}"
oc delete pod llmd-load-generator -n "$LLMD_NAMESPACE" --ignore-not-found
oc delete llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" --ignore-not-found
echo "Scenario 11 resources deleted from $LLMD_NAMESPACE."
