#!/usr/bin/env bash
# Checks and prepares everything llm-d scenarios need on top of a base
# OpenShift + GPU + RHOAI cluster. Idempotent. Safe to re-run.
#   1. RHOAI: DataScienceCluster Ready, LLMInferenceService CRD present   (check only)
#   2. Gateway for LLMInferenceService routing in openshift-ingress         (check only -> `harness.sh maas`)
#   3. hf:// ClusterStorageContainer                                         (check only -> created by llmd-deploy-model)
#   4. User Workload Monitoring (scrapes the auto-generated PodMonitor/ServiceMonitor)  (prepare)
#   5. Grafana Operator + instance + Thanos datasource in MONITORING_NAMESPACE           (prepare)
#      GRAFANA_ADMIN_PASSWORD=<pw> sets a fixed admin password (default: operator-generated)
#   6. Free GPU count                                                        (report)
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"
GRAFANA_NAME="${GRAFANA_NAME:-gpu-grafana}"
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

echo "== 1. RHOAI / llm-d CRD =="
[ "$(oc get datasciencecluster -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && ok "DataScienceCluster Ready" || bad "DataScienceCluster not Ready (oc get datasciencecluster)"
oc get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1 \
  && ok "LLMInferenceService CRD present" || bad "LLMInferenceService CRD missing (RHOAI 3.5+ with kserve Managed required)"

echo "== 2. Gateway =="
GW=$(oc get gateway -n openshift-ingress -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
[ -n "$GW" ] && ok "Gateway(s): $GW" || bad "No Gateway in openshift-ingress -> run: ./harness.sh maas"

echo "== 3. hf:// storage =="
oc get clusterstoragecontainer hf-hub >/dev/null 2>&1 \
  && ok "ClusterStorageContainer hf-hub present" || warn "hf-hub missing (created automatically by llmd-deploy-model)"

echo "== 4. User Workload Monitoring =="
CMO_CFG=$(oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
if echo "$CMO_CFG" | grep -q 'enableUserWorkload: *true'; then
  ok "enableUserWorkload: true"
elif [ -z "$CMO_CFG" ]; then
  echo "  creating cluster-monitoring-config (enableUserWorkload: true)"
  oc apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    alertmanagerMain:
      enableUserAlertmanagerConfig: true
YAML
else
  # Existing config with other settings: do not overwrite it.
  bad "cluster-monitoring-config exists without enableUserWorkload: true -- add it manually:
         oc edit cm cluster-monitoring-config -n openshift-monitoring"
fi
# Capture first: `oc ... | grep -q` under pipefail fails when grep exits early (SIGPIPE to oc).
for _ in $(seq 1 30); do
  UWM_PODS=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus 2>/dev/null || true)
  grep -q Running <<< "$UWM_PODS" && break
  sleep 10
done
grep -q Running <<< "$UWM_PODS" \
  && ok "UWM Prometheus Running" || bad "UWM Prometheus not Running (oc get pods -n openshift-user-workload-monitoring)"

echo "== 5. Grafana ($MONITORING_NAMESPACE) =="
oc get namespace "$MONITORING_NAMESPACE" >/dev/null 2>&1 || oc create namespace "$MONITORING_NAMESPACE"
if ! oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1; then
  echo "  installing Grafana Operator (community-operators, channel v5)"
  oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${MONITORING_NAMESPACE}
  namespace: ${MONITORING_NAMESPACE}
spec:
  targetNamespaces:
  - ${MONITORING_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: ${MONITORING_NAMESPACE}
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML
  for _ in $(seq 1 40); do
    oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1 && break
    sleep 15
  done
fi
oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1 || { bad "Grafana CRD not registered"; exit 1; }

oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-thanos-reader
  namespace: ${MONITORING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-thanos-reader-binding
subjects:
- kind: ServiceAccount
  name: grafana-thanos-reader
  namespace: ${MONITORING_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${GRAFANA_NAME}-data
  namespace: ${MONITORING_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: ${GRAFANA_NAME}
  namespace: ${MONITORING_NAMESPACE}
  labels:
    dashboards: "${GRAFANA_NAME}"
spec:
  config:
    security:
      admin_user: admin
  route:
    spec:
      tls:
        termination: edge
  deployment:
    spec:
      template:
        spec:
          volumes:
          - name: grafana-data
            persistentVolumeClaim:
              claimName: ${GRAFANA_NAME}-data
YAML

# Optional fixed admin password. The operator logs in with the password in its own
# <name>-admin-credentials Secret, so change it there (an env override breaks the operator's
# login), then reset the value Grafana already stored on its PVC.
if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  for _ in $(seq 1 30); do
    oc get secret "${GRAFANA_NAME}-admin-credentials" -n "$MONITORING_NAMESPACE" &>/dev/null && break
    sleep 5
  done
  oc patch secret "${GRAFANA_NAME}-admin-credentials" -n "$MONITORING_NAMESPACE" --type=merge \
    -p "{\"stringData\":{\"GF_SECURITY_ADMIN_PASSWORD\":\"${GRAFANA_ADMIN_PASSWORD}\"}}" >/dev/null
  oc rollout restart "deploy/${GRAFANA_NAME}-deployment" -n "$MONITORING_NAMESPACE" >/dev/null
  oc rollout status "deploy/${GRAFANA_NAME}-deployment" -n "$MONITORING_NAMESPACE" --timeout=300s >/dev/null
  oc exec -n "$MONITORING_NAMESPACE" "deploy/${GRAFANA_NAME}-deployment" -c grafana -- \
    grafana cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null
  ok "Grafana admin password set (GRAFANA_ADMIN_PASSWORD)"
fi

# Token is inlined into secureJsonData: valuesFrom into secureJsonData
# silently resolves empty on grafana-operator v5 (every query 401s).
if ! oc get grafanadatasource thanos-querier -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
  TOKEN=$(oc create token grafana-thanos-reader -n "$MONITORING_NAMESPACE" --duration=87600h)
  oc apply -f - <<YAML
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: thanos-querier
  namespace: ${MONITORING_NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: "${GRAFANA_NAME}"
  datasource:
    name: thanos-querier
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      timeInterval: 30s
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer ${TOKEN}"
YAML
fi

for _ in $(seq 1 40); do
  [ -n "$(oc get grafanadatasource thanos-querier -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.uid}' 2>/dev/null)" ] && break
  sleep 10
done
[ -n "$(oc get grafanadatasource thanos-querier -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.uid}' 2>/dev/null)" ] \
  && ok "Grafana datasource thanos-querier synced" || bad "GrafanaDatasource thanos-querier has no .status.uid yet"
ROUTE=$(oc get route "${GRAFANA_NAME}-route" -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$ROUTE" ] && ok "Grafana: https://${ROUTE}" || warn "Grafana route not created yet"

echo "== 6. GPU capacity =="
TOTAL=0; USED=0
for n in $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}'); do
  a=$(oc get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  u=$(oc get pods -A --field-selector "spec.nodeName=$n,status.phase=Running" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.nvidia\.com/gpu}{"\n"}{end}{end}' \
      | awk '{s+=$1} END{print s+0}')
  TOTAL=$((TOTAL + ${a:-0})); USED=$((USED + u))
done
FREE=$((TOTAL - USED))
[ "$FREE" -gt 0 ] && ok "GPU free: $FREE / $TOTAL" \
  || warn "GPU free: 0 / $TOTAL -- new LLMInferenceService will stay Pending. Scale out:
         oc scale machineset <gpu-machineset> -n openshift-machine-api --replicas=N"

echo
[ "$FAIL" -eq 0 ] && echo "llm-d prerequisites: READY" || { echo "llm-d prerequisites: NOT READY (see [FAIL] above)"; exit 1; }
