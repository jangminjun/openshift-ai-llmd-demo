# Scenario 2-04: P/D decider threshold. For each threshold of the EPP pd-profile-handler, sends short (~20 tokens)
# and long (~2k tokens, unique) prompts through MaaS and counts how many reached the prefill pod (prefill
# request_success) and how much the decode pod computed locally (decode prompt tokens). Restores the original
# EPP config on exit. Prepended with lib/bench.sh.
#   S24_THRESHOLDS ("0 1000")  pd-profile-handler threshold (uncached prompt tokens); 0 = always disaggregate
#   S24_REQUESTS (20)          requests per prompt size     S24_LONG_WORDS (1000, ~2k tokens)
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"
EPP_ORIG=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.router.scheduler.config.inline}')
[ -n "$EPP_ORIG" ] || die "$NS/$N has no inline EPP config"
trap 'epp_set "$NS" "$N" "$EPP_ORIG"; echo "  EPP config restored"' EXIT

epp_with_threshold() {  # <threshold> -> the original inline config with pd-profile-handler.threshold replaced
  printf '%s' "$EPP_ORIG" | "$PY" -c '
import sys, json
c = json.load(sys.stdin)
for p in c["plugins"]:
    if p["type"] == "pd-profile-handler":
        p.setdefault("parameters", {})["threshold"] = int(sys.argv[1])
print(json.dumps(c))' "$1"
}

for th in ${S24_THRESHOLDS:-0 1000}; do
  say "threshold $th"
  epp_set "$NS" "$N" "$(epp_with_threshold "$th")"
  oc logs "deploy/${N}-kserve-router-scheduler" -n "$NS" 2>/dev/null | grep 'Effective raw configuration' | tail -1 \
    | grep -oE 'Name: [a-z-]*(decider|profile-handler)[^}]*}' | sed 's/^/  EPP: /'
  for kind in short long; do
    if [ $kind = short ]; then mode=short; else mode=unique-long; fi
    before=$(pd_counters "$NS" "$N")
    sum=$(loadgen "s24-$kind" LLMD_NAMESPACE="$NS" LLMD_NAME="$N" PROMPT_MODE=$mode PREFIX_TOKENS="${S24_LONG_WORDS:-1000}" \
      REQUESTS="${S24_REQUESTS:-20}" CONCURRENCY=1 MAX_TOKENS=16)
    after=$(pd_counters "$NS" "$N")
    printf '  %-5s %s\n' "$kind" "$(pd_delta "$before" "$after")"
    printf '  %-5s %s\n' "$kind" "$(printf '%s' "$sum" | "$PY" -c 'import sys,json; s=json.load(sys.stdin); print("ok=%s ttft_p50=%s ttft_p95=%s" % (s.get("ok"), s.get("ttft_p50"), s.get("ttft_p95")))')"
  done
done
