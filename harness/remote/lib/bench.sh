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
LOADGEN_VARS="URL MODEL CONCURRENCY REQUESTS DURATION INTERVAL MAX_TOKENS PROMPT_MODE PREFIX_TOKENS DOCS DOC_OFFSET IMAGE_URLS HEADERS LABEL TIMEOUT TIMELINE SESSIONS TURNS SESSION_HEADER PAUSE_AFTER_TURN PAUSE_SECONDS IGNORE_EOS"

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
# LOADGEN_VIA=gateway: the Job resolves the URL host to the MaaS gateway ClusterIP (hostAliases), skipping the
# cloud LB and its 60 s idle timeout (requests that queue longer than 60 s before the first token).
loadgen_start() {
  local name=$1; shift
  (
    for kv in "$@"; do export "$kv"; done
    if [ -z "${URL:-}" ]; then
      URL="$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.url}')/v1/chat/completions"
    fi
    [ -n "${MODEL:-}" ] || MODEL=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.model.name}')
    HOST_ALIASES=""
    if [ "${LOADGEN_VIA:-}" = gateway ]; then
      gw_host=${URL#https://}; gw_host=${gw_host#http://}; gw_host=${gw_host%%/*}
      gw_ip=$(oc get svc -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=${MAAS_GATEWAY:-maas-default-gateway}"         -o jsonpath='{.items[0].spec.clusterIP}')
      [ -n "$gw_ip" ] || die "gateway Service for ${MAAS_GATEWAY:-maas-default-gateway} not found"
      HOST_ALIASES="      hostAliases: [{ip: \"$gw_ip\", hostnames: [\"$gw_host\"]}]"
    fi
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
${HOST_ALIASES}
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
    echo "  loadgen $name -> $URL (model=$MODEL${HOST_ALIASES:+, via gateway ClusterIP})" >&2
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
  # via stdin: a TIMELINE summary exceeds the Windows argv limit ("Argument list too long")
  printf '%s' "$1" | "$PY" -c 'import sys,json; s=json.load(sys.stdin); s.pop("timeline",None); s.pop("errors",None); print("  "+json.dumps(s))'
}

# pd_counters <ns> <name>: P/D vLLM counters as JSON {"prefill": {...}, "decode": {...}}, summed over the pods
# of each role (llm-d.ai/role). prefill vLLM :8000, decode vLLM :8001 (the routing sidecar owns :8000), https.
pd_counters() {
  local ns=$1 n=$2 role port p
  local re='^vllm:(request_success_total|prompt_tokens_total|generation_tokens_total|prefix_cache_hits_total|prefix_cache_queries_total|nixl_xfer_time_seconds_count|nixl_bytes_transferred_sum|nixl_num_failed_transfers_total|nixl_num_kv_expired_reqs_total|num_preemptions_total)'
  for role in prefill decode; do
    port=8000; [ "$role" = decode ] && port=8001
    for p in $(oc get pods -n "$ns" -l "llm-d.ai/role=$role" -o name | grep "/${n}-"); do
      oc exec -n "$ns" "$p" -c main -- curl -sk "https://localhost:$port/metrics" 2>/dev/null | grep -E "$re" | sed "s/^/$role /"
    done
  done | "$PY" -c '
import sys, json, re
out = {"prefill": {}, "decode": {}}
for line in sys.stdin:
    role, rest = line.split(" ", 1); name, val = rest.rsplit(" ", 1)
    k = re.sub(r"\{.*", "", name).replace("vllm:", "")
    out[role][k] = out[role].get(k, 0.0) + float(val)
print(json.dumps(out))'
}
# pd_delta <before-json> <after-json>: one line of counter increments (prefill requests, decode prompt tokens, NIXL)
pd_delta() {
  "$PY" -c '
import sys, json
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
d = {r: {k: b[r].get(k, 0) - a[r].get(k, 0) for k in b[r]} for r in b}
print("prefill_requests=%d prefill_prompt_tokens=%d decode_requests=%d decode_prompt_tokens=%d nixl_xfers=%d nixl_failed=%d" % (
  d["prefill"].get("request_success_total", 0), d["prefill"].get("prompt_tokens_total", 0),
  d["decode"].get("request_success_total", 0), d["decode"].get("prompt_tokens_total", 0),
  d["decode"].get("nixl_xfer_time_seconds_count", 0), d["decode"].get("nixl_num_failed_transfers_total", 0)))' "$1" "$2"
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
# set_replicas <ns> <name> <n>: scale an LLMInferenceService and wait until exactly n workload pods run
set_replicas() {
  local ns=$1 n=$2 r=$3
  [ "$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.spec.replicas}')" = "$r" ] && return
  oc patch llminferenceservice "$n" -n "$ns" --type=merge -p "{\"spec\":{\"replicas\":$r}}" >/dev/null
  sleep 5; wait_isvc "$ns" "$n"
  for _ in $(seq 1 60); do   # terminating pods still report metrics / hold GPUs
    [ "$(oc get pods -n "$ns" -l app.kubernetes.io/component=llminferenceservice-workload --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "$r" ] && break
    sleep 5
  done
  echo "  replicas=$r"
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
# vllm_args <ns> <name> [decode|prefill]: VLLM_ADDITIONAL_ARGS of spec.template or spec.prefill.template
vllm_args() {
  local base=.spec.template; [ "${3:-decode}" = prefill ] && base=.spec.prefill.template
  oc get llminferenceservice "$2" -n "$1" -o jsonpath="{${base}.containers[0].env[?(@.name==\"VLLM_ADDITIONAL_ARGS\")].value}"
}
# set_vllm_flag <ns> <name> <flag> <value|on|default> [decode|prefill|both]: rewrites --<flag>[=<value>] in
# VLLM_ADDITIONAL_ARGS ("on" = flag without value, "default" removes it); one restart via rollout_begin/rollout_end
# ("both" changes decode and prefill together).
set_vllm_flag() {
  local ns=$1 n=$2 f=$3 v=$4 roles=${5:-decode} role cur new patch="[]" changed=""
  [ "$roles" = both ] && roles="decode prefill"
  for role in $roles; do
    cur=$(vllm_args "$ns" "$n" "$role")
    new=$(printf '%s' "$cur" | sed -E "s/ ?--${f}(=[^ ]+)?( |$)/\\2/; s/^ //")
    case $v in default) ;; on) new="$new --${f}" ;; *) new="$new --${f}=$v" ;; esac
    [ "$new" = "$cur" ] && continue
    changed="$changed $role"
    patch=$(oc get llminferenceservice "$n" -n "$ns" -o json | "$PY" -c '
import sys, json
d, role, new, patch = json.load(sys.stdin), sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
base = "/spec/prefill/template" if role == "prefill" else "/spec/template"
spec = d["spec"]["prefill"]["template"] if role == "prefill" else d["spec"]["template"]
i = [e["name"] for e in spec["containers"][0]["env"]].index("VLLM_ADDITIONAL_ARGS")
patch.append({"op": "replace", "path": "%s/containers/0/env/%d/value" % (base, i), "value": new})
print(json.dumps(patch))' "$role" "$new" "$patch")
    echo "  vLLM args ($role) -> $new"
  done
  [ -n "$changed" ] || { echo "  vLLM args unchanged (--$f $v)"; return; }
  rollout_begin "$ns" "$n"
  oc patch llminferenceservice "$n" -n "$ns" --type=json -p "$patch" >/dev/null
  echo "  restart:$changed"
  rollout_end "$ns" "$n"; sleep 5; wait_isvc "$ns" "$n"
}
set_max_num_seqs() { set_vllm_flag "$1" "$2" max-num-seqs "$3"; }
# vllm_args_edit <args> "<flag>=<value|on|default> ..." -> args with each --<flag> rewritten (see set_vllm_flag)
vllm_args_edit() {
  local a=$1 spec f v
  for spec in $2; do
    f=${spec%%=*}; v=${spec#*=}
    if [ "$v" = default ]; then a=$(printf '%s' "$a" | sed -E "s/ ?--${f}(=[^ ]+)?( |$)/\2/; s/^ //"); continue; fi
    [ "$v" = on ] && v="" || v="=$v"
    if printf ' %s ' "$a" | grep -qE " --${f}(=[^ ]+)? "; then   # in place: same flags -> same string, no restart
      a=$(printf '%s' "$a" | sed -E "s/(^| )--${f}(=[^ ]+)?( |$)/\1--${f}${v}\3/")
    else a="$a --${f}${v}"; fi
  done
  printf '%s' "$a"
}
# set_vllm_flags <ns> <name> "<prefill specs>" "<decode specs>": several flags on both P/D roles with ONE
# restart (rollout_begin/rollout_end). Does not wait for Ready: callers check startup (OOM) themselves.
# Prints "changed" or "unchanged".
set_vllm_flags() {
  local ns=$1 n=$2 role cur new patch="[]" changed=""
  for role in prefill decode; do
    cur=$(vllm_args "$ns" "$n" "$role")
    if [ "$role" = prefill ]; then new=$(vllm_args_edit "$cur" "$3"); else new=$(vllm_args_edit "$cur" "$4"); fi
    [ "$new" = "$cur" ] && continue
    changed="$changed $role"
    patch=$(oc get llminferenceservice "$n" -n "$ns" -o json | "$PY" -c '
import sys, json
d, role, new, patch = json.load(sys.stdin), sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
base = "/spec/prefill/template" if role == "prefill" else "/spec/template"
spec = d["spec"]["prefill"]["template"] if role == "prefill" else d["spec"]["template"]
i = [e["name"] for e in spec["containers"][0]["env"]].index("VLLM_ADDITIONAL_ARGS")
patch.append({"op": "replace", "path": "%s/containers/0/env/%d/value" % (base, i), "value": new})
print(json.dumps(patch))' "$role" "$new" "$patch")
    echo "  vLLM args ($role) -> $new" >&2
  done
  [ -n "$changed" ] || { echo unchanged; return; }
  rollout_begin "$ns" "$n" >&2
  oc patch llminferenceservice "$n" -n "$ns" --type=json -p "$patch" >/dev/null
  rollout_end "$ns" "$n" >&2
  echo changed
}
# pd_wait_start <ns> <name> [timeout-s]: wait until prefill + decode vLLM are Ready, or detect a startup
# failure (container restart, CrashLoopBackOff, OOM / no-KV-memory message). Prints "ok" or "fail:<reason>".
pd_wait_start() {
  local ns=$1 n=$2 t=${3:-1800} i p rc logs
  for i in $(seq 1 $((t / 15))); do
    sleep 15
    for p in $(oc get pods -n "$ns" -l 'llm-d.ai/role in (prefill,decode)' -o name 2>/dev/null | grep "/${n}-"); do
      rc=$(oc get "$p" -n "$ns" -o jsonpath='{.status.containerStatuses[?(@.name=="main")].restartCount}' 2>/dev/null)
      logs=$(oc logs "$p" -n "$ns" -c main --tail=200 2>/dev/null | grep -iE 'out of memory|No available memory for the cache blocks|insufficient memory' | tail -1 || true)
      [ -z "$logs" ] && [ -z "$(oc logs "$p" -n "$ns" -c main --previous --tail=200 2>/dev/null | grep -iE 'out of memory|No available memory for the cache blocks|insufficient memory' | tail -1 || true)" ] ||         { echo "fail:${p#pod/}: ${logs:-previous container: out of memory}"; return; }
      [ "${rc:-0}" -gt 0 ] && { echo "fail:${p#pod/}: main restarted $rc times"; return; }
    done
    if [ "$(oc get pods -n "$ns" -l 'llm-d.ai/role in (prefill,decode)' --no-headers 2>/dev/null | grep "^${n}-" | grep -c ' Running ')" -ge 2 ]        && [ "$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]        && ! oc get pods -n "$ns" -l 'llm-d.ai/role in (prefill,decode)' -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="main")].ready} {end}' | grep -q false; then
      echo ok; return
    fi
  done
  echo "fail:not Ready after ${t}s"
}
# ---------- tracing (spec.tracing -> OTel Collector -> multi-tenant Tempo, see remote/tracing.sh) ----------
TRACING_NS="${TRACING_NAMESPACE:-openshift-tempo}"
TRACING_EP="http://llmd-otel-collector.${TRACING_NS}.svc.cluster.local:4317"
TEMPO_Q="https://tempo-llmd-tracing-gateway.${TRACING_NS}.svc.cluster.local:8080/api/traces/v1/${TEMPO_TENANT:-llmd}/tempo/api"
# tracing_enable <ns> <name> [sampler-ratio]: the controller injects OTEL_* into vLLM and EPP
# (rolling restart of the workload -> rollout_begin/rollout_end)
tracing_enable() {
  local ns=$1 n=$2 r=${3:-1.0}
  oc get svc llmd-otel-collector -n "$TRACING_NS" >/dev/null 2>&1 || die "tracing not installed -- run 'harness.sh tracing'"
  [ "$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.spec.tracing.exporterEndpoint} {.spec.tracing.samplerArg}')" = "$TRACING_EP $r" ] \
    && { echo "  tracing already on -> $TRACING_EP (sampler $r)"; return; }
  rollout_begin "$ns" "$n"
  oc patch llminferenceservice "$n" -n "$ns" --type=merge -p "{\"spec\":{\"tracing\":{\"exporter\":\"otlp\",\"exporterEndpoint\":\"$TRACING_EP\",\"sampler\":\"parentbased_traceidratio\",\"samplerArg\":\"$r\"}}}" >/dev/null
  rollout_end "$ns" "$n"; sleep 5; wait_isvc "$ns" "$n"
  for d in "${n}-kserve" "${n}-kserve-router-scheduler"; do
    oc get deploy "$d" -n "$ns" -o jsonpath="  $d: OTEL_SERVICE_NAME={.spec.template.spec.containers[0].env[?(@.name==\"OTEL_SERVICE_NAME\")].value}{\"\n\"}" 2>/dev/null || true
  done
  echo "  tracing on -> $TRACING_EP (sampler $r)"
}
tracing_disable() {
  local ns=$1 n=$2
  [ -n "$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.spec.tracing}')" ] || { echo "  tracing already off"; return; }
  rollout_begin "$ns" "$n"
  oc patch llminferenceservice "$n" -n "$ns" --type=json -p '[{"op":"remove","path":"/spec/tracing"}]' >/dev/null
  rollout_end "$ns" "$n"; sleep 5; wait_isvc "$ns" "$n"; echo "  tracing off (OTEL env removed by controller)"
}
# tempo_get <path>: GET the Tempo API through the multi-tenant gateway (reader SA token, throwaway pod)
tempo_get() {
  local tok; tok=$(oc create token llmd-tracing-reader -n "$TRACING_NS" --duration=10m)
  oc run "tempo-q-$RANDOM" --rm -i --restart=Never -n "$TRACING_NS" --quiet --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
    -- curl -sk -H "Authorization: Bearer $tok" "$TEMPO_Q$1" 2>/dev/null
}
# tempo_services: service names Tempo has received spans from
tempo_services() {
  tempo_get /v2/search/tag/resource.service.name/values \
    | "$PY" -c 'import sys,json; print(" ".join(v["value"] for v in json.load(sys.stdin).get("tagValues", [])) or "(none)")' 2>/dev/null || echo "(query failed)"
}
# tempo_trace <trace-id-hex>: one line per span (offset, duration, service, name, vLLM/EPP timing attributes)
tempo_trace() {
  tempo_get "/traces/$1" | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("    (trace not found)"); sys.exit()
keys = ("time_in_queue", "time_in_model_prefill", "time_in_model_decode", "time_to_first_token", "candidate_endpoints")
rows = []
for b in d.get("batches") or d.get("resourceSpans") or []:
    svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", []) if a["key"] == "service.name"), "?")
    for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
        for sp in ss.get("spans", []):
            t0, t1 = int(sp["startTimeUnixNano"]), int(sp["endTimeUnixNano"])
            tags = {}
            for a in sp.get("attributes", []):
                if any(k in a["key"] for k in keys):
                    v = a["value"]; v = v.get("doubleValue", v.get("intValue", v.get("stringValue")))
                    tags[a["key"].split(".")[-1]] = round(float(v), 4) if isinstance(v, (int, float)) or str(v).replace(".", "", 1).isdigit() else v
            rows.append((t0, t1, svc, sp["name"], tags))
if not rows: print("    (trace not found)"); sys.exit()
rows.sort(); base = rows[0][0]
for t0, t1, svc, name, tags in rows:
    print("    +%7.1fms %8.1fms %-24s %-30s %s" % ((t0 - base) / 1e6, (t1 - t0) / 1e6, svc, name, tags or ""))'
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
# rollout_begin/rollout_end <ns> <name>: wrap a pod-template change of one LLMInferenceService.
# GPU_ROLLOUT=surge (default): require one idle GPU for the maxSurge=1 rollout.
# GPU_ROLLOUT=recreate (SNO profile): with no idle GPU, scale to 0 first and restore afterwards
# (brief outage instead of a rollout that stays Pending forever on a 1-GPU node).
rollout_begin() {
  local ns=$1 n=$2
  ROLLOUT_RESTORE=""; ROLLOUT_RESTORE_PREFILL=""
  # P/D (spec.prefill): pods are usually pinned to one node by hostname, so a cluster-wide idle GPU
  # does not help the surge pod -> always recreate both roles.
  ROLLOUT_RESTORE_PREFILL=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.spec.prefill.replicas}')
  if [ -z "$ROLLOUT_RESTORE_PREFILL" ]; then
    if [ "${GPU_ROLLOUT:-surge}" != recreate ] || [ "$(free_gpus)" -ge 1 ]; then require_free_gpu; return; fi
  fi
  ROLLOUT_RESTORE=$(oc get llminferenceservice "$n" -n "$ns" -o jsonpath='{.spec.replicas}')
  echo "  recreate: $ns/$n replicas ${ROLLOUT_RESTORE:-1}${ROLLOUT_RESTORE_PREFILL:+ (prefill $ROLLOUT_RESTORE_PREFILL)} -> 0 during the change"
  if [ -n "$ROLLOUT_RESTORE_PREFILL" ]; then
    oc patch llminferenceservice "$n" -n "$ns" --type=merge -p '{"spec":{"replicas":0,"prefill":{"replicas":0}}}' >/dev/null
  else
    oc patch llminferenceservice "$n" -n "$ns" --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
  fi
  for _ in $(seq 1 60); do
    [ "$(oc get pods -n "$ns" -l app.kubernetes.io/component=llminferenceservice-workload --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
      && [ "$(oc get pods -n "$ns" -l 'llm-d.ai/role in (prefill,decode)' --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && break
    sleep 5
  done
}
rollout_end() {
  [ -n "${ROLLOUT_RESTORE:-}" ] || return 0
  if [ -n "${ROLLOUT_RESTORE_PREFILL:-}" ]; then
    oc patch llminferenceservice "$2" -n "$1" --type=merge -p "{\"spec\":{\"replicas\":${ROLLOUT_RESTORE},\"prefill\":{\"replicas\":${ROLLOUT_RESTORE_PREFILL}}}}" >/dev/null
  else
    oc patch llminferenceservice "$2" -n "$1" --type=merge -p "{\"spec\":{\"replicas\":${ROLLOUT_RESTORE}}}" >/dev/null
  fi
  echo "  replicas restored to ${ROLLOUT_RESTORE}${ROLLOUT_RESTORE_PREFILL:+ (prefill $ROLLOUT_RESTORE_PREFILL)}"; ROLLOUT_RESTORE=""; ROLLOUT_RESTORE_PREFILL=""
}
# require_token_limit <ns> <name> [min]: MaaS 429s silently turn a benchmark into a rate-limit test
# (hit 2026-09-29: default 100k tokens/h rejected 548/600 requests of scenario 11).
require_token_limit() {
  local ns=$1 n=$2 min=${3:-50000000} lim
  lim=$(oc get maassubscription -A -o json | "$PY" -c '
import sys, json
ns, n = sys.argv[1:3]
ls = [l["limit"] for s in json.load(sys.stdin)["items"] for m in s["spec"].get("modelRefs", [])
      if m.get("name") == n and m.get("namespace") == ns for l in m.get("tokenRateLimits", [])]
print(max(ls) if ls else 0)' "$ns" "$n")
  [ "$lim" -ge "$min" ] || die "MaaS token limit for $ns/$n is $lim/window (< $min). Raise it:
  LLMD_NAMESPACE=$ns LLMD_NAME=$n MAAS_USERS=<users> MAAS_TOKEN_LIMIT=1000000000 ./harness.sh maas-register-model"
}
maas_key() { oc get secret loadgen-token -n "$BENCH_NS" -o jsonpath='{.data.token}' | base64 -d; }
