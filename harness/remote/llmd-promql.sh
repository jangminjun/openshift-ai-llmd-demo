#!/usr/bin/env bash
# Instant PromQL query against Thanos Querier (platform + user-workload metrics).
# QUERY: one or more expressions separated by ';;'. Prints "labels value" rows.
# Uses the cluster-monitoring-view ServiceAccount created by llmd-prereq.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

QUERY="${QUERY:?set QUERY}"
# python3 may be a non-functional Store alias on Windows (local mode) -> fall back to python.
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python
SA_NS="${MONITORING_NAMESPACE:-gpu-monitoring}"
TOKEN=$(oc create token grafana-thanos-reader -n "$SA_NS" --duration=10m)
HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

IFS=$'\n' read -r -d '' -a QS < <(printf '%s' "$QUERY" | sed 's/;;/\n/g'; printf '\0') || true
for q in "${QS[@]}"; do
  [ -n "${q// }" ] || continue
  echo "## $q"
  curl -sk -H "Authorization: Bearer $TOKEN" --data-urlencode "query=$q" "https://$HOST/api/v1/query" \
    | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
if d.get("status") != "success":
    print("  ERROR", d.get("error")); sys.exit()
for r in d["data"]["result"]:
    m = {k: v for k, v in r["metric"].items() if k not in ("__name__", "prometheus", "endpoint", "job", "instance", "service")}
    print("  %s %s" % (json.dumps(m, sort_keys=True), r["value"][1]))
if not d["data"]["result"]:
    print("  (no data)")'
done
