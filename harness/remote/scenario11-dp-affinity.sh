# Scenario 11: data parallelism x routing. The same multi-turn workload (one long document
# per conversation, history resent every turn) against:
#   A) replica 1, default EPP                 (before: single GPU)
#   B) replica 2, workload Service            (DP with cache-unaware connection balancing)
#   C) replica 2, default EPP                 (DP + prefix-cache-aware routing)
#   D) replica 2, EPP + session-affinity-scorer  (sticky by x-session-token, still load-balanced)
#   E) replica 2, EPP + session-affinity-filter  (hard sticky)
#   F0/F1/F2) EPP restart between turn 1 and turn 2 (the EPP keeps its prefix index in memory):
#     F0 default EPP, no restart (control)  F1 default EPP, restart  F2 + session-affinity-scorer, restart
#     prefix hit is reported for turns 2..N only (counters snapshotted during the pause).
# Prepended with lib/bench.sh. Restores replicas and the default EPP config.
#   S11_SESSIONS (200) S11_TURNS (3) S11_PREFIX_TOKENS (3000) S11_CONCURRENCY (16) S11_MAX_TOKENS (32)
#   S11_AFFINITY_WEIGHT (3)  S11_ARMS ("A B C D E"; F0 F1 F2 on request)  S11_PAUSE (180)
# Design: SESSIONS x (PREFIX_TOKENS + history) should exceed one pod's KV cache (vLLM log
# "GPU KV cache size") and CONCURRENCY should exceed --max-num-seqs so replica 1 saturates.
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
W=(PROMPT_MODE=multi-turn SESSIONS="${S11_SESSIONS:-200}" TURNS="${S11_TURNS:-3}"
   PREFIX_TOKENS="${S11_PREFIX_TOKENS:-3000}" CONCURRENCY="${S11_CONCURRENCY:-16}" MAX_TOKENS="${S11_MAX_TOKENS:-32}")
SVC_URL="https://${N}-kserve-workload-svc.${NS}.svc.cluster.local:8000/v1/chat/completions"
require_single_epp "$NS"
require_token_limit "$NS" "$N"
ORIG=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.replicas}')
SCHEME=$(tls_scheme)

set_replicas() {
  [ "$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.replicas}')" = "$1" ] && return
  oc patch llminferenceservice "$N" -n "$NS" --type=merge -p "{\"spec\":{\"replicas\":$1}}" >/dev/null
  sleep 5; wait_isvc "$NS" "$N"
  for _ in $(seq 1 60); do   # terminating pods still report metrics / hold GPUs
    [ "$(oc get pods -n "$NS" -l app.kubernetes.io/component=llminferenceservice-workload --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "$1" ] && break
    sleep 5
  done
  echo "  replicas=$1"
}
# epp_with <extra-plugin-json> <profile-entry-json> <first|last>: default config + one plugin
epp_with() {
  "$PY" -c '
import sys, json
c = json.loads(sys.argv[1]); c["plugins"].insert(0, json.loads(sys.argv[2]))
prof = c["schedulingProfiles"][0]["plugins"]; e = json.loads(sys.argv[3])
prof.insert(0, e) if sys.argv[4] == "first" else prof.insert(len(prof) - 1, e)
print(json.dumps(c))' "$(epp_default "$SCHEME")" "$@"
}
run() {  # <label> [URL=...]
  local label=$1 b a s; shift
  b=$(pod_counters "$NS")
  s=$(loadgen s11 LLMD_NAMESPACE="$NS" LLMD_NAME="$N" "${W[@]}" DOC_OFFSET="$(cold_offset)" LABEL="$label" "$@")
  sleep 40; a=$(pod_counters "$NS")
  report "$s" "$b" "$a"
  "$PY" -c 'import sys,json; s=json.loads(sys.argv[1]); print("  %-24s ttft50 turn1=%s later=%s session_token_resp=%s" % ("", s.get("ttft_p50_turn1"), s.get("ttft_p50_later"), s.get("session_token_resp")))' "$s"
}

# run_restart <label> <restart:true|false>: pause after turn 1, optionally delete the EPP pod, then
# continue the same conversations. Counters are taken during the pause -> hit rate of turns 2..N.
run_restart() {
  local label=$1 restart=$2 m a s pod
  loadgen_start s11 LLMD_NAMESPACE="$NS" LLMD_NAME="$N" "${W[@]}" DOC_OFFSET="$(cold_offset)" LABEL="$label" \
    PAUSE_AFTER_TURN=1 PAUSE_SECONDS="${S11_PAUSE:-180}"
  until oc logs job/s11 -n "$BENCH_NS" 2>/dev/null | grep -q PHASE_PAUSE; do
    [ -n "$(oc get job s11 -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}')" ] && die "loadgen s11 ended before PHASE_PAUSE"
    sleep 5
  done
  sleep 40; m=$(pod_counters "$NS")          # scrape interval 30s
  if [ "$restart" = true ]; then
    pod=$(oc get pods -n "$NS" -l app.kubernetes.io/component=llminferenceservice-router-scheduler -o name)
    oc delete "$pod" -n "$NS" --wait=false >/dev/null
    oc wait --for=delete "$pod" -n "$NS" --timeout=120s >/dev/null 2>&1 || true
    oc rollout status "deploy/${N}-kserve-router-scheduler" -n "$NS" --timeout=120s >/dev/null
    echo "  EPP restarted during pause ($pod)"
  fi
  s=$(loadgen_wait s11); sleep 40; a=$(pod_counters "$NS")
  report "$s" "$m" "$a"
  "$PY" -c 'import sys,json; s=json.loads(sys.argv[1]); print("  %-24s (prefix_hit/split = turns 2..N) ttft50 turn1=%s later=%s session_token_resp=%s" % ("", s.get("ttft_p50_turn1"), s.get("ttft_p50_later"), s.get("session_token_resp")))' "$s"
}

for arm in ${S11_ARMS:-A B C D E}; do case $arm in
  A) say "A) replica 1, default EPP (before)"
     set_replicas 1; epp_set "$NS" "$N" "$(epp_default "$SCHEME")"; run r1-epp ;;
  B) say "B) replica 2, workload Service (cache-unaware)"
     set_replicas 2; run r2-service URL="$SVC_URL" ;;
  C) say "C) replica 2, default EPP"
     set_replicas 2; epp_set "$NS" "$N" "$(epp_default "$SCHEME")"; run r2-epp ;;
  D) say "D) replica 2, EPP + session-affinity-scorer (weight ${S11_AFFINITY_WEIGHT:-3})"
     set_replicas 2
     # Build JSON args outside "$(...)": nested \" there lets brace expansion split the value.
     entry='{"pluginRef":"session-affinity-scorer","weight":'"${S11_AFFINITY_WEIGHT:-3}"'}'
     cfg=$(epp_with '{"type":"session-affinity-scorer"}' "$entry" last)
     epp_set "$NS" "$N" "$cfg"
     run r2-affinity-scorer ;;
  E) say "E) replica 2, EPP + session-affinity-filter"
     set_replicas 2
     cfg=$(epp_with '{"type":"session-affinity-filter"}' '{"pluginRef":"session-affinity-filter"}' first)
     epp_set "$NS" "$N" "$cfg"
     run r2-affinity-filter ;;
  F0|F1) restart=false; [ "$arm" = F1 ] && restart=true
     say "$arm) replica 2, default EPP, EPP restart between turns: $restart"
     set_replicas 2; epp_set "$NS" "$N" "$(epp_default "$SCHEME")"; run_restart "r2-epp-restart-$restart" "$restart" ;;
  F2) say "F2) replica 2, EPP + session-affinity-scorer, EPP restart between turns"
     set_replicas 2
     entry='{"pluginRef":"session-affinity-scorer","weight":'"${S11_AFFINITY_WEIGHT:-3}"'}'
     cfg=$(epp_with '{"type":"session-affinity-scorer"}' "$entry" last)
     epp_set "$NS" "$N" "$cfg"; run_restart r2-affinity-restart true ;;
esac; done

say "restore"
set_replicas "$ORIG"
epp_restore_default "$NS" "$N"
