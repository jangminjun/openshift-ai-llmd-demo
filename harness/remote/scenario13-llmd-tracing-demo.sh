#!/usr/bin/env bash
# Scenario 13: llm-d request tracing. Sends a few requests to a model that
# was ALREADY deployed with vLLM's OTLP tracing enabled (cmd_scenario13 in
# harness.sh runs `llmd-deploy-model` with LLMD_EXTRA_VLLM_ARGS set to
# --otlp-traces-endpoint before calling this script), then prints how to
# find the resulting trace -- showing where time was actually spent
# (queue/prefill/decode) for one specific request, not just an aggregate
# metric. Runs ON the bastion. Requires `harness.sh tracing` to have run
# first (this only sends traffic; it does not deploy the model).
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true

LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario13}"
LLMD_NAME="${LLMD_NAME:-llmd-tracing-demo}"
TRACING_NAMESPACE="${TRACING_NAMESPACE:-openshift-tempo}"

if ! oc get tempomonolithic llmd-tracing -n "$TRACING_NAMESPACE" &>/dev/null; then
  echo "TempoMonolithic not found in $TRACING_NAMESPACE -- run 'harness.sh tracing' first." >&2
  exit 1
fi
if ! oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" &>/dev/null; then
  echo "LLMInferenceService $LLMD_NAME not found in $LLMD_NAMESPACE -- run 'harness.sh scenario13-llmd-tracing-demo' (not this script directly)." >&2
  exit 1
fi

SVC="${LLMD_NAME}-kserve-workload-svc.${LLMD_NAMESPACE}.svc.cluster.local:8000"
MODEL_NAME=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')
echo "=== Sending 5 sample requests to generate traces ==="
oc delete pod llmd-tracing-client -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: llmd-tracing-client
  namespace: ${LLMD_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: client
    image: curlimages/curl:latest
    command: ["sh", "-c"]
    args:
    - |
      for i in 1 2 3 4 5; do
        curl -sk -X POST "https://${SVC}/v1/chat/completions" \
          -H "Content-Type: application/json" \
          -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Explain distributed tracing in one sentence."}],"max_tokens":60}'
        echo
        sleep 2
      done
YAML
oc wait --for=condition=Ready=false pod/llmd-tracing-client -n "$LLMD_NAMESPACE" --timeout=60s 2>/dev/null || true
sleep 10

echo ""
echo "=== Traces should now be in Tempo. To view: ==="
echo "oc port-forward -n $TRACING_NAMESPACE svc/tempo-llmd-tracing-jaegerui 16686:16686"
echo "then open http://localhost:16686 and search for service=$LLMD_NAME"
echo ""
echo "Or, with the port-forward running, query the Jaeger API for recent traces:"
echo "  curl -s 'http://localhost:16686/api/traces?service=${LLMD_NAME}&limit=5'"

oc delete pod llmd-tracing-client -n "$LLMD_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
