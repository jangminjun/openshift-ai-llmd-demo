# Scenario 26: 1) Full HTTPS (default) vs 2) Only Envoy HTTPS. The internal hops (Envoy->EPP,
# Envoy->vLLM, EPP->vLLM metrics) switch TLS via DSC spec.components.kserve.
# enableLLMInferenceServiceTLS (cluster-wide -> every LLMInferenceService restarts).
# Measures the same streaming load in both states and restores the original setting.
# Prepended with lib/bench.sh.
#   S26_RUNS (2) S26_DURATION (120) S26_CONCURRENCY (16)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
RUNS="${S26_RUNS:-2}"
W=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N" CONCURRENCY="${S26_CONCURRENCY:-16}" DURATION="${S26_DURATION:-120}" MAX_TOKENS=128)
require_free_gpu
ORIG=$(oc get dsc default-dsc -o jsonpath='{.spec.components.kserve.enableLLMInferenceServiceTLS}')
state() { echo "  vLLM ssl args: [$(oc get deploy "${N}-kserve" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -oE 'ssl-[a-z]+' | sort -u | tr '\n' ' ')]  probe=$(oc get deploy "${N}-kserve" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.scheme}')  EPP $(oc get deploy "${N}-kserve-router-scheduler" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -oE 'secure-serving=[a-z]+' | head -1)"; }
measure() { for i in $(seq 1 "$RUNS"); do brief "$(loadgen s26 "${W[@]}" LABEL="$1-$i")"; done; }
switch() {  # true|false
  local want=$1
  if [ "$want" = true ] && [ -z "$ORIG" ]; then
    oc patch dsc default-dsc --type=json -p '[{"op":"remove","path":"/spec/components/kserve/enableLLMInferenceServiceTLS"}]' >/dev/null
  else
    oc patch dsc default-dsc --type=merge -p "{\"spec\":{\"components\":{\"kserve\":{\"enableLLMInferenceServiceTLS\":$want}}}}" >/dev/null
  fi
  until oc get cm inferenceservice-config -n redhat-ods-applications -o jsonpath='{.data.ingress}' | grep -q "\"enableLLMInferenceServiceTLS\": $want"; do sleep 5; done
  # an explicit inline EPP config pins metrics-data-source scheme -> follow the TLS state
  if oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}' | grep -q metrics-data-source; then
    local s=https; [ "$want" = true ] || s=http
    epp_set "$NS" "$N" "$(epp_default $s)"
  fi
  if [ "$want" = true ]; then
    until oc get deploy "${N}-kserve" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -q ssl-certfile; do sleep 5; done
  else
    while oc get deploy "${N}-kserve" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -q ssl-certfile; do sleep 5; done
  fi
  wait_isvc "$NS" "$N"; sleep 20; state
}
say "1) Full HTTPS: client->Envoy + internal TLS (current)"; state; measure full-https
say "2) Only Envoy HTTPS: internal TLS off (enableLLMInferenceServiceTLS=false)"; switch false; measure envoy-https
say "restore TLS (original: ${ORIG:-unset=default true})"; switch true
