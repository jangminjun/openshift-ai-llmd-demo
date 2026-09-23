#!/usr/bin/env bash
# Runs tools/loadgen.py as an in-cluster Job (ServiceAccount token auth) and
# prints its SUMMARY line. loadgen.py must already be at ~/ocp-install/loadgen.py
# (cmd_llmd_loadgen copies it). Target: URL/MODEL, or derived from
# LLMD_NAMESPACE/LLMD_NAME (MaaS gateway path + .spec.model.name).
# LOADGEN_WAIT=false starts the Job and returns (for concurrent traffic classes).
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

NS="${LOADGEN_NAMESPACE:-llmd-bench}"
NAME="${LOADGEN_NAME:-loadgen}"
WAIT="${LOADGEN_WAIT:-true}"
IMAGE="${LOADGEN_IMAGE:-registry.access.redhat.com/ubi9/python-311:latest}"

if [ -z "${URL:-}" ]; then
  : "${LLMD_NAMESPACE:?set URL or LLMD_NAMESPACE/LLMD_NAME}" "${LLMD_NAME:?set LLMD_NAME}"
  base=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.url}')
  URL="${base}/v1/chat/completions"
fi
[ -n "${MODEL:-}" ] || MODEL=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')

oc get namespace "$NS" &>/dev/null || oc create namespace "$NS"
oc get sa loadgen -n "$NS" &>/dev/null || oc create sa loadgen -n "$NS"
oc create configmap loadgen-script -n "$NS" --from-file=loadgen.py="$HOME/ocp-install/loadgen.py" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

args=(--from-literal=URL="$URL" --from-literal=MODEL="$MODEL")
for v in CONCURRENCY REQUESTS DURATION INTERVAL MAX_TOKENS PROMPT_MODE PREFIX_TOKENS DOCS DOC_OFFSET IMAGE_URLS HEADERS LABEL TIMEOUT TIMELINE; do
  [ -n "${!v:-}" ] && args+=(--from-literal="$v=${!v}")
done
oc create configmap "${NAME}-env" -n "$NS" "${args[@]}" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc delete job "$NAME" -n "$NS" --ignore-not-found --wait=true >/dev/null
oc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 7200
  template:
    spec:
      serviceAccountName: loadgen
      restartPolicy: Never
      containers:
      - name: loadgen
        image: ${IMAGE}
        command: ["python3", "-u", "/app/loadgen.py"]
        envFrom: [{configMapRef: {name: ${NAME}-env}}]
        # MaaS API key from 'harness.sh maas-api-key' if present; else the SA token is used.
        env: [{name: TOKEN, valueFrom: {secretKeyRef: {name: loadgen-token, key: token, optional: true}}}]
        resources: {requests: {cpu: 500m, memory: 256Mi}}
        volumeMounts: [{name: script, mountPath: /app}]
      volumes: [{name: script, configMap: {name: loadgen-script}}]
YAML
echo "loadgen job $NS/$NAME -> $URL (model=$MODEL)"
[ "$WAIT" = "true" ] || exit 0

for _ in $(seq 1 720); do
  s=$(oc get job "$NAME" -n "$NS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null || true)
  [ -n "$s" ] && break
  sleep 5
done
oc logs "job/$NAME" -n "$NS" | grep '^SUMMARY' || { oc logs "job/$NAME" -n "$NS" | tail -20; exit 1; }
