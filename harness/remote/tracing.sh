#!/usr/bin/env bash
# Installs distributed tracing (Tempo) for llm-d request tracing: Red Hat build
# of OpenTelemetry (RHBO) + Tempo Operator, then a TempoMonolithic with PV
# storage and the Jaeger UI. No object store: the public MinIO images
# (quay.io/minio/minio, docker.io/minio/minio) are no longer pullable.
# Idempotent.
#   OTLP gRPC ingest: tempo-<TEMPO_NAME>.<TRACING_NAMESPACE>.svc:4317
#   Jaeger query API: svc/tempo-<TEMPO_NAME>-jaegerui:16686 (port-forward)
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

TRACING_NAMESPACE="${TRACING_NAMESPACE:-openshift-tempo}"
TEMPO_NAME="${TEMPO_NAME:-llmd-tracing}"
TEMPO_STORAGE_SIZE="${TEMPO_STORAGE_SIZE:-10Gi}"

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

echo "=== TempoMonolithic $TEMPO_NAME (PV $TEMPO_STORAGE_SIZE) ==="
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
  jaegerui:
    enabled: true
    # Operator-managed Route. A manual `oc expose` route gets pruned by the
    # Tempo operator (observed 2026-09-23: route vanished within ~1h).
    route:
      enabled: true
      termination: edge
YAML

echo "Waiting for TempoMonolithic Ready (up to 5m)..."
for _ in $(seq 1 30); do
  [ "$(oc get tempomonolithic "$TEMPO_NAME" -n "$TRACING_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 10
done
oc get tempomonolithic "$TEMPO_NAME" -n "$TRACING_NAMESPACE"

JAEGER_HOST=$(oc get route "tempo-${TEMPO_NAME}-jaegerui" -n "$TRACING_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo ""
echo "Tracing stack ready. OTLP gRPC ingest (for vLLM --otlp-traces-endpoint):"
echo "  tempo-${TEMPO_NAME}.${TRACING_NAMESPACE}.svc:4317"
echo "Jaeger UI: https://${JAEGER_HOST:-<route pending>}"
