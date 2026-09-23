# Scenario 22: KV-cache-aware routing. Same multi-document workload against the
# default EPP (4 scorers) and a random-picker baseline, on fresh document ranges.
# Prepended with lib/bench.sh.
#   S22_DOCS (150) S22_PREFIX_TOKENS (3000) S22_REQUESTS (900) S22_CONCURRENCY (8)
# Design: DOCS x PREFIX_TOKENS should exceed one pod's KV cache (see vLLM log
# "GPU KV cache size") so that affinity matters.
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
W=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=multi-prefix DOCS="${S22_DOCS:-150}"
   PREFIX_TOKENS="${S22_PREFIX_TOKENS:-3000}" CONCURRENCY="${S22_CONCURRENCY:-8}" REQUESTS="${S22_REQUESTS:-900}" MAX_TOKENS=16)
require_single_epp "$NS"
run() {  # <label> <epp-config-json>
  epp_set "$NS" "$N" "$2"
  local b a s; b=$(pod_counters "$NS")
  s=$(loadgen s22 "${W[@]}" DOC_OFFSET="$(cold_offset)" LABEL="$1")
  sleep 40; a=$(pod_counters "$NS")
  report "$s" "$b" "$a"
}
SCHEME=$(tls_scheme)
say "A) default EPP (queue 2, kv 2, prefix 3, no-hit-lru 2)"
run epp-default "$(epp_default "$SCHEME")"
say "B) baseline: random-picker"
run random-picker '{"apiVersion":"llm-d.ai/v1alpha1","kind":"EndpointPickerConfig","plugins":[{"type":"single-profile-handler"},{"type":"random-picker"},{"type":"metrics-data-source","parameters":{"scheme":"'"$SCHEME"'"}}],"schedulingProfiles":[{"name":"default","plugins":[{"pluginRef":"random-picker"}]}]}'
say "restore"
epp_restore_default "$NS" "$N"
