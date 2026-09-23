# Scenario 25: end-to-end tracing via spec.tracing -> Tempo. Sends traced requests
# (client traceparent) and one rejected request through MaaS, then prints the spans
# per trace from the Tempo query-frontend (port-forward). Prepended with lib/bench.sh.
# Needs 'harness.sh tracing' and 'harness.sh maas-api-key'.
#   S25_REQUESTS (5)  S25_KEEP=true keeps tracing enabled afterwards
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
TNS="${TRACING_NAMESPACE:-openshift-tempo}"
EP="http://tempo-llmd-tracing-distributor.${TNS}.svc.cluster.local:4317"
require_free_gpu
oc get svc tempo-llmd-tracing-query-frontend -n "$TNS" >/dev/null || die "Tempo not installed -- run 'harness.sh tracing'"

say "enable spec.tracing (sampler 1.0) -> $EP"
oc patch llminferenceservice "$N" -n "$NS" --type=merge -p "{\"spec\":{\"tracing\":{\"exporter\":\"otlp\",\"exporterEndpoint\":\"$EP\",\"sampler\":\"parentbased_traceidratio\",\"samplerArg\":\"1.0\"}}}" >/dev/null
sleep 5; wait_isvc "$NS" "$N"
for d in "${N}-kserve" "${N}-kserve-router-scheduler"; do
  oc get deploy "$d" -n "$NS" -o jsonpath="  $d: {.spec.template.spec.containers[0].env[?(@.name==\"OTEL_SERVICE_NAME\")].value}{\"\n\"}"
done

say "traced requests via MaaS"
KEY=$(maas_key); URL="$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')/v1/chat/completions"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')
hex() { "$PY" -c "import secrets;print(secrets.token_hex($1))"; }
IDS=""
send() {  # <max_tokens> <label>
  local tid; tid=$(hex 16)
  local c; c=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$URL" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -H "traceparent: 00-${tid}-$(hex 8)-01" \
    -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":$1,\"messages\":[{\"role\":\"user\",\"content\":\"Write a haiku about GPUs ($2)\"}]}")
  echo "  $2 trace=$tid http=$c"; IDS="$IDS $tid:$2"
}
for i in $(seq 1 "${S25_REQUESTS:-5}"); do send 64 "req$i"; done
send 99999 "rejected"          # exceeds max_model_len -> 400

say "spans (Tempo, port-forward)"
PORT=$((20000 + RANDOM % 10000))
oc port-forward -n "$TNS" svc/tempo-llmd-tracing-query-frontend "$PORT:16686" </dev/null >/dev/null 2>&1 &
PF=$!; sleep 5
echo "  services: $(curl -s "http://localhost:$PORT/api/services")"
sleep 10
for x in $IDS; do
  echo "  -- ${x#*:} (${x%%:*})"
  curl -s "http://localhost:$PORT/api/traces/${x%%:*}" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("data"): print("    (trace not found)"); sys.exit()
t = d["data"][0]; P = t["processes"]; sp = sorted(t["spans"], key=lambda s: s["startTime"]); t0 = sp[0]["startTime"]
keys = ("time_in_queue", "time_in_model_prefill", "time_in_model_decode", "time_to_first_token", "candidate_endpoints")
for s in sp:
    tags = {x["key"].split(".")[-1]: x["value"] for x in s["tags"] if any(k in x["key"] for k in keys)}
    tags = {k: (round(v, 4) if isinstance(v, float) else v) for k, v in tags.items()}
    print("    +%7.1fms %8.1fms %-24s %-30s %s" % ((s["startTime"] - t0) / 1000, s["duration"] / 1000,
          P[s["processID"]]["serviceName"], s["operationName"], tags or ""))'
done
kill "$PF" 2>/dev/null || true

if [ "${S25_KEEP:-false}" != true ]; then
  say "disable tracing"
  oc patch llminferenceservice "$N" -n "$NS" --type=json -p '[{"op":"remove","path":"/spec/tracing"}]' >/dev/null
  sleep 5; wait_isvc "$NS" "$N"; echo "  tracing removed (OTEL env cleaned by controller)"
fi
