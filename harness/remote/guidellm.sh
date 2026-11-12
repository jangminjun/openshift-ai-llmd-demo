#!/usr/bin/env bash
# GuideLLM benchmark against one LLMInferenceService, as an in-cluster Job (namespace llmd-bench).
# Builds the scenario from the model (served name, hf:// tokenizer, target URL), runs
# ghcr.io/vllm-project/guidellm, prints the latency / throughput tables and copies
# benchmarks.json / benchmarks.csv to GUIDELLM_OUT/<run-id>. Same resources as
# manifests/guidellm/guidellm-job.yaml. Runs on the bastion or locally (HARNESS_EXEC).
#   LLMD_NAMESPACE / LLMD_NAME     target model (default llmd-test/llmd-test)
#   GUIDELLM_VIA      direct (workload Service, no MaaS/EPP) | maas (status.url + API key, through EPP)
#                     | gateway (as maas, but the Job resolves the MaaS host to the gateway ClusterIP via
#                       hostAliases: skips the cloud LB and its 60 s idle timeout; same URL/SNI/HTTPRoute)
#   GUIDELLM_PROFILE  concurrent | constant | poisson | sweep | synchronous | throughput (concurrent)
#   GUIDELLM_STREAMS  concurrency levels for concurrent ("1,4,8,16")
#   GUIDELLM_RATES    req/s levels for constant / poisson ("1,2,4")
#   GUIDELLM_PROMPT_TOKENS (1000)  GUIDELLM_OUTPUT_TOKENS (256)  GUIDELLM_MAX_SECONDS per level (60)
#   GUIDELLM_SCENARIO builtin base, e.g. rhaiis/concurrent-1k-1k-equal (overrides data/profile/levels)
#   GUIDELLM_TOKENIZER (hf repo id; default from spec.model.uri hf://...)
#   GUIDELLM_EXTRA_BODY JSON merged into every request ('{"chat_template_kwargs":{"enable_thinking":false}}')
#   GUIDELLM_IMAGE (ghcr.io/vllm-project/guidellm:v0.8.1)  GUIDELLM_OUT (./results/guidellm)
set -euo pipefail
# Bastion: use the installer kubeconfig. Local (HARNESS_EXEC=local): keep the current oc session.
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig" || true
PY=python3; python3 -c 'pass' 2>/dev/null || PY=python

NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"; BNS="${LOADGEN_NAMESPACE:-llmd-bench}"
VIA="${GUIDELLM_VIA:-direct}"; IMAGE="${GUIDELLM_IMAGE:-ghcr.io/vllm-project/guidellm:v0.8.1}"
RUN="${GUIDELLM_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$N}"; OUT="${GUIDELLM_OUT:-$PWD/results/guidellm}"
die() { echo "ERROR: $*" >&2; exit 1; }

oc get llminferenceservice "$N" -n "$NS" >/dev/null 2>&1 || die "LLMInferenceService $NS/$N not found"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')
URI=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.uri}')
TOKENIZER="${GUIDELLM_TOKENIZER:-${URI#hf://}}"
case "$VIA" in
  direct) TARGET="https://${N}-kserve-workload-svc.${NS}.svc.cluster.local:8000" ;;
  maas|gateway)
          TARGET=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')
          oc get secret loadgen-token -n "$BNS" >/dev/null 2>&1 \
            || die "no MaaS API key: run 'harness.sh maas-register-model' and 'harness.sh maas-api-key'" ;;
  *) die "GUIDELLM_VIA must be direct, maas or gateway" ;;
esac
HOST_ALIASES=""
if [ "$VIA" = gateway ]; then
  GW_HOST=${TARGET#https://}; GW_HOST=${GW_HOST%%/*}
  GW_IP=$(oc get svc -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=${MAAS_GATEWAY:-maas-default-gateway}" \
    -o jsonpath='{.items[0].spec.clusterIP}')
  [ -n "$GW_IP" ] || die "gateway Service for ${MAAS_GATEWAY:-maas-default-gateway} not found"
  HOST_ALIASES="      hostAliases: [{ip: \"$GW_IP\", hostnames: [\"$GW_HOST\"]}]"
  echo "   $GW_HOST -> $GW_IP (gateway ClusterIP, no cloud LB)"
fi
echo "== GuideLLM $RUN: $NS/$N ($MODEL) via $VIA -> $TARGET"

oc get namespace "$BNS" >/dev/null 2>&1 || oc create namespace "$BNS" >/dev/null
SCEN=$(TARGET="$TARGET" MODEL="$MODEL" TOKENIZER="$TOKENIZER" "$PY" - <<'PYEOF'
import json, os
E = os.environ.get
extra = json.loads(E("GUIDELLM_EXTRA_BODY") or '{"chat_template_kwargs":{"enable_thinking":false}}')
backend = {"kind": "openai_http", "target": E("TARGET"), "model": E("MODEL"),
           "request_format": "/v1/chat/completions", "verify": False}
if extra:
    backend["extras"] = {"body": extra}
spec = {"backend": backend, "tokenizer": {"kind": "huggingface_auto", "model": E("TOKENIZER")}}
s = {"metadata": {"name": E("GUIDELLM_SCENARIO") or "harness"}, "spec": spec}
if E("GUIDELLM_SCENARIO"):
    s["base"] = E("GUIDELLM_SCENARIO")          # builtin: data/profile/levels come from it
else:
    kind = E("GUIDELLM_PROFILE") or "concurrent"
    spec["profile"] = {"kind": kind}
    spec["data"] = [{"kind": "synthetic_text", "prompt_tokens": int(E("GUIDELLM_PROMPT_TOKENS") or 1000),
                     "output_tokens": int(E("GUIDELLM_OUTPUT_TOKENS") or 256)}]
    spec["constraints"] = [{"kind": "max_duration", "seconds": int(E("GUIDELLM_MAX_SECONDS") or 60)}]
    if kind == "concurrent":
        s["benchmarks"] = [{"profile.streams": int(x)} for x in (E("GUIDELLM_STREAMS") or "1,4,8,16").split(",")]
    elif kind in ("constant", "poisson"):
        s["benchmarks"] = [{"profile.rate": float(x)} for x in (E("GUIDELLM_RATES") or "1,2,4").split(",")]
print(json.dumps(s))
PYEOF
)
oc create configmap guidellm-scenario -n "$BNS" --from-literal=scenario.json="$SCEN" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc apply -n "$BNS" -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: guidellm-results}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
YAML
oc delete job guidellm -n "$BNS" --ignore-not-found --wait=true >/dev/null
oc apply -n "$BNS" -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: guidellm}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
${HOST_ALIASES}
      containers:
      - name: guidellm
        image: ${IMAGE}
        command:
        - sh
        - -c
        - |
          python3 - <<'PY'
          import json, os
          s = json.load(open("/cfg/scenario.json"))
          base = s.pop("base", None)
          if base:   # builtin scenario: keep its data/profile/levels, replace backend + tokenizer
              import guidellm, glob
              f = glob.glob(os.path.join(os.path.dirname(guidellm.__file__), "**", base + ".json"), recursive=True)
              b = json.load(open(f[0])); b["spec"].update(s["spec"]); s = b
          if os.environ.get("API_KEY"):
              s["spec"]["backend"]["api_key"] = os.environ["API_KEY"]
          json.dump(s, open("/tmp/scenario.json", "w"))
          PY
          guidellm run --scenario /tmp/scenario.json --disable-console-interactive
        env:
        - {name: GUIDELLM__DEFAULT_RESULTS_DIR, value: /results/${RUN}}
        - {name: HF_HOME, value: /tmp/hf}
        - {name: COLUMNS, value: "220"}
$( [ "$VIA" != direct ] && printf '        - name: API_KEY\n          valueFrom: {secretKeyRef: {name: loadgen-token, key: token}}\n' )
        resources:
          requests: {cpu: "2", memory: 4Gi}
          limits: {cpu: "4", memory: 8Gi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: cfg, mountPath: /cfg}, {name: results, mountPath: /results}]
      volumes:
      - {name: cfg, configMap: {name: guidellm-scenario}}
      - {name: results, persistentVolumeClaim: {claimName: guidellm-results}}
YAML

echo "  job guidellm started (oc logs -f job/guidellm -n $BNS)"
until [ -n "$(oc get job guidellm -n "$BNS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]; do sleep 10; done
LOG=$(oc logs job/guidellm -n "$BNS" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
[ "$(oc get job guidellm -n "$BNS" -o jsonpath='{.status.succeeded}')" = 1 ] || { echo "$LOG" | tail -30; die "guidellm job failed"; }
printf '%s\n' "$LOG" | awk '/Request Latency Statistics|Server Throughput Statistics/{p=1} /^Warnings|Benchmarking complete/{p=0} p'

# copy results out through a short-lived reader pod on the same PVC
oc delete pod guidellm-results -n "$BNS" --ignore-not-found --wait=true >/dev/null
oc run guidellm-results -n "$BNS" --image="$IMAGE" --restart=Never --command \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"guidellm-results","image":"'"$IMAGE"'","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"r","mountPath":"/results"}]}],"volumes":[{"name":"r","persistentVolumeClaim":{"claimName":"guidellm-results"}}]}}' \
  -- sleep 300 >/dev/null
oc wait --for=condition=Ready "pod/guidellm-results" -n "$BNS" --timeout=180s >/dev/null
mkdir -p "$OUT"
# Git Bash: relative destination (an absolute "C:/..." is parsed as <pod>:<path>) and no path conversion of the source
for i in 1 2 3; do   # oc cp drops large files now and then ("unexpected EOF")
  rm -rf "${OUT:?}/$RUN"
  (cd "$OUT" && MSYS_NO_PATHCONV=1 oc cp "$BNS/guidellm-results:/results/$RUN" "$RUN" >/dev/null) && break
  echo "  oc cp failed (try $i), retrying"; sleep 5
done
oc delete pod guidellm-results -n "$BNS" --wait=false >/dev/null
echo "  results: $OUT/$RUN ($(ls "$OUT/$RUN" | tr '\n' ' '))"
