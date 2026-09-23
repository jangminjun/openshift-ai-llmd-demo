# MaaS gateway checks found while running the llm-d scenarios. Prepended with lib/bench.sh.
#   MAAS_CHECK=nonstream   N non-streaming + N streaming requests; counts HTTP 200 with empty body
#                          (Kuadrant wasm-shim loses non-streamed bodies, lessonlearn.md 2026-09-23)
#   MAAS_CHECK=token-limit temporarily sets the model's token limit (MAAS_CHECK_LIMIT/1m), waits for a
#                          fresh window, sends streaming and non-streaming requests until 429, restores.
#   MAAS_CHECK_N (20)  MAAS_GROUP (llmd-demo)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
KEY=$(maas_key) || die "no API key -- run 'harness.sh maas-api-key'"
URL="$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')/v1/chat/completions"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')
req() {  # <stream:true|false> <max_tokens> <i> -> "code bytes total_tokens"
  local out opts=""; out=$(mktemp)
  [ "$1" = true ] && opts='"stream_options":{"include_usage":true},'   # only valid with stream=true
  local c; c=$(curl -skN -o "$out" -w '%{http_code}' -X POST "$URL" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"stream\":$1,$opts\"max_tokens\":$2,\"messages\":[{\"role\":\"user\",\"content\":\"Write a short story $3\"}]}" 2>/dev/null \
    || true)
  echo "$c $(wc -c < "$out") $(grep -oE '"total_tokens":[0-9]+' "$out" | tail -1 | cut -d: -f2)"
  rm -f "$out"
}
case "${MAAS_CHECK:-nonstream}" in
nonstream)
  say "non-streaming vs streaming body check ($URL)"
  for s in false true; do
    ok=0; empty=0; other=0
    for i in $(seq 1 "${MAAS_CHECK_N:-20}"); do
      read -r c b _ <<< "$(req $s 16 "$i")"
      if [ "$c" = 200 ] && [ "$b" -gt 0 ]; then ok=$((ok+1)); elif [ "$c" = 200 ]; then empty=$((empty+1)); else other=$((other+1)); fi
    done
    echo "  stream=$s: body_ok=$ok empty_200=$empty non_200=$other"
  done ;;
token-limit)
  LIMIT="${MAAS_CHECK_LIMIT:-300}"; SUB="${MAAS_GROUP:-llmd-demo}-sub"; TNS=models-as-a-service
  idx=$(oc get maassubscription "$SUB" -n "$TNS" -o jsonpath='{range .spec.modelRefs[*]}{.namespace}/{.name}{"\n"}{end}' | grep -nx "$NS/$N" | cut -d: -f1)
  [ -n "$idx" ] || die "$NS/$N not in $SUB"
  ORIG=$(oc get maassubscription "$SUB" -n "$TNS" -o jsonpath="{.spec.modelRefs[$((idx - 1))].tokenRateLimits}")
  setlim() { oc patch maassubscription "$SUB" -n "$TNS" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/$((idx - 1))/tokenRateLimits\",\"value\":$1}]" >/dev/null; }
  trap 'setlim "$ORIG"; echo "  restored limit $ORIG"' EXIT
  say "token limit ${LIMIT}/1m on $NS/$N (original $ORIG)"
  setlim "[{\"limit\":$LIMIT,\"window\":\"1m\"}]"; sleep 70
  for s in true false; do
    until [ "$(req true 1 x | cut -d' ' -f1)" = 200 ]; do sleep 5; done   # fresh window
    tot=0; line=""
    for i in $(seq 1 12); do
      read -r c _ t <<< "$(req $s 100 "$i")"; tot=$((tot + ${t:-0})); line="$line $c"
      [ "$c" = 429 ] && break
    done
    echo "  stream=$s: codes:$line | tokens before 429 = $tot (limit $LIMIT)"
    sleep 65
  done ;;
*) die "MAAS_CHECK must be nonstream|token-limit" ;;
esac
