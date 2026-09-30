#!/usr/bin/env bash
# Runs on the bastion or locally (HARNESS_EXEC), after llmd-prereq and after an LLMInferenceService
# is deployed in LLMD_NAMESPACE. Verifies the auto-generated ServiceMonitor/
# PodMonitor, applies a PrometheusRule (TTFT p95 + error-rate thresholds),
# and imports the llm-d Grafana dashboard (JSON already scp'd to
# ~/ocp-install/llmd-observability.json by cmd_llmd_monitoring).
#
# Metric names verified live on RHOAI 3.5.1 (KServe LLMInferenceService): vLLM
# metrics carry a "kserve_vllm:" prefix. kserve_http_requests_total (used on the
# 2026-09-07 cluster, docs/test-results-2026-09-07.md) is no longer exported, so
# the alert uses vLLM finished_reason=error|abort, and the dashboard takes
# client-visible throughput/errors from the MaaS Gateway (istio_requests_total).
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE to the LLMInferenceService namespace}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"
TTFT_THRESHOLD_S="${LLMD_TTFT_THRESHOLD_S:-2}"
ERROR_RATE_THRESHOLD="${LLMD_ERROR_RATE_THRESHOLD:-0.05}"

echo "== Verifying auto-generated ServiceMonitor/PodMonitor in $LLMD_NAMESPACE =="
oc get servicemonitor,podmonitor -n "$LLMD_NAMESPACE" 2>&1 || true
if ! oc get podmonitor -n "$LLMD_NAMESPACE" 2>/dev/null | grep -q kserve-llm-isvc-vllm-engine; then
  echo "WARNING: kserve-llm-isvc-vllm-engine PodMonitor not found in $LLMD_NAMESPACE." >&2
  echo "         Is there a Ready LLMInferenceService in this namespace? (oc get llminferenceservice -n $LLMD_NAMESPACE)" >&2
fi

echo "== Applying PrometheusRule (TTFT p95 > ${TTFT_THRESHOLD_S}s, error rate > ${ERROR_RATE_THRESHOLD}) =="
oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: llmd-latency-error-alerts
  namespace: ${LLMD_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: llm-d
spec:
  groups:
    - name: llmd.ttft
      rules:
        - alert: LLMDHighTTFT
          expr: |
            histogram_quantile(0.95, sum(rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="${LLMD_NAMESPACE}"}[5m])) by (le)) > ${TTFT_THRESHOLD_S}
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "llm-d TTFT p95 exceeded ${TTFT_THRESHOLD_S}s in ${LLMD_NAMESPACE}"
            description: "TTFT p95 has been {{ \$value }}s for 5m+."
    - name: llmd.error-rate
      rules:
        # vLLM-side ratio of requests that ended in error/abort. Gateway (client-visible) errors live in
        # openshift-ingress and cannot be queried from a namespaced rule -> see the dashboard's Error Rate panel.
        - alert: LLMDHighErrorRate
          expr: |
            (
              sum(rate(kserve_vllm:request_success_total{namespace="${LLMD_NAMESPACE}",finished_reason=~"error|abort"}[5m]))
              /
              sum(rate(kserve_vllm:request_success_total{namespace="${LLMD_NAMESPACE}"}[5m]))
            ) > ${ERROR_RATE_THRESHOLD}
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "llm-d error rate exceeded ${ERROR_RATE_THRESHOLD} in ${LLMD_NAMESPACE}"
            description: "Error rate has been {{ \$value | humanizePercentage }} for 5m+."
YAML

echo "== Importing Grafana dashboard (llm-d Observability) =="
# The GrafanaDashboard CR's `datasources` input-mapping (by datasource
# *name*) does not actually resolve to Grafana's real (randomly-generated,
# changes every cluster rebuild) datasource UID -- confirmed live
# 2026-09-08: panels stored `"uid": "thanos-querier"` (the name, verbatim)
# instead of the real uid, and Grafana's /api/ds/query 404s on that ("Data
# source not found"). The GrafanaDatasource CR publishes the real,
# currently-live uid at .status.uid, so substitute it into the dashboard
# JSON ourselves instead of relying on the operator's input mapping.
THANOS_DS_UID=$(oc get grafanadatasource thanos-querier -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.uid}')
[ -n "$THANOS_DS_UID" ] || { echo "Could not resolve thanos-querier datasource uid" >&2; exit 1; }
sed "s/\${DS_THANOS}/${THANOS_DS_UID}/g" "$HOME/ocp-install/llmd-observability.json" > "$HOME/ocp-install/llmd-observability.resolved.json"

jq -n --rawfile dash "$HOME/ocp-install/llmd-observability.resolved.json" '
  {
    apiVersion: "grafana.integreatly.org/v1beta1",
    kind: "GrafanaDashboard",
    metadata: { name: "llmd-observability", namespace: env.MONITORING_NAMESPACE },
    spec: {
      instanceSelector: { matchLabels: { dashboards: "gpu-grafana" } },
      json: $dash
    }
  }' | oc apply -f -

echo ""
echo "llm-d monitoring ready for namespace: $LLMD_NAMESPACE"
echo "PrometheusRule: oc get prometheusrule llmd-latency-error-alerts -n $LLMD_NAMESPACE"
echo "Dashboard: pick '$LLMD_NAMESPACE' from the namespace dropdown on the 'llm-d Observability' Grafana dashboard."
