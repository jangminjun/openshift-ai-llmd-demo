# Scenario 13: request tracing of a cache miss vs a cache hit on llmd-test (spec.tracing ->
# OTel Collector -> Tempo). Each conversation sends turn 1 (new ~S13_PREFIX_TOKENS document,
# cold) and turn 2 (same document + history, prefix cached) through MaaS with a client
# traceparent, then prints the EPP and vLLM spans of every trace and the prefill/queue
# medians per turn. Prepended with lib/bench.sh. Leaves tracing on.
#   S13_CONVERSATIONS (5)  S13_PREFIX_TOKENS (3000)
NS="${LLMD_NAMESPACE:-llmd-test}"; N="${LLMD_NAME:-llmd-test}"
require_token_limit "$NS" "$N"
say "tracing"
tracing_enable "$NS" "$N" 1.0

say "conversations (turn 1 = cache miss, turn 2 = cache hit)"
URL="$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')/v1/chat/completions"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')
IDS=$(KEY="$(maas_key)" URL="$URL" MODEL="$MODEL" CONV="${S13_CONVERSATIONS:-5}" PREFIX="${S13_PREFIX_TOKENS:-3000}" "$PY" - <<'PYEOF'
import json, os, random, secrets, ssl, time, urllib.request
ctx = ssl._create_unverified_context(); E = os.environ
W = "cluster gateway router scheduler cache token latency replica model pod node queue policy".split()
def send(msgs, tid):
    req = urllib.request.Request(E["URL"], json.dumps({"model": E["MODEL"], "messages": msgs, "max_tokens": 32,
        "stream": True}).encode(), {"Authorization": "Bearer " + E["KEY"], "Content-Type": "application/json",
        "traceparent": "00-%s-%s-01" % (tid, secrets.token_hex(8))})
    out = []
    with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
        for line in r:
            line = line.strip()
            if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
                d = json.loads(line[5:]); c = d.get("choices") and d["choices"][0].get("delta", {}).get("content")
                if c: out.append(c)
    return "".join(out)
seed = int(time.time())
for i in range(int(E["CONV"])):
    rng = random.Random(seed + i)
    hist = [{"role": "system", "content": "Document %d: %s" % (seed + i, " ".join(rng.choice(W) for _ in range(int(E["PREFIX"]))))},
            {"role": "user", "content": "Summarize the text."}]
    t1 = secrets.token_hex(16); a = send(hist, t1)
    hist += [{"role": "assistant", "content": a or "(no answer)"}, {"role": "user", "content": "List three keywords."}]
    t2 = secrets.token_hex(16); send(hist, t2)
    print("%s:c%d-turn1 %s:c%d-turn2" % (t1, i + 1, t2, i + 1), flush=True)
PYEOF
)
echo "$IDS" | tr ' ' '\n' | sed 's/^/  /'

say "spans (Tempo)"
sleep 20
OUT=""
for x in $IDS; do
  echo "  -- ${x#*:} (${x%%:*})"
  t=$(tempo_trace "${x%%:*}"); echo "$t"; OUT="$OUT"$'\n'"${x#*:}"$'\t'"$(echo "$t" | tr '\n' ' ')"
done

say "summary (vLLM span attributes, median per turn)"
printf '%s\n' "$OUT" | "$PY" -c '
import sys, re, statistics as st
v = {}
for line in sys.stdin:
    if "\t" not in line: continue
    label, spans = line.split("\t", 1); turn = label.split("-")[-1]
    for k in ("time_in_queue", "time_in_model_prefill", "time_in_model_decode", "time_to_first_token"):
        m = re.search(r"%s.: ([0-9.]+)" % k, spans)
        if m: v.setdefault((turn, k), []).append(float(m.group(1)))
for turn in ("turn1", "turn2"):
    print("  %s: " % turn + "  ".join("%s=%.3fs(n=%d)" % (k.replace("time_in_model_", "").replace("time_", ""), st.median(x), len(x))
          for (t, k), x in sorted(v.items()) if t == turn) or "  (no vLLM timing attributes)")'
echo "  UI: OpenShift console > Observe > Traces (openshift-tempo/llmd-tracing, tenant llmd)"
