# Scenario 28: external tokenizer service. (1) baseRefs the RHOAI tokenizer preset
# (separate Deployment running `vllm launch render`), (2) wires the EPP token-producer to
# it (modelName = the render server's model id, not the served model name), (3) verifies
# render calls, (4) compares external vs built-in tokenization on the same workload.
# Prepended with lib/bench.sh.   S28_REQUESTS (450)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
PRESET="${S28_PRESET:-$(oc get llminferenceserviceconfig -n redhat-ods-applications -o name | sed -n 's#.*/\(v[0-9-]*kserve-config-llm-tokenizer\)$#\1#p' | head -1)}"
W=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=multi-prefix DOCS=150 PREFIX_TOKENS=3000 CONCURRENCY=8 REQUESTS="${S28_REQUESTS:-450}" MAX_TOKENS=16)
require_single_epp "$NS"

say "1) tokenizer service via baseRefs ($PRESET)"
REFS=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.baseRefs[*].name}')
if ! echo "$REFS" | grep -qw "$PRESET"; then   # append, keeping existing baseRefs
  if [ -n "$REFS" ]; then P="[{\"op\":\"add\",\"path\":\"/spec/baseRefs/-\",\"value\":{\"name\":\"$PRESET\"}}]"
  else P="[{\"op\":\"add\",\"path\":\"/spec/baseRefs\",\"value\":[{\"name\":\"$PRESET\"}]}]"; fi
  oc patch llminferenceservice "$N" -n "$NS" --type=json -p "$P" >/dev/null
fi
until oc get deploy "${N}-tokenizer" -n "$NS" &>/dev/null; do sleep 5; done
oc rollout status "deploy/${N}-tokenizer" -n "$NS" --timeout=900s >/dev/null
oc get deploy "${N}-tokenizer" -n "$NS" -o jsonpath='  {.metadata.name}: {.spec.template.spec.containers[0].resources.requests}{"\n"}'
RENDER_MODEL=$(oc get deploy "${N}-tokenizer" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -oE 'render [^ \\"]+' | head -1 | cut -d' ' -f2)
SCHEME=$(tls_scheme)
echo "  render model id: $RENDER_MODEL  scheme: $SCHEME"

say "2) EPP token-producer -> ${SCHEME}://${N}-tokenizer.${NS}.svc:8000"
# model id via stdin: as an argv it would be rewritten by Git Bash in local mode
CFG=$(printf '%s' "$RENDER_MODEL" | "$PY" -c '
import sys, json
c = json.loads(sys.argv[1])
c["plugins"].append({"type": "token-producer", "parameters": {"modelName": sys.stdin.read().strip(), "vllm": {"url": sys.argv[2]}}})
print(json.dumps(c))' "$(epp_default "$SCHEME")" "${SCHEME}://${N}-tokenizer.${NS}.svc.cluster.local:8000")
epp_set "$NS" "$N" "$CFG"

say "3) verify render calls"
loadgen s28 "${W[@]}" DOCS=3 PREFIX_TOKENS=500 REQUESTS=10 CONCURRENCY=2 LABEL=probe >/dev/null
echo "  render responses: $(oc logs -n "$NS" "deploy/${N}-tokenizer" --since=2m | grep -oE '"POST /v1/(chat/)?completions/render[^"]*" [0-9]+' | awk '{print $NF}' | sort | uniq -c | tr '\n' ' ')"
echo "  prefix-scorer misses: $(oc logs -n "$NS" "deploy/${N}-kserve-router-scheduler" --since=2m | grep -c 'PrefixCacheMatchInfo not found')"

run() {
  local b a s; b=$(pod_counters "$NS")
  s=$(loadgen s28 "${W[@]}" DOC_OFFSET="$(cold_offset)" LABEL="$1"); sleep 40; a=$(pod_counters "$NS")
  report "$s" "$b" "$a"
  thanos_print "token-producer latency p95 (s)" "histogram_quantile(0.95, sum by (le, plugin_type)(rate(llm_d_epp_plugin_duration_seconds_bucket{namespace=\"$NS\",plugin_type=\"token-producer\"}[5m])))"
}
say "4a) external tokenizer"; run external-tokenizer
say "4b) built-in token estimation"; epp_restore_default "$NS" "$N"; run builtin
echo "  (tokenizer Deployment kept via baseRefs; EPP back on default config)"
