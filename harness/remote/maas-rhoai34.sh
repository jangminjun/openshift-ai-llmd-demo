#!/usr/bin/env bash
# RHOAI 3.3/3.4 path (DSC kserve.modelsAsService). RHOAI 3.5+ uses maas.sh --
# harness.sh maas picks the right one automatically.
# Runs ON the bastion, after rhoai.sh (DataScienceCluster must already be
# Ready). Installs RHCL (Kuadrant: Authorino + Limitador) and enables
# RHOAI's integrated Models-as-a-Service (MaaS) gateway, required for llm-d
# serving. Ported from https://github.com/hyogrin/RHOAI-Toolkit
# (scripts/setup-maas.sh, RHOAI 3.3+ "integrated" path) and adapted to this
# harness's conventions. Idempotent — every step checks before creating.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

echo "== Step 0: cert-manager operator (Authorino TLS depends on it) =="

if oc get crd certificates.cert-manager.io &>/dev/null; then
  echo "cert-manager already installed."
else
  oc get namespace cert-manager-operator &>/dev/null || oc create namespace cert-manager-operator
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for cert-manager CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd certificates.cert-manager.io &>/dev/null && break
    sleep 10
  done
  oc get crd certificates.cert-manager.io &>/dev/null || { echo "Timed out waiting for cert-manager CRDs" >&2; exit 1; }
  echo "Waiting for cert-manager webhook to be ready (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get pods -n cert-manager -l app=webhook 2>/dev/null | grep -q Running && break
    sleep 10
  done
fi

echo "== Step 1: RHCL (Kuadrant) operator =="

oc get namespace kuadrant-system &>/dev/null || oc create namespace kuadrant-system

if oc get csv -n kuadrant-system 2>/dev/null | grep -qi rhcl-operator; then
  echo "RHCL operator already installed."
else
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant-system
  namespace: kuadrant-system
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: kuadrant-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for RHCL operator CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd kuadrants.kuadrant.io &>/dev/null && break
    sleep 10
  done
  oc get crd kuadrants.kuadrant.io &>/dev/null || { echo "Timed out waiting for RHCL CRDs" >&2; exit 1; }
fi

if oc get kuadrant kuadrant -n kuadrant-system &>/dev/null; then
  echo "Kuadrant instance already exists."
else
  oc apply -f - <<'YAML'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
YAML
  echo "Waiting for Authorino service (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get svc/authorino-authorino-authorization -n kuadrant-system &>/dev/null && break
    sleep 10
  done
fi

echo "== Step 2: Authorino TLS =="

if oc get secret authorino-server-cert -n kuadrant-system &>/dev/null; then
  echo "Authorino TLS secret already exists."
else
  # Requires cert-manager (installed as an RHOAI dependency).
  oc apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: authorino-selfsigned
  namespace: kuadrant-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authorino-server-cert
  namespace: kuadrant-system
spec:
  secretName: authorino-server-cert
  isCA: false
  duration: 8760h
  renewBefore: 720h
  issuerRef:
    name: authorino-selfsigned
    kind: Issuer
  commonName: authorino-authorino
  dnsNames:
    - authorino-authorino
    - authorino-authorino.kuadrant-system
    - authorino-authorino.kuadrant-system.svc
    - authorino-authorino.kuadrant-system.svc.cluster.local
  usages:
    - server auth
YAML
  for _ in $(seq 1 10); do
    oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && break
    sleep 3
  done
fi

oc apply -f - <<'YAML'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
YAML

oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite 2>/dev/null || true

echo "== Step 3: Enable modelsAsService in DataScienceCluster =="

current_state=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "")
if [ "$current_state" = "Managed" ]; then
  echo "modelsAsService already Managed."
else
  oc patch datasciencecluster default-dsc --type=merge -p '{
    "spec": {"components": {"kserve": {"modelsAsService": {"managementState": "Managed"}}}}
  }'
  echo "Waiting 30s for DataScienceCluster to reconcile..."
  sleep 30
fi

echo "== Step 4: Inference GatewayClass/Gateway =="
# RHOAI's own controller may already create a MaaS gateway once
# modelsAsService is Managed (observed as maas-default-gateway on some
# versions) — these are additive and only created if missing.

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

oc get gatewayclass openshift-ai-inference &>/dev/null || oc apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-ai-inference
spec:
  controllerName: openshift.io/gateway-controller/v1
YAML

if oc get gateway openshift-ai-inference -n openshift-ingress &>/dev/null; then
  echo "Gateway openshift-ai-inference already exists."
else
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/rev: openshift-gateway
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: inference-gateway.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: default-gateway-tls
        mode: Terminate
YAML
fi

echo "== Step 5: Dashboard MaaS features =="
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {"dashboardConfig": {"disableModelRegistry": false, "disableModelCatalog": false,
  "disableKServeMetrics": false, "genAiStudio": true, "modelAsService": true, "disableLMEval": false}}
}' 2>/dev/null || echo "Could not patch odhdashboardconfig (may not exist yet) - continuing."

echo "== Step 6: Restart controllers to pick up the new config =="
oc delete pod -n redhat-ods-applications -l app=odh-model-controller --ignore-not-found=true
oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager --ignore-not-found=true
sleep 10

echo ""
echo "MaaS setup complete."
echo "MaaS endpoint (once a model with MaaS enabled is deployed): https://maas.${CLUSTER_DOMAIN}"
echo "Inference gateway:  https://inference-gateway.${CLUSTER_DOMAIN}"
echo "Verify: oc get tenants.maas.opendatahub.io -A ; oc get gateway -A"
