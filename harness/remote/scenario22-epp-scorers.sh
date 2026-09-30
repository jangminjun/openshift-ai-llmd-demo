# Scenario 22: EPP scorers. Prepended with lib/bench.sh.
#   S22_PARTS "abc kv lru" (default: all three)
#   abc  multi-document workload: A random-picker / B 2 scorers (prefix, queue) / C 4 scorers (3.5.1 default)
#   kv   one pod's KV cache is kept full by long requests sent to it directly (EPP bypassed); new requests
#        via EPP -- where do they go, without / with kv-cache-utilization-scorer. vLLM KV cache is shrunk
#        with --num-gpu-blocks-override so a few requests can fill it (restored afterwards).
#   lru  new documents sent one at a time, then re-read; placement without / with no-hit-lru-scorer
#   S22_DOCS (150) S22_PREFIX_TOKENS (3000) S22_REQUESTS (900) S22_CONCURRENCY (8)
#   S22_KV_BLOCKS (1024 x 16 tokens) S22_KV_PROBE_SECS (120) S22_LRU_DOCS (60)
# Design (abc): DOCS x PREFIX_TOKENS should exceed one pod's KV cache (vLLM log "GPU KV cache size").
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
PARTS=" ${S22_PARTS:-abc kv lru} "
require_single_epp "$NS"
SCHEME=$(tls_scheme)
T=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N")
TWO=(prefix-cache-scorer:3 queue-scorer:2)
THREE_KV=(prefix-cache-scorer:3 queue-scorer:2 kv-cache-utilization-scorer:2)

cfg() {  # <plugin[:weight] ...> -> EndpointPickerConfig JSON (max-score-picker added unless a picker is given)
  "$PY" -c '
import sys, json
scheme, items = sys.argv[1], sys.argv[2:]
plugins, prof = [{"type": "single-profile-handler"}], []
for it in items:
    t, _, w = it.partition(":")
    plugins.append({"type": t}); prof.append({"pluginRef": t, "weight": int(w)} if w else {"pluginRef": t})
if not any(p["pluginRef"].endswith("-picker") for p in prof):
    plugins.append({"type": "max-score-picker"}); prof.append({"pluginRef": "max-score-picker"})
plugins.append({"type": "metrics-data-source", "parameters": {"scheme": scheme}})
print(json.dumps({"apiVersion": "llm-d.ai/v1alpha1", "kind": "EndpointPickerConfig", "plugins": plugins,
                  "schedulingProfiles": [{"name": "default", "plugins": prof}]}))' "$SCHEME" "$@"
}
measure() {  # <label> <loadgen VAR=VAL ...>: one report line (per-pod counters before/after)
  local label=$1 b a s; shift
  b=$(pod_counters "$NS")
  s=$(loadgen s22 "${T[@]}" LABEL="$label" "$@")
  sleep 40; a=$(pod_counters "$NS")
  report "$s" "$b" "$a"
}

if [[ $PARTS == *" abc "* ]]; then
  W=(PROMPT_MODE=multi-prefix DOCS="${S22_DOCS:-150}" PREFIX_TOKENS="${S22_PREFIX_TOKENS:-3000}"
     CONCURRENCY="${S22_CONCURRENCY:-8}" REQUESTS="${S22_REQUESTS:-900}" MAX_TOKENS=16)
  say "abc/A) random-picker"
  epp_set "$NS" "$N" "$(cfg random-picker)"; measure A-random "${W[@]}" DOC_OFFSET="$(cold_offset)"
  say "abc/B) 2 scorers: prefix 3, queue 2"
  epp_set "$NS" "$N" "$(cfg "${TWO[@]}")"; measure B-two "${W[@]}" DOC_OFFSET="$(cold_offset)"
  say "abc/C) 4 scorers: prefix 3, queue 2, kv 2, no-hit-lru 2 (default)"
  epp_set "$NS" "$N" "$(epp_default "$SCHEME")"; measure C-four "${W[@]}" DOC_OFFSET="$(cold_offset)"
fi

if [[ $PARTS == *" kv "* ]]; then
  BLK="${S22_KV_BLOCKS:-1024}"; PROBE="${S22_KV_PROBE_SECS:-120}"
  say "kv) vLLM KV cache -> $BLK blocks ($((BLK * 16)) tokens per pod)"
  set_vllm_flag "$NS" "$N" num-gpu-blocks-override "$BLK"
  trap 'echo "  restoring vLLM KV cache and EPP"; set_vllm_flag "$NS" "$N" num-gpu-blocks-override default; epp_restore_default "$NS" "$N"' EXIT
  # Running pods only: right after the rolling restart the old, terminating pods are still listed
  read -r POD_A IP_A < <(oc get pods -n "$NS" -l app.kubernetes.io/name="$N",kserve.io/component=workload \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} {.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk 'NF == 2' | sort | head -1)
  [ -n "$POD_A" ] || die "no running workload pod found"
  echo "  pod A (kept full, direct requests): $POD_A"
  kv_run() {  # <label> <plugin[:weight] ...>
    local label=$1 b a s fill; shift
    epp_set "$NS" "$N" "$(cfg "$@")"
    # 3 long requests (below --max-num-seqs=4, so pod A never queues and queue-scorer stays neutral)
    loadgen_start s22-fill "${T[@]}" URL="https://${IP_A}:8000/v1/chat/completions" PROMPT_MODE=unique-long \
      PREFIX_TOKENS=2000 MAX_TOKENS=2000 IGNORE_EOS=1 CONCURRENCY=3 DURATION=$((PROBE + 60)) LABEL="fill-$label"
    sleep 45
    local kv_a; kv_a=$(thanos "max(kserve_vllm:kv_cache_usage_perc{namespace=\"$NS\",pod=\"$POD_A\"})" \
      | "$PY" -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)')
    echo "  pod A KV cache usage before probe: $kv_a"
    "$PY" -c 'import sys; sys.exit(float(sys.argv[1]) < 0.5)' "$kv_a" || die "pod A KV cache not filled (filler failed?)"
    b=$(pod_counters "$NS")
    s=$(loadgen s22 "${T[@]}" PROMPT_MODE=multi-prefix DOCS=100000 DOC_OFFSET="$(cold_offset)" PREFIX_TOKENS=300 \
      CONCURRENCY=1 DURATION="$PROBE" MAX_TOKENS=32 LABEL="$label")
    sleep 40; a=$(pod_counters "$NS")
    fill=$(loadgen_wait s22-fill)
    "$PY" -c '
import sys, json
s, b, a, pa, fill = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4], json.loads(sys.argv[5])
to_b = sum(a[p][4] - b.get(p, [0] * 5)[4] for p in a if p != pa)
to_a = s["ok"] - to_b
print("  %-22s new requests -> pod A (full) %d : pod B (free) %d  (%.0f%% to A)  ttft50=%s ttft95=%s  filler ok=%d/%d" % (
    s["label"], to_a, to_b, 100 * to_a / max(s["ok"], 1), s["ttft_p50"], s["ttft_p95"], fill["ok"], fill["n"]))' \
      "$s" "$b" "$a" "$POD_A" "$fill"
    thanos_print "  KV cache usage during probe (mean)" \
      "label_replace(avg_over_time(kserve_vllm:kv_cache_usage_perc{namespace=\"$NS\"}[${PROBE}s]), \"short\", \"\$1\", \"pod\", \".*-([a-z0-9]+)\$\")"
  }
  kv_run kv-without "${TWO[@]}"
  kv_run kv-with "${THREE_KV[@]}"
  kv_run kv-default-four queue-scorer:2 kv-cache-utilization-scorer:2 prefix-cache-scorer:3 no-hit-lru-scorer:2
  say "kv) restore vLLM KV cache"
  set_vllm_flag "$NS" "$N" num-gpu-blocks-override default
  trap - EXIT
fi

if [[ $PARTS == *" lru "* ]]; then
  LD="${S22_LRU_DOCS:-60}"
  lru_run() {  # <label> <plugin[:weight] ...>: phase 1 places LD new docs one by one, phase 2 re-reads them
    local label=$1 off; shift
    epp_set "$NS" "$N" "$(cfg "$@")"; off=$(cold_offset)
    measure "$label-new" PROMPT_MODE=multi-prefix DOC_ORDER=seq DOCS="$LD" REQUESTS="$LD" CONCURRENCY=1 \
      PREFIX_TOKENS=3000 MAX_TOKENS=16 DOC_OFFSET="$off"
    measure "$label-reread" PROMPT_MODE=multi-prefix DOCS="$LD" REQUESTS=$((LD * 5)) CONCURRENCY=8 \
      PREFIX_TOKENS=3000 MAX_TOKENS=16 DOC_OFFSET="$off"
  }
  say "lru) new documents, without / with no-hit-lru-scorer"
  lru_run lru-without "${THREE_KV[@]}"
  lru_run lru-with "${THREE_KV[@]}" no-hit-lru-scorer:2
fi

say "restore"
epp_restore_default "$NS" "$N"
