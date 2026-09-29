# Scenario 25: end-to-end tracing via spec.tracing -> Tempo. Sends traced requests
# (client traceparent) and one rejected request through MaaS, then prints the spans
# per trace from Tempo (multi-tenant gateway). Prepended with lib/bench.sh.
# Needs 'harness.sh tracing' and 'harness.sh maas-api-key'.
#   S25_REQUESTS (5)  S25_KEEP=true keeps tracing enabled afterwards
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
TNS="$TRACING_NS"
say "enable spec.tracing (sampler 1.0) -> $TRACING_EP"
tracing_enable "$NS" "$N" 1.0

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

say "spans (Tempo via gateway)"
sleep 15
echo "  services: $(tempo_services)"
for x in $IDS; do
  echo "  -- ${x#*:} (${x%%:*})"; tempo_trace "${x%%:*}"
done

if [ "${S25_KEEP:-false}" != true ]; then
  say "disable tracing"; tracing_disable "$NS" "$N"
fi
