# Scenario 27: scorer-weight policies x workloads. Prepended with lib/bench.sh.
#   P1 cache-first (prefix 5, queue 1, kv 1, lru 1)   P2 load-first (prefix 1, queue 3, kv 3, lru 1)
#   W1 many documents (affinity pays)   W2 unique long prompts (no cache signal)
#   W3 one hot document, 16 concurrent (needs a vLLM queue to show load signals)
#   S27_WORKLOADS ("W1 W2 W3")  S27_MAX_NUM_SEQS (4; queue forms for W3, "default" = vLLM default)
#   S27_SCALE (1.0) multiplies request counts / durations for quick checks
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
SC="${S27_SCALE:-1.0}"; sc() { "$PY" -c "print(max(1, int($1 * $SC)))"; }
require_single_epp "$NS"
set_max_num_seqs "$NS" "$N" "${S27_MAX_NUM_SEQS:-4}"
T=(LLMD_NAMESPACE="$NS" LLMD_NAME="$N")
wl() { case $1 in
  W1) echo "PROMPT_MODE=multi-prefix DOCS=150 PREFIX_TOKENS=3000 CONCURRENCY=8 REQUESTS=$(sc 450) MAX_TOKENS=16" ;;
  W2) echo "PROMPT_MODE=unique-long PREFIX_TOKENS=1500 CONCURRENCY=16 DURATION=$(sc 90) MAX_TOKENS=128" ;;
  W3) echo "PROMPT_MODE=multi-prefix DOCS=1 PREFIX_TOKENS=3000 CONCURRENCY=16 DURATION=$(sc 90) MAX_TOKENS=128" ;;
esac; }
policy() {  # prefix queue kv lru
  "$PY" -c '
import sys, json
c = json.loads(sys.argv[1]); w = dict(zip(["prefix-cache-scorer", "queue-scorer", "kv-cache-utilization-scorer", "no-hit-lru-scorer"], map(int, sys.argv[2:6])))
for p in c["schedulingProfiles"][0]["plugins"]:
    if p["pluginRef"] in w: p["weight"] = w[p["pluginRef"]]
print(json.dumps(c))' "$(epp_default "$(tls_scheme)")" "$@"
}
for P in "P1 5 1 1 1" "P2 1 3 3 1"; do
  set -- $P; name=$1; shift
  say "$name policy (prefix=$1 queue=$2 kv=$3 lru=$4)"
  epp_set "$NS" "$N" "$(policy "$@")"
  for w in ${S27_WORKLOADS:-W1 W2 W3}; do
    b=$(pod_counters "$NS")
    # shellcheck disable=SC2046
    s=$(loadgen s27 "${T[@]}" $(wl "$w") DOC_OFFSET="$(cold_offset)" LABEL="$name-$w")
    sleep 40; a=$(pod_counters "$NS"); report "$s" "$b" "$a"
  done
done
say "restore"
epp_restore_default "$NS" "$N"
