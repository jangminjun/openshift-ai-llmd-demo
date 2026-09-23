#!/usr/bin/env bash
# Installs distributed tracing (Tempo) for llm-d request tracing: Cluster
# Observability Operator (COO, ships TempoStack support) + Red Hat build of
# OpenTelemetry (RHBO) + Tempo Operator, then a TempoStack backed by the
# same in-cluster MinIO openshift-logging.sh already deployed (adds a
# second bucket to it rather than standing up a separate object store).
# Runs ON the bastion. Idempotent.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin123}"
TRACING_NAMESPACE="${TRACING_NAMESPACE:-openshift-tempo}"
TEMPO_BUCKET="${TEMPO_BUCKET:-tempo-traces}"

# Reuse the MinIO openshift-logging.sh deploys when present; otherwise stand
# up a minimal single-replica MinIO here so this harness stays self-contained.
if ! oc get deployment minio -n "$MINIO_NAMESPACE" &>/dev/null; then
  echo "=== MinIO not found in $MINIO_NAMESPACE -- deploying a minimal instance ==="
  oc get namespace "$MINIO_NAMESPACE" &>/dev/null || oc create namespace "$MINIO_NAMESPACE"
  oc apply -n "$MINIO_NAMESPACE" -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 20Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: minio}}
  template:
    metadata: {labels: {app: minio}}
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - {name: MINIO_ROOT_USER, value: "${MINIO_ACCESS_KEY}"}
        - {name: MINIO_ROOT_PASSWORD, value: "${MINIO_SECRET_KEY}"}
        ports: [{containerPort: 9000}, {containerPort: 9001}]
        volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: minio-data}}]
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector: {app: minio}
  ports: [{name: api, port: 9000, targetPort: 9000}]
YAML
  oc rollout status deployment/minio -n "$MINIO_NAMESPACE" --timeout=300s
fi

echo "=== Ensuring a $TEMPO_BUCKET bucket exists in MinIO ==="
# MINIO_DEFAULT_BUCKETS only creates buckets on a truly empty data
# directory -- on a PVC that already has data (e.g. loki-logs from
# openshift-logging.sh already ran), restarting MinIO with an updated
# MINIO_DEFAULT_BUCKETS does NOT retroactively create the new bucket, even
# though the env var is set correctly and the pod restarts cleanly. Hit
# this live 2026-09-08: Tempo's ingester/compactor/querier/query-frontend
# all crash-looped with "ListObjects on tempo-traces: The specified bucket
# does not exist" despite the env var being right. Fix: create the bucket
# for real via `mc`, don't just set the env var and hope.
current_buckets=$(oc get deployment minio -n "$MINIO_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_DEFAULT_BUCKETS")].value}' 2>/dev/null || echo "")
case ",${current_buckets}," in
  *",${TEMPO_BUCKET},"*) : ;;
  *)
    new_buckets="${current_buckets:+${current_buckets},}${TEMPO_BUCKET}"
    oc set env deployment/minio -n "$MINIO_NAMESPACE" "MINIO_DEFAULT_BUCKETS=${new_buckets}"
    oc rollout status deployment/minio -n "$MINIO_NAMESPACE" --timeout=120s
    ;;
esac

oc delete pod mc-bucket-ensure -n "$MINIO_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
oc run mc-bucket-ensure --image=quay.io/minio/mc:latest -n "$MINIO_NAMESPACE" --restart=Never \
  --env="HOME=/tmp" --command -- sh -c \
  "mc alias set myminio http://minio.${MINIO_NAMESPACE}.svc:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} && mc mb -p myminio/${TEMPO_BUCKET}" \
  >/dev/null
for _ in $(seq 1 12); do
  phase=$(oc get pod mc-bucket-ensure -n "$MINIO_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 5
done
oc logs mc-bucket-ensure -n "$MINIO_NAMESPACE" 2>&1 || true
oc delete pod mc-bucket-ensure -n "$MINIO_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
echo "Bucket $TEMPO_BUCKET confirmed."

echo "=== Cluster Observability Operator + Red Hat build of OpenTelemetry + Tempo Operator ==="
oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for Tempo + OpenTelemetry CRDs (up to 5m)..."
for _ in $(seq 1 30); do
  oc get crd tempostacks.tempo.grafana.com &>/dev/null && \
  oc get crd opentelemetrycollectors.opentelemetry.io &>/dev/null && break
  sleep 10
done
oc get crd tempostacks.tempo.grafana.com &>/dev/null || { echo "Timed out waiting for Tempo CRDs" >&2; exit 1; }

echo "=== TempoStack (backed by MinIO/$TEMPO_BUCKET) ==="
oc get namespace "$TRACING_NAMESPACE" &>/dev/null || oc create namespace "$TRACING_NAMESPACE"

oc create secret generic tempo-minio -n "$TRACING_NAMESPACE" \
  --from-literal=bucket="$TEMPO_BUCKET" \
  --from-literal=endpoint="http://minio.${MINIO_NAMESPACE}.svc:9000" \
  --from-literal=access_key_id="$MINIO_ACCESS_KEY" \
  --from-literal=access_key_secret="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: llmd-tracing
  namespace: ${TRACING_NAMESPACE}
spec:
  storage:
    secret:
      name: tempo-minio
      type: s3
  storageSize: 10Gi
  resources:
    total:
      limits:
        memory: 2Gi
        cpu: "1"
  template:
    queryFrontend:
      jaegerQuery:
        enabled: true
        # Operator-managed Route. A manual `oc expose` route gets pruned by the
        # Tempo operator (observed 2026-09-23: route vanished within ~1h).
        ingress:
          type: route
          route:
            termination: edge
YAML

echo "Waiting for TempoStack pods..."
for _ in $(seq 1 30); do
  oc get pods -n "$TRACING_NAMESPACE" -l app.kubernetes.io/component=query-frontend 2>/dev/null | grep -q Running && break
  sleep 10
done

echo "=== Jaeger UI route (operator-managed) ==="
for _ in $(seq 1 30); do
  oc get route tempo-llmd-tracing-query-frontend -n "$TRACING_NAMESPACE" &>/dev/null && break
  sleep 5
done
JAEGER_HOST=$(oc get route tempo-llmd-tracing-query-frontend -n "$TRACING_NAMESPACE" -o jsonpath='{.spec.host}')

echo ""
echo "Tracing stack ready. OTLP gRPC ingest (for vLLM --otlp-traces-endpoint):"
echo "  tempo-llmd-tracing-distributor.${TRACING_NAMESPACE}.svc:4317"
echo "Jaeger UI: https://${JAEGER_HOST}"
