#!/usr/bin/env bash
# RHOAI 3.5+ MaaS (Models-as-a-Service) setup: RHCL (Kuadrant: Authorino +
# Limitador), DSC aigateway.modelsAsAService, inference/MaaS Gateways and the
# Postgres DB maas-api needs. Idempotent -- every step checks before creating;
# controllers are only restarted when the DSC was actually changed.
# RHOAI 3.5+ only; the 3.3/3.4 path (DSC kserve.modelsAsService) is no longer kept.
#
# RHOAI 3.5 differences from the 3.4 path (verified on 3.5.1):
#   - MaaS lives at spec.components.aigateway.modelsAsAService (not kserve.*).
#   - Authorino listener TLS must be ON: odh-model-controller generates a
#     <gateway>-authn-ssl EnvoyFilter that dials Authorino over TLS. The
#     service-CA serving cert is enough -- no cert-manager Issuer/Certificate.
#   - AITenant expects a Gateway named exactly "maas-default-gateway".
#   - Gateways use the cluster's router-certs-default (the placeholder
#     "default-gateway-tls" secret is never created).
#   - maas-api needs a Postgres DB (maas-db-config secret) nothing else provisions.
#   - maas-default-gateway needs opendatahub.io/managed=false BEFORE any model
#     is deployed to it, or odh-model-controller takes over its AuthPolicy.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

MAAS_INFRA_NS="${MAAS_INFRA_NS:-redhat-ai-gateway-infra}"
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
DSC_CHANGED=false

echo "== Step 1: RHCL (Kuadrant: Authorino + Limitador) operator =="
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

echo "== Step 2: Authorino instance (listener TLS on, service-CA cert) =="
# odh-model-controller's <gateway>-authn-ssl EnvoyFilter dials Authorino over TLS
# (trusting service-ca.crt); a plaintext listener makes every authenticated call 500.
oc annotate svc authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
for _ in $(seq 1 12); do
  oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && break
  sleep 5
done
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

echo "== Step 3: DSC aigateway.modelsAsAService =="
current_state=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || echo "")
if [ "$current_state" = "Managed" ]; then
  echo "aigateway.modelsAsAService already Managed."
else
  oc patch datasciencecluster default-dsc --type=merge -p '{
    "spec": {"components": {"aigateway": {
      "managementState": "Managed",
      "modelsAsAService": {"managementState": "Managed"}
    }}}
  }'
  DSC_CHANGED=true
  echo "Waiting 30s for DataScienceCluster to reconcile..."
  sleep 30
fi

echo "== Step 4: GatewayClass + Gateways (openshift-ai-inference, maas-default-gateway) =="
oc get gatewayclass openshift-ai-inference &>/dev/null || oc apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-ai-inference
spec:
  controllerName: openshift.io/gateway-controller/v1
YAML

create_gateway() {  # <name> <hostname prefix>
  if oc get gateway "$1" -n openshift-ingress &>/dev/null; then
    echo "Gateway $1 already exists."
    return
  fi
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: $1
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: $2.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: router-certs-default
        mode: Terminate
YAML
}
create_gateway openshift-ai-inference inference-gateway
create_gateway maas-default-gateway maas

oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed="false" \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite

echo "== Step 5: Postgres DB for maas-api =="
if oc get secret maas-db-config -n "$MAAS_INFRA_NS" &>/dev/null; then
  echo "maas-db-config secret already exists."
else
  oc get namespace "$MAAS_INFRA_NS" &>/dev/null || oc create namespace "$MAAS_INFRA_NS"
  DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  oc create secret generic maas-postgres-creds -n "$MAAS_INFRA_NS" \
    --from-literal=username=maasapi --from-literal=password="$DB_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
  oc apply -n "$MAAS_INFRA_NS" -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: maas-db
spec:
  selector: {app: maas-db}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maas-db
spec:
  replicas: 1
  selector: {matchLabels: {app: maas-db}}
  template:
    metadata: {labels: {app: maas-db}}
    spec:
      containers:
      - name: postgres
        image: registry.redhat.io/rhel9/postgresql-15:latest
        ports: [{containerPort: 5432}]
        env:
        - {name: POSTGRESQL_USER, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: username}}}
        - {name: POSTGRESQL_PASSWORD, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: password}}}
        - {name: POSTGRESQL_DATABASE, value: maasdb}
        volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, emptyDir: {}}]
YAML
  echo "Waiting for maas-db (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get pods -n "$MAAS_INFRA_NS" -l app=maas-db 2>/dev/null | grep -q "1/1.*Running" && break
    sleep 10
  done
  DB_USER=$(oc get secret maas-postgres-creds -n "$MAAS_INFRA_NS" -o jsonpath='{.data.username}' | base64 -d)
  DB_PASS=$(oc get secret maas-postgres-creds -n "$MAAS_INFRA_NS" -o jsonpath='{.data.password}' | base64 -d)
  oc create secret generic maas-db-config -n "$MAAS_INFRA_NS" \
    --from-literal=DB_CONNECTION_URL="postgresql://${DB_USER}:${DB_PASS}@maas-db.${MAAS_INFRA_NS}.svc:5432/maasdb" \
    --dry-run=client -o yaml | oc apply -f -
fi

echo "== Step 6: Dashboard MaaS feature flags =="
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {"dashboardConfig": {"disableModelRegistry": false, "disableModelCatalog": false,
  "disableKServeMetrics": false, "genAiStudio": true, "modelAsService": true, "disableLMEval": false}}
}' 2>/dev/null || echo "Could not patch odhdashboardconfig (may not exist yet) -- continuing."

if [ "$DSC_CHANGED" = true ]; then
  echo "== Step 7: Restart controllers to pick up the new DSC config =="
  oc delete pod -n redhat-ods-applications -l app=odh-model-controller --ignore-not-found=true
  oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager --ignore-not-found=true
fi

echo "== Verify =="
for _ in $(seq 1 18); do
  [ "$(oc get aitenant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 10
done
oc get aitenant -A
oc get pods -n "$MAAS_INFRA_NS" --no-headers 2>/dev/null | grep -E 'maas-(api|db)' | grep -v Completed || true
oc get gateway -n openshift-ingress

echo ""
echo "MaaS endpoint:     https://maas.${CLUSTER_DOMAIN}"
echo "Inference gateway: https://inference-gateway.${CLUSTER_DOMAIN}"
echo "Next: register a model for MaaS access (MaaSModelRef + MaaSSubscription + MaaSAuthPolicy)."
