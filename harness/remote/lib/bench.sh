# Shared helpers for the llm-d scenario scripts (remote/scenario2*.sh, llmd-loadgen.sh,
# maas-checks.sh). harness.sh prepends this file to the script and pipes both to
# `bash -s` (bastion or local), so every scenario script stays a single stream.
# Requires: oc, curl, python3|python. loadgen.py is copied to ~/ocp-install first.
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
# Git Bash (Windows local mode) rewrites path-like ARGUMENTS of native programs
# ("/mnt/models/base" -> "C:/Program Files/Git/mnt/models/base") but real file paths
# need that conversion -> never pass in-container paths as argv; use stdin instead.
# python3 may be a non-functional Store alias on Windows (local mode) -> fall back to python.
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python

BENCH_NS="${LOADGEN_NAMESPACE:-llmd-bench}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-registry.access.redhat.com/ubi9/python-311:latest}"
LOADGEN_VARS="URL MODEL CONCURRENCY REQUESTS DURATION INTERVAL MAX_TOKENS PROMPT_MODE PREFIX_TOKENS DOCS DOC_OFFSET IMAGE_URLS HEADERS LABEL TIMEOUT TIMELINE"

say()  { printf '\n== %s ==\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
cold_offset() { echo $(( ($(date +%s) % 100000) * 10 )); }   # fresh doc/image range per run

# ---------- Thanos ----------
_THANOS_TOKEN=""; _THANOS_HOST=""
thanos() {  # <promql> -> raw JSON
  [ -n "$_THANOS_TOKEN" ] || _THANOS_TOKEN=$(oc create token grafana-thanos-reader -n "$MONITORING_NAMESPACE" --duration=30m)
  [ -n "$_THANOS_HOST" ] || _THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
  curl -sk -H "Authorization: Bearer $_THANOS_TOKEN" --data-urlencode "query=$1" "https://$_THANOS_HOST/api/v1/query"
}
thanos_print() {  # <title> <promql>: "labels value" rows
  echo "  # $1"
  thanos "$2" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
if d.get("status") != "success": print("    ERROR", d.get("error")); sys.exit()
skip = {"__name__","prometheus","endpoint","job","instance","service","container","namespace","llm_isvc_component","pod"}
for r in d["data"]["result"] or []:
    m = {k: v for k, v in r["metric"].items() if k not in skip}
    print("    %s %s" % (json.dumps(m, sort_keys=True) if m else "{}", r["value"][1]))
if not d["data"]["result"]: print("    (no data)")'
}

# pod_counters <ns> -> one JSON line {pod: [prefix_hits, prefix_queries, mm_hits, mm_queries, requests]}
pod_counters() {
  local ns=$1 a b c d e
  a=$(thanos "sum by (pod)(kserve_vllm:prefix_cache_hits_total{namespace=\"$ns\"})")
  b=$(thanos "sum by (pod)(kserve_vllm:prefix_cache_queries_total{namespace=\"$ns\"})")
  c=$(thanos "sum by (pod)(kserve_vllm:mm_cache_hits_total{namespace=\"$ns\"})")
  d=$(thanos "sum by (pod)(kserve_vllm:mm_cache_queries_total{namespace=\"$ns\"})")
  e=$(thanos "sum by (pod)(kserve_vllm:request_success_total{namespace=\"$ns\"})")
  "$PY" -c '
import sys, json
maps = [{r["metric"].get("pod"): float(r["value"][1]) for r in json.loads(x)["data"]["result"]} for x in sys.argv[1:]]
pods = sorted(set().union(*maps))
print(json.dumps({p: [m.get(p, 0) for m in maps] for p in pods}))' "$a" "$b" "$c" "$d" "$e"
}
# report <summary-json> <before-json> <after-json>: one result line
report() {
  "$PY" -c '
import sys, json
s, b, a = (json.loads(x) for x in sys.argv[1:4])
d = {p: [a[p][i] - b.get(p, [0] * 5)[i] for i in range(5)] for p in a}
t = [sum(v[i] for v in d.values()) for i in range(5)]
split = ":".join(str(int(v[4])) for _, v in sorted(d.items()) if v[4] > 0) or "-"
mm = ("%.1f%%" % (100 * t[2] / t[3])) if t[3] else "-"
print("  %-24s ok=%d/%d codes=%s rps=%.2f ttft50=%s ttft95=%s e2e95=%s prefix_hit=%.1f%% mm_hit=%s split=%s" % (
    s["label"], s["ok"], s["n"], json.dumps(s["codes"]), s["rps"], s["ttft_p50"], s["ttft_p95"], s["e2e_p95"],
    100 * t[0] / max(t[1], 1), mm, split))' "$1" "$2" "$3"
}

# ---------- load generator (in-cluster Job) ----------
# loadgen_start <job-name> [VAR=VAL ...]: target = URL/MODEL or LLMD_NAMESPACE/LLMD_NAME (MaaS path).
loadgen_start() {
  local name=$1; shift
  (
    for kv in "$@"; do export "$kv"; done
    if [ -z "${URL:-}" ]; then
      URL="$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.url}')/v1/chat/completions"
    fi
    [ -n "${MODEL:-}" ] || MODEL=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')
    oc get namespace "$BENCH_NS" &>/dev/null || oc create namespace "$BENCH_NS" >/dev/null
    oc get sa loadgen -n "$BENCH_NS" &>/dev/null || oc create sa loadgen -n "$BENCH_NS" >/dev/null
    oc create configmap loadgen-script -n "$BENCH_NS" --from-file=loadgen.py="$HOME/ocp-install/loadgen.py" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    args=(--from-literal=URL="$URL" --from-literal=MODEL="$MODEL")
    for v in $LOADGEN_VARS; do
      [ "$v" = URL ] || [ "$v" = MODEL ] || { [ -n "${!v:-}" ] && args+=(--from-literal="$v=${!v}"); } || true
    done
    oc create configmap "${name}-env" -n "$BENCH_NS" "${args[@]}" --dry-run=client -o yaml | oc apply -f - >/dev/null
    oc delete job "$name" -n "$BENCH_NS" --ignore-not-found --wait=true >/dev/null
    oc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: ${name}, namespace: ${BENCH_NS}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 7200
  template:
    spec:
      serviceAccountName: loadgen
      restartPolicy: Never
      containers:
      - name: loadgen
        image: ${LOADGEN_IMAGE}
        command: ["python3", "-u", "/app/loadgen.py"]
        envFrom: [{configMapRef: {name: ${name}-env}}]
        # MaaS API key from 'harness.sh maas-api-key' if present; else the SA token is used.
        env: [{name: TOKEN, valueFrom: {secretKeyRef: {name: loadgen-token, key: token, optional: true}}}]
        resources: {requests: {cpu: 500m, memory: 256Mi}}
        volumeMounts: [{name: script, mountPath: /app}]
      volumes: [{name: script, configMap: {name: loadgen-script}}]
YAML
    echo "  loadgen $name -> $URL (model=$MODEL)" >&2
  )
  for _ in $(seq 1 60); do   # wait until the pod runs so callers can time phases
    [ "$(oc get pods -n "$BENCH_NS" -l job-name="$name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = Running ] && return 0
    [ -n "$(oc get job "$name" -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}')" ] && return 0
    sleep 3
  done
}
loadgen_wait() {  # <job-name> -> SUMMARY json on stdout
  local name=$1
  until [ -n "$(oc get job "$name" -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]; do sleep 5; done
  oc logs "job/$name" -n "$BENCH_NS" | sed -n 's/^SUMMARY //p' | tail -1 | grep . \
    || { oc logs "job/$name" -n "$BENCH_NS" | tail -20 >&2; die "loadgen $name produced no summary"; }
}
loadgen() { loadgen_start "$@"; loadgen_wait "$1"; }   # blocking run
brief() {  # <summary-json> -> compact line (drops timeline)
  "$PY" -c 'import sys,json; s=json.loads(sys.argv[1]); s.pop("timeline",None); s.pop("errors",None); print("  "+json.dumps(s))' "$1"
}

# ---------- LLMInferenceService / EPP ----------
wait_isvc() {  # <ns> <name>: controller caught up + Ready + workloads rolled out
  local ns=$1 n=$2
  for _ in $(seq 1 120); do
    local g o r
    g=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.metadata.generation}')
    o=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.status.observedGeneration}')
    r=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [ "$g" = "$o" ] && [ "$r" = True ] && break
    sleep 10
  done
  for d in $(oc get deploy -n "$ns" -o name | grep "/${n}-"); do oc rollout status "$d" -n "$ns" --timeout=900s >/dev/null; done
}
epp_default() {  # [scheme] -> RHOAI 3.5.1 default EndpointPickerConfig (JSON)
  local scheme=${1:-https}
  echo '{"apiVersion":"llm-d.ai/v1alpha1","kind":"EndpointPickerConfig","plugins":[{"type":"single-profile-handler"},{"type":"queue-scorer"},{"type":"kv-cache-utilization-scorer"},{"type":"prefix-cache-scorer"},{"type":"no-hit-lru-scorer"},{"type":"max-score-picker"},{"type":"metrics-data-source","parameters":{"scheme":"'"$scheme"'"}}],"schedulingProfiles":[{"name":"default","plugins":[{"pluginRef":"queue-scorer","weight":2},{"pluginRef":"kv-cache-utilization-scorer","weight":2},{"pluginRef":"prefix-cache-scorer","weight":3},{"pluginRef":"no-hit-lru-scorer","weight":2},{"pluginRef":"max-score-picker"}]}]}'
}
tls_scheme() { oc get cm inferenceservice-config -n redhat-ods-applications -o jsonpath='{.data.ingress}' | grep -q '"enableLLMInferenceServiceTLS": false' && echo http || echo https; }
# epp_set <ns> <name> <inline-json>: replace the WHOLE inline config (merge patches leave stale keys ->
# EPP CrashLoop) and wait for the EPP rollout.
epp_set() {
  local ns=$1 n=$2 cfg=$3 before
  before=$(oc get deploy "${n}-kserve-router-scheduler" -n "$ns" -o jsonpath='{.metadata.generation}')
  oc patch llminferenceservice "$n" -n "$ns" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/router/scheduler/config\",\"value\":{\"inline\":$cfg}}]" >/dev/null
  for _ in $(seq 1 60); do
    [ "$(oc get deploy "${n}-kserve-router-scheduler" -n "$ns" -o jsonpath='{.metadata.generation}')" != "$before" ] && break
    sleep 2
  done
  oc rollout status "deploy/${n}-kserve-router-scheduler" -n "$ns" --timeout=300s >/dev/null
  sleep 20   # EPP warms its endpoint/metrics view
}
epp_restore_default() { epp_set "$1" "$2" "$(epp_default "$(tls_scheme)")"; echo "  EPP config restored to default"; }
vllm_args() { oc get llminferenceservice "$2" -n "$1" -o jsonpath='{.spec.template.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'; }
# set_max_num_seqs <ns> <name> <n|default>: rewrites --max-num-seqs in VLLM_ADDITIONAL_ARGS (rolling restart)
set_max_num_seqs() {
  local ns=$1 n=$2 v=$3 cur new idx
  cur=$(vllm_args "$ns" "$n")
  new=$(printf '%s' "$cur" | sed -E 's/ ?--max-num-seqs=[0-9]+//')
  [ "$v" = default ] || new="$new --max-num-seqs=$v"
  [ "$new" = "$cur" ] && { echo "  vLLM args unchanged ($cur)"; return; }
  require_free_gpu
  idx=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{range .spec.template.containers[0].env[*]}{.name}{"\n"}{end}' | grep -nx VLLM_ADDITIONAL_ARGS | cut -d: -f1)
  oc patch llminferenceservice "$n" -n "$ns" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/containers/0/env/$((idx - 1))/value\",\"value\":\"$new\"}]" >/dev/null
  echo "  vLLM args -> $new (rolling restart)"
  sleep 5; wait_isvc "$ns" "$n"
}
# require_single_epp <own-namespace>: one EPP-enabled model per Gateway (multi-InferencePool ext_proc bug)
require_single_epp() {
  local others
  others=$(oc get inferencepool -A --no-headers 2>/dev/null | awk -v ns="$1" '$1!=ns{print $1"/"$2}' | tr '\n' ' ')
  [ -z "$others" ] || [ "${ALLOW_MULTI_EPP:-false}" = true ] || \
    die "other InferencePools on the cluster: $others-- one EPP model per Gateway (see lessonlearn.md). Run 'harness.sh llmd-test-down' first or set ALLOW_MULTI_EPP=true."
}
# require_free_gpu: workload Deployments roll with maxSurge=1/maxUnavailable=0, so any pod-template
# change (vLLM args, tracing env, TLS) needs one idle GPU or the new pod stays Pending forever.
free_gpus() {
  local total used
  total=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')
  used=$(oc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.nvidia\.com/gpu}{"\n"}{end}{end}' | awk '{s+=$1} END{print s+0}')
  echo $((total - used))
}
require_free_gpu() {
  local f
  for _ in $(seq 1 18); do   # terminating pods from a previous rollout still hold their GPU
    f=$(free_gpus); [ "$f" -ge 1 ] && return 0; sleep 10
  done
  [ "$f" -ge 1 ] || die "rolling update needs 1 idle GPU (free: $f). Scale out first:
  oc scale machineset <gpu-machineset> -n openshift-machine-api --replicas=N (+ MachineAutoscaler min/max)"
}
maas_key() { oc get secret loadgen-token -n "$BENCH_NS" -o jsonpath='{.data.token}' | base64 -d; }
