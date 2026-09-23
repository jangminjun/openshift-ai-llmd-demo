#!/usr/bin/env bash
# Registers an existing LLMInferenceService with MaaS (RHOAI 3.5+) so it is
# callable through maas-default-gateway: MaaSModelRef (model side),
# MaaSSubscription (group -> token rate limit), MaaSAuthPolicy (group -> access).
# Idempotent. Re-running for a second model appends it to the same
# subscription/auth policy instead of creating new ones.
#
# Caveat: creating or changing a MaaSAuthPolicy makes maas-controller
# regenerate the gateway AuthPolicy (maas-gateway-auth), which drops any
# manual patch on it (e.g. an external OIDC identity source).
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE}"
LLMD_NAME="${LLMD_NAME:?set LLMD_NAME}"
MAAS_GROUP="${MAAS_GROUP:-llmd-demo}"
# Comma-separated users. Added to MAAS_GROUP AND listed directly as
# subscription owner / auth subject: an OpenShift OAuth token (oc whoami -t)
# only carries system:authenticated* groups in TokenReview, not Group objects,
# so group-only subscriptions never match oc-token callers.
MAAS_USERS="${MAAS_USERS:-}"
MAAS_TOKEN_LIMIT="${MAAS_TOKEN_LIMIT:-100000}"
MAAS_TOKEN_WINDOW="${MAAS_TOKEN_WINDOW:-1h}"
MAAS_PRIORITY="${MAAS_PRIORITY:-10}"         # must not collide with other subscriptions' priority
TENANT_NAMESPACE="${TENANT_NAMESPACE:-models-as-a-service}"
SUB_NAME="${MAAS_GROUP}-sub"
USERS_JSON="[]"
[ -n "$MAAS_USERS" ] && USERS_JSON="[\"$(echo "$MAAS_USERS" | sed 's/,/\",\"/g')\"]"
POLICY_NAME="${MAAS_GROUP}-access"

oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" >/dev/null \
  || { echo "LLMInferenceService $LLMD_NAMESPACE/$LLMD_NAME not found" >&2; exit 1; }

echo "== Group $MAAS_GROUP =="
oc get group "$MAAS_GROUP" &>/dev/null || oc adm groups new "$MAAS_GROUP"
if [ -n "$MAAS_USERS" ]; then
  # ServiceAccounts (system:serviceaccount:<ns>:<sa>) cannot be Group members;
  # they are only listed directly on the subscription/auth policy below.
  IFS=',' read -ra USERS <<< "$MAAS_USERS"
  GROUP_USERS=()
  for u in "${USERS[@]}"; do [[ "$u" == *:* ]] || GROUP_USERS+=("$u"); done
  [ "${#GROUP_USERS[@]}" -gt 0 ] && oc adm groups add-users "$MAAS_GROUP" "${GROUP_USERS[@]}"
fi
oc get group "$MAAS_GROUP"

echo "== MaaSModelRef $LLMD_NAMESPACE/$LLMD_NAME =="
oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${LLMD_NAME}
  namespace: ${LLMD_NAMESPACE}
spec:
  modelRef:
    kind: LLMInferenceService
    name: ${LLMD_NAME}
YAML

# has_ref <kind> <name>: is LLMD_NAME already in .spec.modelRefs?
has_ref() {
  oc get "$1" "$2" -n "$TENANT_NAMESPACE" \
    -o jsonpath='{range .spec.modelRefs[*]}{.namespace}/{.name}{"\n"}{end}' 2>/dev/null \
    | grep -qx "${LLMD_NAMESPACE}/${LLMD_NAME}"
}

echo "== MaaSSubscription $SUB_NAME (limit ${MAAS_TOKEN_LIMIT}/${MAAS_TOKEN_WINDOW}, priority ${MAAS_PRIORITY}) =="
if ! oc get maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" &>/dev/null; then
  oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${SUB_NAME}
  namespace: ${TENANT_NAMESPACE}
spec:
  priority: ${MAAS_PRIORITY}
  owner:
    groups: [{name: ${MAAS_GROUP}}]
    users: ${USERS_JSON}
  modelRefs:
  - name: ${LLMD_NAME}
    namespace: ${LLMD_NAMESPACE}
    tokenRateLimits: [{limit: ${MAAS_TOKEN_LIMIT}, window: ${MAAS_TOKEN_WINDOW}}]
    billingRate: {perToken: "0"}
YAML
elif has_ref maassubscription "$SUB_NAME"; then
  # keep the token limit in sync with MAAS_TOKEN_LIMIT/MAAS_TOKEN_WINDOW on re-runs
  idx=$(oc get maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" \
    -o jsonpath='{range .spec.modelRefs[*]}{.namespace}/{.name}{"\n"}{end}' \
    | grep -nx "${LLMD_NAMESPACE}/${LLMD_NAME}" | cut -d: -f1)
  oc patch maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" --type=json -p "[{\"op\":\"replace\",
    \"path\":\"/spec/modelRefs/$((idx - 1))/tokenRateLimits\",
    \"value\":[{\"limit\":${MAAS_TOKEN_LIMIT},\"window\":\"${MAAS_TOKEN_WINDOW}\"}]}]"
else
  oc patch maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",
    \"value\":{\"name\":\"${LLMD_NAME}\",\"namespace\":\"${LLMD_NAMESPACE}\",
    \"tokenRateLimits\":[{\"limit\":${MAAS_TOKEN_LIMIT},\"window\":\"${MAAS_TOKEN_WINDOW}\"}],\"billingRate\":{\"perToken\":\"0\"}}}]"
fi

echo "== MaaSAuthPolicy $POLICY_NAME =="
if ! oc get maasauthpolicy "$POLICY_NAME" -n "$TENANT_NAMESPACE" &>/dev/null; then
  oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${POLICY_NAME}
  namespace: ${TENANT_NAMESPACE}
spec:
  modelRefs:
  - {name: ${LLMD_NAME}, namespace: ${LLMD_NAMESPACE}}
  subjects:
    groups: [{name: ${MAAS_GROUP}}]
    users: ${USERS_JSON}
YAML
elif has_ref maasauthpolicy "$POLICY_NAME"; then
  echo "already contains ${LLMD_NAMESPACE}/${LLMD_NAME}"
else
  oc patch maasauthpolicy "$POLICY_NAME" -n "$TENANT_NAMESPACE" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${LLMD_NAME}\",\"namespace\":\"${LLMD_NAMESPACE}\"}}]"
fi

if [ -n "$MAAS_USERS" ]; then
  oc patch maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" --type=merge -p "{\"spec\":{\"owner\":{\"users\":${USERS_JSON}}}}"
  oc patch maasauthpolicy "$POLICY_NAME" -n "$TENANT_NAMESPACE" --type=merge -p "{\"spec\":{\"subjects\":{\"users\":${USERS_JSON}}}}"
fi

echo "Waiting for MaaS governance to attach (up to 60s)..."
for _ in $(seq 1 12); do
  phase=$(oc get maasmodelref "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  sub=$(oc get maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Ready" ] && [ "$sub" = "Active" ] && break
  sleep 5
done
oc get maasmodelref "$LLMD_NAME" -n "$LLMD_NAMESPACE"
oc get maassubscription "$SUB_NAME" -n "$TENANT_NAMESPACE"
oc get maasauthpolicy "$POLICY_NAME" -n "$TENANT_NAMESPACE"
oc get maasmodelref "$LLMD_NAME" -n "$LLMD_NAMESPACE" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}'
