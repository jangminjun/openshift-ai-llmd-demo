# Scenario 23: inference-aware pod lifecycle. Continuous traffic through MaaS while a
# rolling update is triggered (pod template env LLMD_ROLLOUT_ID changes -> new pods load
# weights; EPP must only route to Ready pods). Reports non-200 per phase and pod transitions.
# Prepended with lib/bench.sh.
#   S23_DURATION traffic seconds (default 900; must cover the rollout)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
DUR="${S23_DURATION:-900}"
require_single_epp "$NS"
require_free_gpu
oc get deploy "${N}-kserve" -n "$NS" -o jsonpath='  strategy={.spec.strategy.rollingUpdate} readiness={.spec.template.spec.containers[0].readinessProbe.httpGet.path}/{.spec.template.spec.containers[0].readinessProbe.periodSeconds}s preStop={.spec.template.spec.containers[0].lifecycle.preStop.exec.command}{"\n"}'

WATCH=$(mktemp)
oc get pods -n "$NS" -l kserve.io/component=workload -w --output-watch-events --no-headers </dev/null 2>/dev/null \
  | while read -r ev pod ready status _; do echo "$(date +%s) $ev $pod $ready $status"; done > "$WATCH" &
WPID=$!

say "traffic ${DUR}s (concurrency 2, 0.5s interval)"
loadgen_start s23 LLMD_NAMESPACE="$NS" LLMD_NAME="$N" CONCURRENCY=2 INTERVAL=0.5 DURATION="$DUR" MAX_TOKENS=32 TIMELINE=1 LABEL=rolling-update
T0=$(date +%s); sleep 30

say "rolling update (LLMD_ROLLOUT_ID)"
ENV=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.template.containers[0].env}')
NEWENV=$("$PY" -c '
import sys, json
env = [e for e in json.loads(sys.argv[1]) if e["name"] != "LLMD_ROLLOUT_ID"] + [{"name": "LLMD_ROLLOUT_ID", "value": sys.argv[2]}]
print(json.dumps(env))' "$ENV" "$(date +%s)")
oc patch llminferenceservice "$N" -n "$NS" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/containers/0/env\",\"value\":$NEWENV}]" >/dev/null
T1=$(date +%s); sleep 10
wait_isvc "$NS" "$N"; T2=$(date +%s)
echo "  rollout: $((T2 - T1))s (t=$((T1 - T0))s .. t=$((T2 - T0))s)"
S=$(loadgen_wait s23); kill "$WPID" 2>/dev/null || true
brief "$S"
"$PY" -c '
import sys, json
s = json.loads(sys.argv[1]); t1, t2 = float(sys.argv[2]), float(sys.argv[3]); tl = s["timeline"]
for name, (a, b) in {"before": (0, t1), "rollout": (t1, t2), "after": (t2, 1e9)}.items():
    xs = [c for t, c in tl if a <= t < b]; bad = [(t, c) for t, c in tl if a <= t < b and c != 200]
    print("  %-8s requests=%-5d non-200=%d %s" % (name, len(xs), len(bad), bad[:5]))' "$S" "$((T1 - T0))" "$((T2 - T0))"
echo "  pod transitions (t = seconds from traffic start):"
awk -v t0="$T0" '($5=="Running" && $4=="1/1") || $5=="Terminating" || $2=="DELETED" {k=$3" "$4" "$5; if(!(k in s)){s[k]=1; printf "    t=%-5d %-8s %s %s %s\n", $1-t0, $2, $3, $4, $5}}' "$WATCH"
rm -f "$WATCH"
