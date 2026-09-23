#!/usr/bin/env bash
# Reverse of maas-register-model.sh: removes <LLMD_NAMESPACE>/<LLMD_NAME> from the
# group's MaaSSubscription and MaaSAuthPolicy (deleting them if it was the last
# model) and deletes its MaaSModelRef. Run before/after deleting an
# LLMInferenceService -- a dangling modelRef turns the subscription Degraded/Failed.
# Idempotent.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE}"
LLMD_NAME="${LLMD_NAME:?set LLMD_NAME}"
MAAS_GROUP="${MAAS_GROUP:-llmd-demo}"
TENANT_NAMESPACE="${TENANT_NAMESPACE:-models-as-a-service}"

remove_ref() {  # <kind> <name>
  oc get "$1" "$2" -n "$TENANT_NAMESPACE" &>/dev/null || { echo "$1/$2 not found"; return; }
  local refs idx count
  refs=$(oc get "$1" "$2" -n "$TENANT_NAMESPACE" -o jsonpath='{range .spec.modelRefs[*]}{.namespace}/{.name}{"\n"}{end}')
  idx=$(printf '%s\n' "$refs" | grep -nx "${LLMD_NAMESPACE}/${LLMD_NAME}" | cut -d: -f1 || true)
  count=$(printf '%s\n' "$refs" | grep -c . || true)
  if [ -z "$idx" ]; then
    echo "$1/$2 does not reference ${LLMD_NAMESPACE}/${LLMD_NAME}"
  elif [ "$count" -le 1 ]; then
    oc delete "$1" "$2" -n "$TENANT_NAMESPACE"      # modelRefs is required: drop the object
  else
    oc patch "$1" "$2" -n "$TENANT_NAMESPACE" --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/modelRefs/$((idx - 1))\"}]"
  fi
}

remove_ref maassubscription "${MAAS_GROUP}-sub"
remove_ref maasauthpolicy "${MAAS_GROUP}-access"
oc delete maasmodelref "$LLMD_NAME" -n "$LLMD_NAMESPACE" --ignore-not-found
oc get maassubscription "${MAAS_GROUP}-sub" -n "$TENANT_NAMESPACE" 2>/dev/null || true
