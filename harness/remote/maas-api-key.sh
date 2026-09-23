#!/usr/bin/env bash
# Mints a MaaS API key (sk-oai-...) for the current oc user via maas-api and
# stores it in Secret <KEY_NAMESPACE>/<KEY_SECRET> (key: token), which
# llmd-loadgen uses in preference to its ServiceAccount token.
# Why API keys: an oc/ServiceAccount token makes Authorino call the kube API
# (TokenReview) per request; the Kuadrant auth call has a 200ms timeout with
# failureMode=deny, so a slow API server yields sporadic HTTP 500s. API keys
# are validated by maas-api (cached 60s) instead.
# Needs a user token (oc whoami -t), so run with HARNESS_EXEC=local.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

KEY_NAME="${KEY_NAME:-llmd-loadgen}"
KEY_NAMESPACE="${KEY_NAMESPACE:-llmd-bench}"
KEY_SECRET="${KEY_SECRET:-loadgen-token}"
USER_TOKEN=$(oc whoami -t 2>/dev/null) || { echo "No user token (oc whoami -t) -- run locally after oc login." >&2; exit 1; }
MAAS_HOST="maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"

resp=$(curl -sk -X POST "https://${MAAS_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${USER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${KEY_NAME}\",\"description\":\"llm-d harness\"}")
key=$(printf '%s' "$resp" | sed -n 's/.*"key":"\(sk-oai-[^"]*\)".*/\1/p')
[ -n "$key" ] || { echo "API key creation failed: $resp" >&2; exit 1; }
printf '%s' "$resp" | sed 's/"key":"sk-oai-[^"]*"/"key":"sk-oai-***"/'; echo

oc get namespace "$KEY_NAMESPACE" &>/dev/null || oc create namespace "$KEY_NAMESPACE"
oc create secret generic "$KEY_SECRET" -n "$KEY_NAMESPACE" --from-literal=token="$key" \
  --dry-run=client -o yaml | oc apply -f -
echo "Stored in secret $KEY_NAMESPACE/$KEY_SECRET (key: token)."
