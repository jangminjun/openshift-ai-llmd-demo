#!/usr/bin/env bash
# Publish one Grafana dashboard JSON (copied to ~/ocp-install/$DASHBOARD_FILE) as a GrafanaDashboard CR
# for the Grafana instance created by llmd-prereq.sh. Idempotent.
#   - ${DS_THANOS} placeholders are replaced with the live thanos-querier datasource uid
#     (the operator's name-based input mapping does not resolve real uids; see llmd-monitoring.sh).
#   - Dashboards using a "datasource" template variable need no substitution: thanos-querier is the default.
set -euo pipefail
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"
GRAFANA_NAME="${GRAFANA_NAME:-gpu-grafana}"
SRC="$HOME/ocp-install/${DASHBOARD_FILE:?set DASHBOARD_FILE}"

oc get grafana "$GRAFANA_NAME" -n "$MONITORING_NAMESPACE" >/dev/null 2>&1 \
  || { echo "Grafana $MONITORING_NAMESPACE/$GRAFANA_NAME not found -- run 'harness.sh llmd-prereq' first" >&2; exit 1; }

RESOLVED="${SRC%.json}.resolved.json"
if grep -q '\${DS_THANOS}' "$SRC"; then
  uid=$(oc get grafanadatasource thanos-querier -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.uid}')
  [ -n "$uid" ] || { echo "thanos-querier datasource uid not found" >&2; exit 1; }
  sed "s/\${DS_THANOS}/${uid}/g" "$SRC" > "$RESOLVED"
else
  cp "$SRC" "$RESOLVED"
fi

NAME="${DASHBOARD_NAME:-$(jq -r '.uid // empty' "$RESOLVED" | tr '[:upper:]_' '[:lower:]-')}"
[ -n "$NAME" ] || NAME=$(basename "${SRC%.json}")

jq -n --rawfile dash "$RESOLVED" --arg name "$NAME" --arg ns "$MONITORING_NAMESPACE" --arg g "$GRAFANA_NAME" '
  { apiVersion: "grafana.integreatly.org/v1beta1", kind: "GrafanaDashboard",
    metadata: { name: $name, namespace: $ns },
    spec: { instanceSelector: { matchLabels: { dashboards: $g } }, json: $dash } }' | oc apply -f -

for _ in $(seq 1 24); do
  [ "$(oc get grafanadashboard "$NAME" -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="DashboardSynchronized")].status}' 2>/dev/null)" = True ] && break
  sleep 5
done
oc get grafanadashboard "$NAME" -n "$MONITORING_NAMESPACE" \
  -o jsonpath='{.metadata.name}: synchronized={.status.conditions[?(@.type=="DashboardSynchronized")].status} {.status.conditions[?(@.type=="DashboardSynchronized")].message}{"\n"}'
host=$(oc get route -n "$MONITORING_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
echo "Grafana: https://${host}/d/$(jq -r '.uid' "$RESOLVED")"
