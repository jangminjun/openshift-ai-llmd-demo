# Scenario 2-07: MaaS token rate limit with long prompts. Temporarily rewrites the
# MaaSSubscription token limits for LLMD_NAMESPACE/LLMD_NAME, fires long requests from an
# in-cluster Job (API key stays in the Secret) and records status, usage and rate-limit headers
# per request. Restores the original limits on exit. Prepended with lib/bench.sh.
#   E1 sequential long requests          -> when the first 429 comes, how long it lasts, headers
#   E2 concurrent burst, then short ones -> overshoot past the limit, collateral 429s
#   E3 streaming without usage           -> are tokens charged when the response carries no usage
#   E4 two-tier limits (15s + 1m)        -> both windows enforced
#   MAAS_RL_ARMS ("E1 E2 E3 E4") MAAS_RL_LIMIT (20000) MAAS_RL_WINDOW (15s) MAAS_RL_LIMIT2 (30000) MAAS_RL_WINDOW2 (1m)
#   MAAS_RL_PROMPT_WORDS (6000, ~12k tokens) MAAS_RL_DURATION (60, E1/E3) MAAS_RL_SUBSCRIPTION (llmd-demo-sub)
# No rate-limit headers are returned on 429 (no Retry-After): the probe retries every 1 s.
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"
SUB="${MAAS_RL_SUBSCRIPTION:-llmd-demo-sub}"; SUBNS="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
L1="${MAAS_RL_LIMIT:-20000}"; W1="${MAAS_RL_WINDOW:-15s}"; L2="${MAAS_RL_LIMIT2:-30000}"; W2="${MAAS_RL_WINDOW2:-1m}"
WORDS="${MAAS_RL_PROMPT_WORDS:-6000}"
oc get secret loadgen-token -n "$BENCH_NS" >/dev/null 2>&1 || die "no MaaS API key: run 'harness.sh maas-api-key'"
IDX=$(oc get maassubscription "$SUB" -n "$SUBNS" -o json | "$PY" -c '
import sys, json
refs = json.load(sys.stdin)["spec"]["modelRefs"]
print(next(i for i, r in enumerate(refs) if r["name"] == sys.argv[1] and r.get("namespace") == sys.argv[2]))' "$N" "$NS") \
  || die "$NS/$N is not in MaaSSubscription $SUBNS/$SUB"
ORIG=$(oc get maassubscription "$SUB" -n "$SUBNS" -o jsonpath="{.spec.modelRefs[$IDX].tokenRateLimits}")
URL="$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')/v1/chat/completions"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')

set_limits() {  # <json list>: patch, then wait for the TokenRateLimitPolicy and Authorino's 60 s cache
  oc patch maassubscription "$SUB" -n "$SUBNS" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/$IDX/tokenRateLimits\",\"value\":$1}]" >/dev/null
  echo "  limits -> $1 (waiting 75 s for policy + cache)"; sleep 75
}
restore() { set_limits "$ORIG" >/dev/null 2>&1; echo "  limits restored -> $ORIG"; }
trap restore EXIT

# probe <label> <pattern> <count> <concurrency> <stream_usage 0|1> [<short_after_seconds>]
probe() {
  oc create configmap rl-probe -n "$BENCH_NS" --from-literal=probe.py="$(cat <<'PYEOF'
import json, os, random, ssl, threading, time, urllib.request, urllib.error
E = os.environ.get; ctx = ssl._create_unverified_context()
W = "cluster gateway router scheduler cache token latency replica model pod node queue policy".split()
def req(words, stream_usage, i):
    rng = random.Random(i * 7919 + int(time.time()))
    body = {"model": E("MODEL"), "max_tokens": 32, "stream": True,
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": " ".join(rng.choice(W) + rng.choice("abcdefghij") for _ in range(words)) + "\nSummarize."}]}
    if stream_usage: body["stream_options"] = {"include_usage": True}
    r = urllib.request.Request(E("URL"), json.dumps(body).encode(),
        {"Authorization": "Bearer " + E("TOKEN"), "Content-Type": "application/json"})
    t0 = time.time(); code = 0; usage = None; hdr = {}
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=300) as resp:
            code = resp.status
            hdr = {k.lower(): v for k, v in resp.getheaders() if "ratelimit" in k.lower() or "retry" in k.lower()}
            for line in resp:
                if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
                    d = json.loads(line[5:]); usage = d.get("usage") or usage
    except urllib.error.HTTPError as e:
        code = e.code; hdr = {k.lower(): v for k, v in e.headers.items() if "ratelimit" in k.lower() or "retry" in k.lower()}
    except Exception as e:
        code = -1; hdr = {"error": str(e)[:120]}
    return {"t": round(t0 - T0, 1), "dur": round(time.time() - t0, 2), "code": code,
            "tokens": usage and usage.get("total_tokens"), "hdr": hdr}
T0 = time.time(); out = []; lock = threading.Lock()
def run(i, words, su):
    x = req(words, su, i)
    with lock: out.append(x); print("REQ " + json.dumps(x), flush=True)
pat, n, c, su = E("PATTERN"), int(E("COUNT")), int(E("CONC")), E("STREAM_USAGE") == "1"
words = int(E("WORDS"))
if pat == "sequential":                   # long requests back to back for DURATION s; 1 s pause after a 429
    end = time.time() + float(E("DURATION", "60")); i = 0
    while time.time() < end:
        run(i, words, su); i += 1
        if out[-1]["code"] == 429: time.sleep(1)
elif pat == "spaced":                     # one long request every INTERVAL s
    for i in range(n): run(i, words, su); time.sleep(float(E("INTERVAL", "5")))
else:                                     # burst: c long requests at once, then short probes
    ts = [threading.Thread(target=run, args=(i, words, su)) for i in range(c)]
    [t.start() for t in ts]; [t.join() for t in ts]
    end = time.time() + float(E("SHORT_AFTER", "0"))
    i = 100
    while time.time() < end: run(i, 20, su); i += 1; time.sleep(1)
PYEOF
)" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc delete job rl-probe -n "$BENCH_NS" --ignore-not-found --wait=true >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: rl-probe, namespace: ${BENCH_NS}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: probe
        image: ${LOADGEN_IMAGE}
        command: ["python3", "-u", "/app/probe.py"]
        env:
        - {name: URL, value: "${URL}"}
        - {name: MODEL, value: "${MODEL}"}
        - {name: PATTERN, value: "$2"}
        - {name: COUNT, value: "$3"}
        - {name: CONC, value: "$4"}
        - {name: STREAM_USAGE, value: "$5"}
        - {name: SHORT_AFTER, value: "${6:-0}"}
        - {name: INTERVAL, value: "${MAAS_RL_INTERVAL:-5}"}
        - {name: WORDS, value: "${WORDS}"}
        - {name: DURATION, value: "${MAAS_RL_DURATION:-60}"}
        - name: TOKEN
          valueFrom: {secretKeyRef: {name: loadgen-token, key: token}}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: s, mountPath: /app}]
      volumes: [{name: s, configMap: {name: rl-probe}}]
YAML
  until [ -n "$(oc get job rl-probe -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]; do sleep 5; done
  oc logs job/rl-probe -n "$BENCH_NS" | sed -n 's/^REQ //p' | "$PY" -c '
import sys, json
rows = sorted((json.loads(l) for l in sys.stdin), key=lambda r: r["t"])
lab = sys.argv[1]; cum = 0; spans = []; start = None
for r in rows:
    if r["code"] == 200 and r["tokens"]: cum += r["tokens"]
    if r["code"] == 429 and start is None: start = r["t"]
    if r["code"] == 200 and start is not None: spans.append((start, r["t"])); start = None
    print("  %-4s t=%6.1fs dur=%5.2fs code=%s tokens=%s cum=%s %s" % (lab, r["t"], r["dur"], r["code"], r["tokens"], cum, json.dumps(r["hdr"]) if r["hdr"] else ""))
ok = sum(r["code"] == 200 for r in rows); lim = sum(r["code"] == 429 for r in rows)
sp = " ".join("%.1f-%.1fs(%.1fs)" % (a, b, b - a) for a, b in spans) + (" %.1f-...(not recovered)" % start if start is not None else "")
print("  %-4s summary: 200=%d 429=%d tokens_ok=%d lockouts=%s" % (lab, ok, lim, cum, sp or "-"))' "$1"
}

for arm in ${MAAS_RL_ARMS:-E1 E2 E3 E4}; do case $arm in
  E1) say "E1 sequential long requests for ${MAAS_RL_DURATION:-60}s, limit $L1/$W1"
      set_limits "[{\"limit\":$L1,\"window\":\"$W1\"}]"; probe E1 sequential 0 1 1 ;;
  E2) say "E2 burst of 4 long requests, then short requests for 30 s, limit $L1/$W1"
      set_limits "[{\"limit\":$L1,\"window\":\"$W1\"}]"; sleep 20; probe E2 burst 4 4 1 30 ;;
  E3) say "E3 streaming WITHOUT usage, limit $L1/$W1"
      set_limits "[{\"limit\":$L1,\"window\":\"$W1\"}]"; sleep 20; probe E3 sequential 0 1 0 ;;
  E4) say "E4 two-tier $L1/$W1 + $L2/$W2, one long request every ${MAAS_RL_INTERVAL:-5}s"
      set_limits "[{\"limit\":$L1,\"window\":\"$W1\"},{\"limit\":$L2,\"window\":\"$W2\"}]"; probe E4 spaced 14 1 1 ;;
esac; done
