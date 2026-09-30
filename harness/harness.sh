#!/usr/bin/env bash
# llm-d / MaaS harness for this repo (openshift-ai-llmd-demo). Assumes the
# base cluster already exists (bastion, OpenShift, GPU nodes, RHOAI,
# monitoring/logging) -- built separately via openshift-aws-harness
# (https://github.com/jangminjun/openshift-aws-harness), which stays the
# generic "install a cluster" tool. This harness only adds what's specific
# to llm-d testing: MaaS/RHCL, request tracing, model deployment, and the
# scenarios 11-14 and 21-29 (docs/scenarios/*.md). Idempotent where the
# underlying remote scripts are idempotent.
#
# Usage: ./harness.sh <subcommand> [args]
#   llmd-prereq                         check/prepare llm-d prerequisites (UWM, Grafana, CRD, Gateway, free GPU)
#   maas                                install RHCL + enable MaaS (RHOAI 3.5+: DSC aigateway.modelsAsAService)
#   maas-register-model                 register an LLMInferenceService with MaaS (LLMD_NAMESPACE/LLMD_NAME, MAAS_GROUP/MAAS_USERS,
#                                       MAAS_TOKEN_LIMIT default 1e9/h: benchmarks exceed a realistic per-user quota)
#   maas-unregister-model               remove an LLMInferenceService from MaaS (LLMD_NAMESPACE/LLMD_NAME)
#   maas-api-key                        mint a MaaS API key for the oc user -> Secret llmd-bench/loadgen-token (used by llmd-loadgen)
#   llmd-deploy-model                   deploy one LLMInferenceService (LLMD_NAMESPACE/LLMD_NAME/LLMD_MODEL_URI/...)
#   llmd-loadgen                        in-cluster load Job via tools/loadgen.py (LLMD_NAMESPACE/LLMD_NAME or URL/MODEL; see loadgen.py)
#   llmd-promql                         instant PromQL query via Thanos (QUERY='expr1;;expr2')
#   llmd-monitoring                     PrometheusRule + Grafana dashboard for one LLMInferenceService (LLMD_NAMESPACE)
#   tracing                             RHBO(OpenTelemetry) + Tempo Operator + TempoMonolithic + console Traces UI
#   llmd-tracing                        TRACING=on|off spec.tracing -> Tempo for LLMD_NAMESPACE/LLMD_NAME (default llmd-test),
#                                       on: sends LLMD_TRACING_PROBE (3) requests and lists the services Tempo received
#   llmd-test-{down,up}                 remove / re-apply the demo model (LLMD_MANIFEST, default manifests/llmd-test-llminferenceservice.json)
#   scenario11-llmd-dp-affinity         data parallelism x routing: replica 1 vs 2 (Service / EPP / session affinity)
#   scenario12-llmd-failure             failure & recovery: kill vLLM (r1, r2) or EPP pod under MaaS traffic
#   scenario13-llmd-tracing             per-request traces: turn 1 cache miss vs turn 2 cache hit (EPP + vLLM spans)
#   scenario14-llmd-latency             latency diagnosis: queue / prefill / decode bottleneck workloads
#   scenario21-llmd-flow-control        priority flow control (S21_DETECTOR=concurrency|utilization)
#   scenario22-llmd-epp-scorers         default EPP vs random-picker, multi-document workload
#   scenario23-llmd-lifecycle           rolling update under continuous traffic
#   scenario24-llmd-vlm-{up,run,down}   multimodal routing on a VLM (needs llmd-test-down first)
#   scenario25-llmd-tracing             spec.tracing -> Tempo, prints spans per request
#   scenario26-llmd-tls                 TLS on vs off (DSC, cluster-wide), restores
#   scenario27-llmd-scorer-weights      cache-first vs load-first policies x W1/W2/W3
#   scenario28-llmd-tokenizer           external tokenizer (vllm render) vs built-in
#   scenario29-llmd-canary-{up,weights,shift,down}  controlled deployment (needs llmd-test-down first)
#   maas-checks                         MAAS_CHECK=nonstream|token-limit
#
# Config: harness/config.env (exec mode, bastion IP, SSH key, model/GPU
# defaults). HARNESS_EXEC=local runs remote/*.sh on this machine against the
# current `oc login` session (no bastion needed). Cluster access: ../AGENT.md.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HARNESS_DIR"
source ./config.env
source ./lib.sh

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"

# run_bench <remote-script>|--eval <code>: prepend remote/lib/bench.sh, copy loadgen.py,
# and pass through every scenario/loadgen/MaaS variable that is set.
run_bench() {
  local envs="" v src
  for v in $(compgen -v | grep -E '^(S[12][0-9]_[A-Z0-9_]+|LLMD_[A-Z_]+|LOADGEN_[A-Z_]+|MAAS_[A-Z_]+|ALLOW_MULTI_EPP|TRACING_NAMESPACE|URL|MODEL|CONCURRENCY|REQUESTS|DURATION|INTERVAL|MAX_TOKENS|PROMPT_MODE|PREFIX_TOKENS|DOCS|DOC_OFFSET|DOC_ORDER|IMAGE_URLS|HEADERS|LABEL|TIMEOUT|TIMELINE|SESSIONS|TURNS|SESSION_HEADER|PAUSE_AFTER_TURN|PAUSE_SECONDS)$'); do
    [ -n "${!v:-}" ] && envs="$envs $v=$(printf '%q' "${!v}")"
  done
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion ./tools/loadgen.py "~/ocp-install/loadgen.py"
  if [ "$1" = --eval ]; then src=$(cat ./remote/lib/bench.sh; printf '\n%s\n' "$2"); else src=$(cat ./remote/lib/bench.sh "./remote/$1"); fi
  printf '%s\n' "$src" | ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' $envs bash -s"
}

cmd="${1:-}"
[ -n "$cmd" ] && shift || true
case "$cmd" in ""|help|-h|--help) ;; *) resolve_exec_mode ;; esac

cmd_llmd_prereq() {
  ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD:-}' bash -s" < ./remote/llmd-prereq.sh
}

# RHOAI 3.5+ only (DSC spec.components.aigateway). The 3.3/3.4 path (kserve.modelsAsService) was dropped.
cmd_maas() {
  ssh_bastion "${KCFG_INIT} oc explain datasciencecluster.spec.components.aigateway" >/dev/null 2>&1 \
    || err "DataScienceCluster has no spec.components.aigateway -- this harness needs RHOAI 3.5+"
  ssh_bastion 'bash -s' < ./remote/maas.sh
}

cmd_maas_register_model() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' LLMD_NAME='${LLMD_NAME:?set LLMD_NAME}'     MAAS_GROUP='${MAAS_GROUP:-llmd-demo}' MAAS_USERS='${MAAS_USERS:-}' MAAS_TOKEN_LIMIT='${MAAS_TOKEN_LIMIT:-1000000000}'     MAAS_TOKEN_WINDOW='${MAAS_TOKEN_WINDOW:-1h}' MAAS_PRIORITY='${MAAS_PRIORITY:-10}'     bash -s" < ./remote/maas-register-model.sh
}

cmd_maas_unregister_model() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' LLMD_NAME='${LLMD_NAME:?set LLMD_NAME}'     MAAS_GROUP='${MAAS_GROUP:-llmd-demo}' bash -s" < ./remote/maas-unregister-model.sh
}

cmd_maas_api_key() {
  ssh_bastion "KEY_NAME='${KEY_NAME:-llmd-loadgen}' KEY_NAMESPACE='${KEY_NAMESPACE:-llmd-bench}' bash -s" < ./remote/maas-api-key.sh
}

cmd_llmd_deploy_model() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' LLMD_NAME='${LLMD_NAME:-llmd-demo}' \
    LLMD_MODEL_URI='${LLMD_MODEL_URI:-}' LLMD_MODEL_NAME='${LLMD_MODEL_NAME:-}' LLMD_REPLICAS='${LLMD_REPLICAS:-1}' \
    GPU_INSTANCE_TYPE='${GPU_INSTANCE_TYPE:-}' LLMD_MEMORY='${LLMD_MEMORY:-16Gi}' LLMD_MAX_MODEL_LEN='${LLMD_MAX_MODEL_LEN:-16384}' \
    LLMD_GPU_MEM_UTIL='${LLMD_GPU_MEM_UTIL:-0.90}' LLMD_SCHEDULER='${LLMD_SCHEDULER:-true}'     LLMD_ROUTE_GROUP='${LLMD_ROUTE_GROUP:-}' LLMD_ROUTE_WEIGHT='${LLMD_ROUTE_WEIGHT:-}' LLMD_EXTRA_VLLM_ARGS='${LLMD_EXTRA_VLLM_ARGS:-}' \
    LLMD_GATEWAY_NAME='${LLMD_GATEWAY_NAME:-}' LLMD_GATEWAY_NAMESPACE='${LLMD_GATEWAY_NAMESPACE:-openshift-ingress}' \
    bash -s" < ./remote/llmd-deploy-model.sh
}

cmd_llmd_loadgen() { run_bench llmd-loadgen.sh; }

cmd_llmd_promql() {
  ssh_bastion "QUERY=$(printf '%q' "${QUERY:?set QUERY}") MONITORING_NAMESPACE='$MONITORING_NAMESPACE' bash -s" < ./remote/llmd-promql.sh
}

cmd_llmd_monitoring() {
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion ./remote/dashboards/llmd-observability.json "~/ocp-install/llmd-observability.json"
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' MONITORING_NAMESPACE='$MONITORING_NAMESPACE' \
    LLMD_TTFT_THRESHOLD_S='${LLMD_TTFT_THRESHOLD_S:-2}' LLMD_ERROR_RATE_THRESHOLD='${LLMD_ERROR_RATE_THRESHOLD:-0.05}' \
    bash -s" < ./remote/llmd-monitoring.sh
}

cmd_tracing() { ssh_bastion 'bash -s' < ./remote/tracing.sh; }
cmd_llmd_tracing() {
  run_bench --eval 'NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
if [ "'"${TRACING:-on}"'" = off ]; then tracing_disable "$NS" "$N"; exit 0; fi
tracing_enable "$NS" "$N" "${LLMD_TRACING_SAMPLER:-1.0}"
s=$(loadgen tracing-probe LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=short CONCURRENCY=1 REQUESTS="${LLMD_TRACING_PROBE:-3}" MAX_TOKENS=16 LABEL=tracing-probe)
brief "$s"; sleep 15
echo "  Tempo services: $(tempo_services)"
echo "  UI: OpenShift console > Observe > Traces (openshift-tempo/llmd-tracing)"'
}

# --- Scenario 29: controlled deployment (route group + weight) ---
# Needs to be the only EPP-enabled model on the Gateway (multi-InferencePool
# ext_proc mis-assignment, lessonlearn.md 2026-09-23) -- bring it up last and
# tear it down before restoring other llm-d models.
S29_NS="${LLMD_NAMESPACE:-llmd-s29}"
cmd_scenario29_llmd_canary_up() {
  LLMD_NAMESPACE="$S29_NS" run_bench --eval "require_single_epp $S29_NS"
  local v w a
  for v in "llmd-v1:${LLMD_V1_WEIGHT:-90}:" "llmd-v2:${LLMD_V2_WEIGHT:-10}:--max-num-seqs=8"; do
    IFS=: read -r n w a <<< "$v"
    LLMD_NAMESPACE="$S29_NS" LLMD_NAME="$n" LLMD_REPLICAS=1 LLMD_ROUTE_GROUP=chat LLMD_ROUTE_WEIGHT="$w"       LLMD_EXTRA_VLLM_ARGS="$a" cmd_llmd_deploy_model
    LLMD_NAMESPACE="$S29_NS" LLMD_NAME="$n" MAAS_TOKEN_LIMIT="${MAAS_TOKEN_LIMIT:-1000000000}" cmd_maas_register_model
  done
}
cmd_scenario29_llmd_canary_weights() {
  ssh_bastion "${KCFG_INIT}     oc patch llminferenceservice llmd-v1 -n '$S29_NS' --type=merge -p '{\"spec\":{\"router\":{\"route\":{\"group\":\"chat\",\"weight\":${LLMD_V1_WEIGHT:?set LLMD_V1_WEIGHT}}}}}';     oc patch llminferenceservice llmd-v2 -n '$S29_NS' --type=merge -p '{\"spec\":{\"router\":{\"route\":{\"group\":\"chat\",\"weight\":${LLMD_V2_WEIGHT:?set LLMD_V2_WEIGHT}}}}}'"
}
cmd_scenario29_llmd_canary_down() {
  local n
  for n in llmd-v1 llmd-v2; do
    LLMD_NAMESPACE="$S29_NS" LLMD_NAME="$n" cmd_maas_unregister_model
    ssh_bastion "${KCFG_INIT} oc delete llminferenceservice '$n' -n '$S29_NS' --ignore-not-found --wait=true"
  done
}

# --- demo model swap (Gateway allows one EPP model: 24/29 need llmd-test down) ---
LLMD_MANIFEST="${LLMD_MANIFEST:-../manifests/llmd-test-llminferenceservice.json}"
cmd_llmd_test_down() {
  ssh_bastion "${KCFG_INIT} oc delete llminferenceservice ${LLMD_NAME:-llmd-test} -n ${LLMD_NAMESPACE:-llmd-test} --ignore-not-found --wait=true"
}
cmd_llmd_test_up() {
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion "$LLMD_MANIFEST" "~/ocp-install/llmd-model.json"
  run_bench --eval 'require_single_epp "${LLMD_NAMESPACE:-llmd-test}"
oc get namespace "${LLMD_NAMESPACE:-llmd-test}" &>/dev/null || oc create namespace "${LLMD_NAMESPACE:-llmd-test}"
oc apply -f "$HOME/ocp-install/llmd-model.json"; sleep 5
wait_isvc "${LLMD_NAMESPACE:-llmd-test}" "${LLMD_NAME:-llmd-test}"
oc get llminferenceservice -n "${LLMD_NAMESPACE:-llmd-test}"'
}

# --- Scenarios 21-29: llm-d GA features (docs/scenarios/2x-*.md) ---
cmd_scenario21() { run_bench scenario21-flow-control.sh; }
cmd_scenario22() { run_bench scenario22-epp-scorers.sh; }
cmd_scenario23() { run_bench scenario23-lifecycle.sh; }
cmd_scenario24_up() {
  LLMD_NAMESPACE=llmd-s24 run_bench --eval 'require_single_epp llmd-s24'
  LLMD_NAMESPACE=llmd-s24 LLMD_NAME=llmd-vlm LLMD_MODEL_URI=hf://Qwen/Qwen2.5-VL-3B-Instruct LLMD_MODEL_NAME=     LLMD_REPLICAS=2 LLMD_MEMORY=8Gi LLMD_EXTRA_VLLM_ARGS="--limit-mm-per-prompt.image=1" cmd_llmd_deploy_model
  LLMD_NAMESPACE=llmd-s24 LLMD_NAME=llmd-vlm MAAS_TOKEN_LIMIT="${MAAS_TOKEN_LIMIT:-1000000000}" cmd_maas_register_model
}
cmd_scenario24_run() { LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-s24}" LLMD_NAME="${LLMD_NAME:-llmd-vlm}" run_bench scenario24-multimodal.sh; }
cmd_scenario24_down() {
  LLMD_NAMESPACE=llmd-s24 LLMD_NAME=llmd-vlm cmd_maas_unregister_model
  ssh_bastion "${KCFG_INIT} oc delete llminferenceservice llmd-vlm -n llmd-s24 --ignore-not-found --wait=true"
}
cmd_scenario25() { run_bench scenario25-tracing.sh; }
cmd_scenario26() { run_bench scenario26-tls.sh; }
cmd_scenario27() { run_bench scenario27-scorer-weights.sh; }
cmd_scenario28() { run_bench scenario28-tokenizer.sh; }
cmd_scenario29_shift() { LLMD_NAMESPACE="$S29_NS" run_bench scenario29-canary-shift.sh; }
cmd_maas_checks() { run_bench maas-checks.sh; }


# --- Scenario 11: data parallelism x routing (llmd-test, replica 1 vs 2) ---
cmd_scenario11_affinity() { run_bench scenario11-dp-affinity.sh; }

# --- Scenario 12: failure & recovery (llmd-test via MaaS + EPP) ---
cmd_scenario12() { run_bench scenario12-failure.sh; }

# --- Scenario 13: request tracing, cache miss vs hit (llmd-test) ---
cmd_scenario13() { run_bench scenario13-trace-cache.sh; }

# --- Scenario 14: latency diagnosis, one workload per bottleneck (llmd-test) ---
cmd_scenario14() { run_bench scenario14-latency.sh; }

cmd_status() {
  ssh_bastion "${KCFG_INIT} \
    echo '=== llm-d LLMInferenceServices ==='; oc get llminferenceservice -A; \
    echo '=== GPU nodes ==='; oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.metadata.labels.node\\.kubernetes\\.io/instance-type}{\"\n\"}{end}'; \
    echo '=== MaaS ==='; oc get gateway -n openshift-ingress 2>&1; \
    echo '=== MaaS token limits ==='; oc get maassubscription -A -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.modelRefs[*]}{.namespace}/{.name}={.tokenRateLimits[0].limit}/{.tokenRateLimits[0].window} {end}{\"\n\"}{end}' 2>&1; \
    echo '=== Tracing ==='; oc get tempomonolithic,opentelemetrycollector -n ${TRACING_NAMESPACE:-openshift-tempo} 2>&1 || echo '(not installed: ./harness.sh tracing)'; \
    oc get llminferenceservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: tracing={.spec.tracing.exporterEndpoint} sampler={.spec.tracing.samplerArg}{\"\n\"}{end}'"
}

case "$cmd" in
  llmd-prereq)                        cmd_llmd_prereq ;;
  maas)                               cmd_maas ;;
  maas-register-model)                cmd_maas_register_model ;;
  maas-api-key)                       cmd_maas_api_key ;;
  maas-unregister-model)              cmd_maas_unregister_model ;;
  scenario29-llmd-canary-up)          cmd_scenario29_llmd_canary_up ;;
  scenario29-llmd-canary-weights)     cmd_scenario29_llmd_canary_weights ;;
  scenario29-llmd-canary-down)        cmd_scenario29_llmd_canary_down ;;
  scenario29-llmd-canary-shift)       cmd_scenario29_shift ;;
  llmd-test-down)                     cmd_llmd_test_down ;;
  llmd-test-up)                       cmd_llmd_test_up ;;
  scenario21-llmd-flow-control)       cmd_scenario21 ;;
  scenario22-llmd-epp-scorers)        cmd_scenario22 ;;
  scenario23-llmd-lifecycle)          cmd_scenario23 ;;
  scenario24-llmd-vlm-up)             cmd_scenario24_up ;;
  scenario24-llmd-vlm-run)            cmd_scenario24_run ;;
  scenario24-llmd-vlm-down)           cmd_scenario24_down ;;
  scenario25-llmd-tracing)            cmd_scenario25 ;;
  scenario26-llmd-tls)                cmd_scenario26 ;;
  scenario27-llmd-scorer-weights)     cmd_scenario27 ;;
  scenario28-llmd-tokenizer)          cmd_scenario28 ;;
  maas-checks)                        cmd_maas_checks ;;
  llmd-deploy-model)                  cmd_llmd_deploy_model ;;
  llmd-monitoring)                    cmd_llmd_monitoring ;;
  llmd-loadgen)                       cmd_llmd_loadgen ;;
  llmd-promql)                        cmd_llmd_promql ;;
  tracing)                            cmd_tracing ;;
  llmd-tracing)                       cmd_llmd_tracing ;;
  scenario11-llmd-dp-affinity)        cmd_scenario11_affinity ;;
  scenario12-llmd-failure)            cmd_scenario12 ;;
  scenario13-llmd-tracing)            cmd_scenario13 ;;
  scenario14-llmd-latency)            cmd_scenario14 ;;
  status)                             cmd_status ;;
  ""|help|-h|--help)                  sed -n '/^# Usage:/,/^# Config:/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *)
    err "Unknown subcommand '$cmd'. Run ./harness.sh help for the list."
    ;;
esac
