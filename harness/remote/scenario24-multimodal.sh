# Scenario 24: multimodal prefix-aware routing on a VLM (deployed by
# 'harness.sh scenario24-llmd-vlm-up'). Seeded images (deterministic per id) re-requested
# several times; default EPP vs random-picker. Prepended with lib/bench.sh.
#   S24_IMAGES (150) S24_REQUESTS (600) S24_SIZE (896 px) S24_CONCURRENCY (8)
NS="${LLMD_NAMESPACE:-llmd-s24}"; N="${LLMD_NAME:-llmd-vlm}"
SIZE="${S24_SIZE:-896}"
W=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=image IMAGE_URLS="https://picsum.photos/seed/llmd{n}/${SIZE}/${SIZE}"
   DOCS="${S24_IMAGES:-150}" CONCURRENCY="${S24_CONCURRENCY:-8}" REQUESTS="${S24_REQUESTS:-600}" MAX_TOKENS=16)
require_single_epp "$NS"
oc get llminferenceservice "$N" -n "$NS" >/dev/null || die "$NS/$N not found -- run 'harness.sh scenario24-llmd-vlm-up' first"
run() {
  epp_set "$NS" "$N" "$2"
  local b a s; b=$(pod_counters "$NS")
  s=$(loadgen s24 "${W[@]}" DOC_OFFSET="$(cold_offset)" LABEL="$1")
  sleep 40; a=$(pod_counters "$NS")
  report "$s" "$b" "$a"
}
SCHEME=$(tls_scheme)
say "A) default EPP"
run epp-default "$(epp_default "$SCHEME")"
say "B) baseline: random-picker"
run random-picker '{"apiVersion":"llm-d.ai/v1alpha1","kind":"EndpointPickerConfig","plugins":[{"type":"single-profile-handler"},{"type":"random-picker"},{"type":"metrics-data-source","parameters":{"scheme":"'"$SCHEME"'"}}],"schedulingProfiles":[{"name":"default","plugins":[{"pluginRef":"random-picker"}]}]}'
say "restore"
epp_restore_default "$NS" "$N"
