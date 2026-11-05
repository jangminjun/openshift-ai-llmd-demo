#!/usr/bin/env bash
# llm-d / MaaS harness for this repo (openshift-ai-llmd-demo). Assumes the base
# cluster (OpenShift, GPU, RHOAI) already exists. Two cluster profiles
# (HARNESS_PROFILE, harness/profiles/<name>.env):
#   aws  (default) multi-node AWS cluster built by openshift-aws-harness, bastion + GPU MachineSet
#   sno            scenarios-2 on RHDP sandbox1343: SNO control plane (+ GPU workers), local `oc login` session
# This harness adds what is specific to llm-d testing: MaaS/RHCL, request tracing,
# model deployment, and scenarios 11-14 / 21-29 (docs/scenarios/*.md).
#
# Usage: ./harness.sh <subcommand> [args]
#
# [SNO] Single Node OpenShift (HARNESS_PROFILE=sno)
#   sno-check                           topology, GPU, OCP/RHOAI versions, DSC, operators, scenario fit by GPU count
#   sno-enable-features                 run the pinned third-party RHOAI 3.5 SNO "enable all features" script
#                                       (SNO_FEATURES_ARGS=--skip-install, SNO_FEATURES_REFRESH=true re-downloads)
#
# [Prepare] both profiles
#   llmd-prereq                         check/prepare llm-d prerequisites (UWM, Grafana, CRD, Gateway, free GPU)
#   maas                                install RHCL + enable MaaS (RHOAI 3.5+: DSC aigateway.modelsAsAService)
#   tracing                             RHBO(OpenTelemetry) + Tempo Operator + TempoMonolithic + console Traces UI
#   status                              LLMInferenceServices, GPU nodes, Gateways, MaaS limits, tracing
#
# [Model] demo model and MaaS registration
#   llmd-test-{down,up}                 remove / apply the demo model (LLMD_MANIFEST; profile default:
#                                       sno -> manifests/sno/ (replicas 1), aws -> manifests/ (replicas 2))
#   llmd-deploy-model                   deploy one LLMInferenceService (LLMD_NAMESPACE/LLMD_NAME/LLMD_MODEL_URI/...)
#   maas-register-model                 register an LLMInferenceService with MaaS (LLMD_NAMESPACE/LLMD_NAME, MAAS_GROUP/MAAS_USERS,
#                                       MAAS_TOKEN_LIMIT default 1e9/h: benchmarks exceed a realistic per-user quota)
#   maas-unregister-model               remove an LLMInferenceService from MaaS (LLMD_NAMESPACE/LLMD_NAME)
#   maas-api-key                        mint a MaaS API key for the oc user -> Secret llmd-bench/loadgen-token (used by llmd-loadgen)
#
# [Observe] load, metrics, traces
#   llmd-loadgen                        in-cluster load Job via tools/loadgen.py (LLMD_NAMESPACE/LLMD_NAME or URL/MODEL; see loadgen.py)
#   guidellm                            GuideLLM benchmark Job vs LLMD_NAMESPACE/LLMD_NAME (GUIDELLM_VIA=direct|maas,
#                                       GUIDELLM_PROFILE/STREAMS/RATES/PROMPT_TOKENS/OUTPUT_TOKENS/MAX_SECONDS, see remote/guidellm.sh)
#   llmd-promql                         instant PromQL query via Thanos (QUERY='expr1;;expr2')
#   llmd-monitoring                     PrometheusRule + Grafana dashboard for one LLMInferenceService (LLMD_NAMESPACE)
#   grafana-dashboard                   publish remote/dashboards/<DASHBOARD>.json as a GrafanaDashboard (default llmd-pd-latency)
#   llmd-tracing                        TRACING=on|off spec.tracing -> Tempo for LLMD_NAMESPACE/LLMD_NAME (default llmd-test),
#                                       on: sends LLMD_TRACING_PROBE (3) requests and lists the services Tempo received
#   scenario2-07-maas-ratelimit         MaaS token limit with long prompts (MAAS_RL_ARMS=E1..E4, see remote/scenario2-07-maas-ratelimit.sh)
#   scenario2-08-mitigation             429 mitigations: limit sizing, concurrency cap, retry policy, subscription split (MAAS_MIT_ARMS=M1..M4)
#   maas-checks                         MAAS_CHECK=nonstream|token-limit
#
# [Scenarios] 1 GPU (SNO ok)
#   scenario13-llmd-tracing             per-request traces: turn 1 cache miss vs turn 2 cache hit (EPP + vLLM spans)
#   scenario14-llmd-latency             latency diagnosis: queue / prefill / decode bottleneck workloads
#   scenario21-llmd-flow-control        priority flow control (S21_DETECTOR=concurrency|utilization)
#   scenario25-llmd-tracing             spec.tracing -> Tempo, prints spans per request
#   scenario28-llmd-tokenizer           external tokenizer (vllm render) vs built-in
#
# [Scenarios] 2+ GPUs (refused below that; SKIP_GPU_CHECK=true overrides)
#   scenario11-llmd-dp-affinity         data parallelism x routing: replica 1 vs 2 (Service / EPP / session affinity)
#   scenario12-llmd-failure             failure & recovery: kill vLLM (r1, r2) or EPP pod under MaaS traffic
#   scenario22-llmd-epp-scorers         scorer effects, S22_PARTS="abc kv lru": 1 random/2/4 scorers, 2 KV-full pod
#                                       avoidance (kv-cache-utilization), 3 new-document placement (no-hit-lru)
#   scenario23-llmd-lifecycle           zero-downtime rolling update under traffic (needs 1 idle GPU next to the model)
#   scenario24-llmd-vlm-{up,run,down}   multimodal routing on a VLM, replicas 2 (needs llmd-test-down first)
#   scenario26-llmd-tls                 TLS on vs off (DSC, cluster-wide), restores
#   scenario27-llmd-scorer-weights      cache-first vs load-first policies x W1/W2/W3
#   scenario29-llmd-canary-{up,weights,shift,down}  controlled deployment: v1/v2 behind one route group, weight shift
#                                       (EPP off by default: LLMD_SCHEDULER=true re-enables it; run llmd-test-down first)
#
# Config: harness/config.env + harness/profiles/<HARNESS_PROFILE>.env (exec mode,
# bastion, GPU type, demo manifest, GPU_ROLLOUT). HARNESS_EXEC=local runs remote/*.sh
# on this machine against the current `oc login` session. Cluster access: ../AGENT.md.
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
  for v in $(compgen -v | grep -E '^(S[12][0-9]_[A-Z0-9_]+|LLMD_[A-Z_]+|LOADGEN_[A-Z_]+|MAAS_[A-Z_]+|ALLOW_MULTI_EPP|GPU_ROLLOUT|TRACING_NAMESPACE|URL|MODEL|CONCURRENCY|REQUESTS|DURATION|INTERVAL|MAX_TOKENS|PROMPT_MODE|PREFIX_TOKENS|DOCS|DOC_OFFSET|DOC_ORDER|IMAGE_URLS|HEADERS|LABEL|TIMEOUT|TIMELINE|SESSIONS|TURNS|SESSION_HEADER|PAUSE_AFTER_TURN|PAUSE_SECONDS)$'); do
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

# Minimum allocatable GPUs per subcommand (replicas 2, two models, or a spare GPU for a rollout).
SNO_GPU_NEEDS="scenario11-llmd-dp-affinity:2 scenario12-llmd-failure:2 scenario22-llmd-epp-scorers:2 \
scenario23-llmd-lifecycle:2 scenario24-llmd-vlm-up:2 scenario26-llmd-tls:2 scenario27-llmd-scorer-weights:2 \
scenario29-llmd-canary-up:2"
gpu_total() {
  ssh_bastion "${KCFG_INIT} oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].status.allocatable.nvidia\\.com/gpu}'" \
    | tr ' ' '\n' | awk '{s+=$1} END{print s+0}'
}
need_gpus() {
  local e need="" total
  for e in $SNO_GPU_NEEDS; do [ "${e%%:*}" = "$1" ] && need=${e#*:}; done
  [ -n "$need" ] && [ "${SKIP_GPU_CHECK:-false}" != true ] || return 0
  total=$(gpu_total)
  [ "$total" -ge "$need" ] || err "$1 needs $need GPUs, cluster has $total (profile $HARNESS_PROFILE). Add a GPU node or set SKIP_GPU_CHECK=true."
}
case "$cmd" in ""|help|-h|--help) ;; *) need_gpus "$cmd" ;; esac

# --- SNO ---
cmd_sno_check() {
  log "profile=$HARNESS_PROFILE manifest=$LLMD_MANIFEST GPU_ROLLOUT=${GPU_ROLLOUT:-surge}"
  ssh_bastion "SNO_GPU_NEEDS='$SNO_GPU_NEEDS' GPU_ROLLOUT='${GPU_ROLLOUT:-surge}' bash -s" < ./remote/sno/sno-check.sh
}
# Third-party script (not part of this repo): downloaded once from the pinned URL into
# harness/.cache/, then run as a file rather than piped to stdin.
cmd_sno_enable_features() {
  local f="$HARNESS_DIR/.cache/sno-enable-all-features-35.sh"
  mkdir -p "$HARNESS_DIR/.cache"
  if [ ! -s "$f" ] || [ "${SNO_FEATURES_REFRESH:-false}" = true ]; then
    log "download ${SNO_FEATURES_SCRIPT_URL:?set SNO_FEATURES_SCRIPT_URL (profiles/sno.env)}"
    curl -fsSL "$SNO_FEATURES_SCRIPT_URL" -o "$f"
  fi
  log "run $(basename "$f") ${SNO_FEATURES_ARGS:-} (sha256 $(sha256sum "$f" | cut -c1-12))"
  scp_to_bastion "$f" "~/ocp-install/sno-enable-all-features-35.sh"
  ssh_bastion "${KCFG_INIT} bash ~/ocp-install/sno-enable-all-features-35.sh ${SNO_FEATURES_ARGS:-}"
}

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
  ssh_bastion "KEY_NAME='${KEY_NAME:-llmd-loadgen}' KEY_NAMESPACE='${KEY_NAMESPACE:-llmd-bench}' \
    KEY_SECRET='${KEY_SECRET:-loadgen-token}' KEY_SUBSCRIPTION='${KEY_SUBSCRIPTION:-}' bash -s" < ./remote/maas-api-key.sh
}

cmd_llmd_deploy_model() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' LLMD_NAME='${LLMD_NAME:-llmd-demo}' \
    LLMD_MODEL_URI='${LLMD_MODEL_URI:-}' LLMD_MODEL_NAME='${LLMD_MODEL_NAME:-}' LLMD_REPLICAS='${LLMD_REPLICAS:-1}' \
    GPU_INSTANCE_TYPE='${GPU_INSTANCE_TYPE:-}' LLMD_MEMORY='${LLMD_MEMORY:-16Gi}' LLMD_MAX_MODEL_LEN='${LLMD_MAX_MODEL_LEN:-16384}' \
    LLMD_GPU_MEM_UTIL='${LLMD_GPU_MEM_UTIL:-0.90}' LLMD_SCHEDULER='${LLMD_SCHEDULER:-true}'     LLMD_ROUTE_GROUP='${LLMD_ROUTE_GROUP:-}' LLMD_ROUTE_WEIGHT='${LLMD_ROUTE_WEIGHT:-}' LLMD_EXTRA_VLLM_ARGS='${LLMD_EXTRA_VLLM_ARGS:-}' \
    LLMD_GATEWAY_NAME='${LLMD_GATEWAY_NAME:-}' LLMD_GATEWAY_NAMESPACE='${LLMD_GATEWAY_NAMESPACE:-openshift-ingress}' \
    bash -s" < ./remote/llmd-deploy-model.sh
}

cmd_guidellm() {
  local envs="" v
  for v in $(compgen -v | grep -E '^(GUIDELLM_[A-Z_]+|LLMD_NAMESPACE|LLMD_NAME|LOADGEN_NAMESPACE)$'); do
    envs="$envs $v=$(printf '%q' "${!v}")"
  done
  ssh_bastion "$envs bash -s" < ./remote/guidellm.sh
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

cmd_grafana_dashboard() {
  local f="${DASHBOARD:-llmd-pd-latency}.json"
  [ -f "./remote/dashboards/$f" ] || err "no remote/dashboards/$f"
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion "./remote/dashboards/$f" "~/ocp-install/$f"
  ssh_bastion "DASHBOARD_FILE='$f' DASHBOARD_NAME='${DASHBOARD_NAME:-}' MONITORING_NAMESPACE='$MONITORING_NAMESPACE' bash -s" < ./remote/grafana-dashboard.sh
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
# v1 and v2 are deployed WITHOUT an EPP by default (LLMD_SCHEDULER=false): two EPP models on one
# Gateway get every route wired to the last-created EPP (lessonlearn.md 2026-09-23 / 2026-09-30),
# while the route-group weights work on plain workload Services. LLMD_SCHEDULER=true restores the
# EPP variant (then it must be the only EPP model on the Gateway).
S29_NS="${LLMD_NAMESPACE:-llmd-s29}"
cmd_scenario29_llmd_canary_up() {
  LLMD_NAMESPACE="$S29_NS" run_bench --eval "require_single_epp $S29_NS"
  local v w a
  for v in "llmd-v1:${LLMD_V1_WEIGHT:-90}:" "llmd-v2:${LLMD_V2_WEIGHT:-10}:--max-num-seqs=8"; do
    IFS=: read -r n w a <<< "$v"
    LLMD_NAMESPACE="$S29_NS" LLMD_NAME="$n" LLMD_REPLICAS=1 LLMD_ROUTE_GROUP=chat LLMD_ROUTE_WEIGHT="$w"       LLMD_EXTRA_VLLM_ARGS="$a" LLMD_SCHEDULER="${LLMD_SCHEDULER:-false}" cmd_llmd_deploy_model
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
LLMD_MANIFEST="${LLMD_MANIFEST:-../manifests/llmd-test-llminferenceservice.json}"   # profiles/*.env set it
cmd_llmd_test_down() {
  ssh_bastion "${KCFG_INIT} oc delete llminferenceservice ${LLMD_NAME:-llmd-test} -n ${LLMD_NAMESPACE:-llmd-test} --ignore-not-found --wait=true"
}
cmd_llmd_test_up() {
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion "$LLMD_MANIFEST" "~/ocp-install/llmd-model.json"
  run_bench --eval 'require_single_epp "${LLMD_NAMESPACE:-llmd-test}"
# baseRefs follow the installed RHOAI (v3-5-1-kserve-config-* -> v3-5-2-kserve-config-* ...)
v=$(oc get llminferenceserviceconfig -n redhat-ods-applications -o name | sed -n "s#.*/\(v[0-9-]*\)-kserve-config-llm-tokenizer\$#\1#p" | head -1)
[ -z "$v" ] || sed -i -E "s/v[0-9]+-[0-9]+-[0-9]+-kserve-config-/$v-kserve-config-/g" "$HOME/ocp-install/llmd-model.json"
oc get namespace "${LLMD_NAMESPACE:-llmd-test}" &>/dev/null || oc create namespace "${LLMD_NAMESPACE:-llmd-test}"
oc apply -f "$HOME/ocp-install/llmd-model.json"; sleep 5
wait_isvc "${LLMD_NAMESPACE:-llmd-test}" "${LLMD_NAME:-llmd-test}"
# maas-controller may have checked the model before its pods were Ready and does not recheck on its own
ns="${LLMD_NAMESPACE:-llmd-test}"; n="${LLMD_NAME:-llmd-test}"
if oc get maasmodelref "$n" -n "$ns" &>/dev/null; then
  for _ in $(seq 1 12); do [ "$(oc get maasmodelref "$n" -n "$ns" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" = True ] && break; sleep 5; done
  if [ "$(oc get maasmodelref "$n" -n "$ns" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" != True ]; then
    echo "  MaaSModelRef $ns/$n not Ready -> restarting maas-controller to recheck"
    oc rollout restart deploy/maas-controller -n redhat-ods-applications >/dev/null
    oc rollout status deploy/maas-controller -n redhat-ods-applications --timeout=180s >/dev/null
  fi
  oc get maasmodelref "$n" -n "$ns"
fi
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
cmd_scenario2_07() { run_bench scenario2-07-maas-ratelimit.sh; }
cmd_scenario2_08() { run_bench scenario2-08-mitigation.sh; }


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
  scenario2-07-maas-ratelimit)        cmd_scenario2_07 ;;
  scenario2-08-mitigation)            cmd_scenario2_08 ;;
  maas-checks)                        cmd_maas_checks ;;
  llmd-deploy-model)                  cmd_llmd_deploy_model ;;
  llmd-monitoring)                    cmd_llmd_monitoring ;;
  grafana-dashboard)                  cmd_grafana_dashboard ;;
  llmd-loadgen)                       cmd_llmd_loadgen ;;
  guidellm)                           cmd_guidellm ;;
  llmd-promql)                        cmd_llmd_promql ;;
  tracing)                            cmd_tracing ;;
  llmd-tracing)                       cmd_llmd_tracing ;;
  scenario11-llmd-dp-affinity)        cmd_scenario11_affinity ;;
  scenario12-llmd-failure)            cmd_scenario12 ;;
  scenario13-llmd-tracing)            cmd_scenario13 ;;
  scenario14-llmd-latency)            cmd_scenario14 ;;
  status)                             cmd_status ;;
  sno-check)                          cmd_sno_check ;;
  sno-enable-features)                cmd_sno_enable_features ;;
  ""|help|-h|--help)                  sed -n '/^# Usage:/,/^# Config:/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *)
    err "Unknown subcommand '$cmd'. Run ./harness.sh help for the list."
    ;;
esac
