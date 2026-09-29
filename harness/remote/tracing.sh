#!/usr/bin/env bash
# Installs distributed tracing for llm-d: Red Hat build of OpenTelemetry (RHBO) + Tempo
# Operator, a multi-tenant TempoMonolithic (PV storage, mode openshift) and an OTel Collector
# that authenticates to the Tempo gateway, plus the console Observe > Traces UI (COO UIPlugin).
#   vLLM/EPP --OTLP--> <OTEL_NAME>-collector:4317 --bearer token + X-Scope-OrgID--> Tempo gateway
# The console plugin lists multi-tenant Tempo instances only, and a multi-tenant Tempo only
# accepts authenticated writes -> the collector adds the ServiceAccount token.
# No object store: the public MinIO images are no longer pullable. Idempotent.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

TRACING_NAMESPACE="${TRACING_NAMESPACE:-openshift-tempo}"
TEMPO_NAME="${TEMPO_NAME:-llmd-tracing}"
TEMPO_STORAGE_SIZE="${TEMPO_STORAGE_SIZE:-10Gi}"
TEMPO_TENANT="${TEMPO_TENANT:-llmd}"
OTEL_NAME="${OTEL_NAME:-llmd-otel}"

echo "=== Red Hat build of OpenTelemetry + Tempo Operator ==="
# Skip when the operator is already installed (e.g. by RHOAI) -- a second
# Subscription for the same package breaks OLM resolution.
for pkg in tempo-product opentelemetry-product; do
  if oc get subscriptions.operators.coreos.com -A -o jsonpath='{.items[*].spec.name}' | tr ' ' '\n' | grep -qx "$pkg"; then
    echo "$pkg already subscribed."
    continue
  fi
  oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: ${pkg}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
done

echo "Waiting for Tempo + OpenTelemetry CRDs (up to 5m)..."
for _ in $(seq 1 30); do
  oc get crd tempomonolithics.tempo.grafana.com &>/dev/null && \
  oc get crd opentelemetrycollectors.opentelemetry.io &>/dev/null && break
  sleep 10
done
oc get crd tempomonolithics.tempo.grafana.com &>/dev/null || { echo "Timed out waiting for Tempo CRDs" >&2; exit 1; }

echo "=== TempoMonolithic $TEMPO_NAME (PV $TEMPO_STORAGE_SIZE, tenant $TEMPO_TENANT) ==="
oc get namespace "$TRACING_NAMESPACE" &>/dev/null || oc create namespace "$TRACING_NAMESPACE"
oc apply -f - <<YAML
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoMonolithic
metadata:
  name: ${TEMPO_NAME}
  namespace: ${TRACING_NAMESPACE}
spec:
  storage:
    traces:
      backend: pv
      size: ${TEMPO_STORAGE_SIZE}
  resources:
    limits:
      memory: 2Gi
      cpu: "1"
  multitenancy:
    enabled: true
    mode: openshift
    authentication:
    - tenantName: ${TEMPO_TENANT}
      tenantId: ${TEMPO_TENANT}
YAML

echo "Waiting for TempoMonolithic Ready (up to 5m)..."
for _ in $(seq 1 30); do
  [ "$(oc get tempomonolithic "$TEMPO_NAME" -n "$TRACING_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 10
done
oc get tempomonolithic "$TEMPO_NAME" -n "$TRACING_NAMESPACE"

echo "=== OTel Collector $OTEL_NAME -> Tempo gateway (tenant $TEMPO_TENANT) ==="
oc apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${TEMPO_NAME}-traces-write
rules:
- apiGroups: [tempo.grafana.com]
  resources: [${TEMPO_TENANT}]
  resourceNames: [traces]
  verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${TEMPO_NAME}-traces-write
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${TEMPO_NAME}-traces-write}
subjects:
- {kind: ServiceAccount, name: ${OTEL_NAME}-collector, namespace: ${TRACING_NAMESPACE}}
---
# read access for the harness (tempo_services / tempo_trace); console users need the same 'get'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${TEMPO_NAME}-traces-read
rules:
- apiGroups: [tempo.grafana.com]
  resources: [${TEMPO_TENANT}]
  resourceNames: [traces]
  verbs: [get]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${TEMPO_NAME}-reader
  namespace: ${TRACING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${TEMPO_NAME}-traces-read
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${TEMPO_NAME}-traces-read}
subjects:
- {kind: ServiceAccount, name: ${TEMPO_NAME}-reader, namespace: ${TRACING_NAMESPACE}}
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: ${OTEL_NAME}
  namespace: ${TRACING_NAMESPACE}
spec:
  mode: deployment
  config:
    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token
    receivers:
      otlp:
        protocols:
          grpc: {endpoint: 0.0.0.0:4317}
          http: {endpoint: 0.0.0.0:4318}
    processors:
      memory_limiter: {check_interval: 1s, limit_percentage: 75, spike_limit_percentage: 15}
      batch: {}
    exporters:
      otlp/tempo:
        endpoint: tempo-${TEMPO_NAME}-gateway.${TRACING_NAMESPACE}.svc.cluster.local:4317
        auth: {authenticator: bearertokenauth}
        headers: {X-Scope-OrgID: ${TEMPO_TENANT}}
        tls: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt}
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces: {receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp/tempo]}
YAML
oc rollout status "deploy/${OTEL_NAME}-collector" -n "$TRACING_NAMESPACE" --timeout=300s

echo "=== OpenShift console Observe > Traces (COO UIPlugin) ==="
if oc get crd uiplugins.observability.openshift.io &>/dev/null; then
  oc apply -f - <<'YAML'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing
spec:
  type: DistributedTracing
YAML
else
  echo "Cluster Observability Operator not installed -- skipping the console trace UI."
fi

echo ""
echo "Tracing stack ready. OTLP gRPC ingest (spec.tracing exporterEndpoint):"
echo "  http://${OTEL_NAME}-collector.${TRACING_NAMESPACE}.svc.cluster.local:4317"
echo "Traces UI: OpenShift console > Observe > Traces (${TRACING_NAMESPACE}/${TEMPO_NAME}, tenant ${TEMPO_TENANT})"
