# Scenario 2-08: root cause and mitigations of 429s after long-prompt calls behind MaaS token limits.
# Temporarily rewrites MaaSSubscription token limits (and vLLM prefill flags for prefix/chunk), runs a
# workload plan from an in-cluster Job (API keys stay in Secrets) and restores everything on exit.
# Prepended with lib/bench.sh. Arms (MAAS_MIT_ARMS, docs/scenarios-2/08-*):
#   single    H1  one request larger than the window limit, then a short probe           (08)
#   io        H2  input-heavy vs output-heavy requests: both charged as total_tokens       (08)
#   saturate  H3  no token limit, long requests at high concurrency: who returns 429?      (08)
#   limit     M1/M2  agent sessions under several limit sets (size, two tiers)             (08-1)
#   prefix    M3  same document asked twice, prefill prefix caching off vs on              (08-2)
#   chunk     M4  short-request TTFT during long prefills, prefill max-num-batched-tokens  (08-3)
#   retry     M5  sequential long tasks: immediate / fixed / exponential-backoff retry     (08-4)
#   conc      M6  same long tasks at concurrency 4/2/1 while a short probe runs            (08-5)
#   split     S1  long burst + short probe on the same vs a separate subscription          (08-6)
# Limits are written as "LIMIT/WINDOW[+LIMIT/WINDOW]", e.g. "50000/15s+100000/2m".
#   MAAS_MIT_ARMS ("single io saturate limit retry conc split"; prefix/chunk restart prefill, run them explicitly)
#   MAAS_MIT_LIMITS ("20000/15s 25000/15s 50000/15s 50000/15s+80000/2m") MAAS_MIT_SECONDS (90) MAAS_MIT_SESSIONS (2)
#   MAAS_MIT_CONC_LIMIT (20000/15s) MAAS_MIT_CONC ("4 2 1") MAAS_MIT_RETRY_LIMIT (20000/15s)
#   MAAS_MIT_POLICIES ("immediate fixed backoff") MAAS_MIT_TASKS (6) MAAS_MIT_SPLIT_LIMIT (20000/15s)
#   MAAS_MIT_SATURATE_CONC (48) MAAS_MIT_CHUNK ("2048 8192") MAAS_MIT_PROMPT_WORDS (6000, ~12k tokens)
#   MAAS_RL_SUBSCRIPTION (llmd-demo-sub, key Secret loadgen-token)
#   MAAS_MIT_CHAT_SUBSCRIPTION (llmd-demo-sub-chat, key Secret loadgen-token-chat; split only)
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"
SUBNS="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
SUB="${MAAS_RL_SUBSCRIPTION:-llmd-demo-sub}"; SUB2="${MAAS_MIT_CHAT_SUBSCRIPTION:-llmd-demo-sub-chat}"
WORDS="${MAAS_MIT_PROMPT_WORDS:-6000}"; TASKS="${MAAS_MIT_TASKS:-6}"
ARMS="${MAAS_MIT_ARMS:-single io saturate limit retry conc split}"
oc get secret loadgen-token -n "$BENCH_NS" >/dev/null 2>&1 || die "no MaaS API key: run 'harness.sh maas-api-key'"
SUBS="$SUB"
case " $ARMS " in *" split "*) SUBS="$SUB $SUB2"
  oc get maassubscription "$SUB2" -n "$SUBNS" >/dev/null 2>&1 && oc get secret loadgen-token-chat -n "$BENCH_NS" >/dev/null 2>&1 \
    || die "split needs MaaSSubscription $SUBNS/$SUB2 and Secret $BENCH_NS/loadgen-token-chat (see docs/scenarios-2/08-6)";;
esac
URL="$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.status.url}')/v1/chat/completions"
MODEL=$(oc get llminferenceservice "$N" -n "$NS" -o jsonpath='{.spec.model.name}')

ref_index() {  # <subscription> -> index of NS/N in spec.modelRefs
  oc get maassubscription "$1" -n "$SUBNS" -o json | "$PY" -c '
import sys, json
refs = json.load(sys.stdin)["spec"]["modelRefs"]
print(next(i for i, r in enumerate(refs) if r["name"] == sys.argv[1] and r.get("namespace") == sys.argv[2]))' "$N" "$NS"
}
limits_json() {  # "20000/15s+100000/2m" -> [{"limit":20000,"window":"15s"},...]
  echo "$1" | tr '+' '\n' | awk -F/ 'BEGIN{printf "["} {printf "%s{\"limit\":%s,\"window\":\"%s\"}", (NR>1 ? "," : ""), $1, $2} END{print "]"}'
}
# bash 3.2 compatible: per-subscription index/original limits in IDX_<n>/ORIG_<n> (n = position in $SUBS)
sub_n() { local i=0 s; for s in $SUBS; do [ "$s" = "$1" ] && { echo $i; return; }; i=$((i + 1)); done; }
i=0; for s in $SUBS; do
  eval "IDX_$i=\$(ref_index \"\$s\")" || die "$NS/$N is not in MaaSSubscription $SUBNS/$s"
  eval "ORIG_$i=\$(oc get maassubscription \"\$s\" -n \"\$SUBNS\" -o jsonpath=\"{.spec.modelRefs[\$IDX_$i].tokenRateLimits}\")"
  i=$((i + 1))
done
patch_limits() {  # <subscription> <json list>
  local n; n=$(sub_n "$1"); eval "local idx=\$IDX_$n"
  oc patch maassubscription "$1" -n "$SUBNS" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/$idx/tokenRateLimits\",\"value\":$2}]" >/dev/null
}
set_limits() {  # <spec> [<subscription>...]: patch, then wait for the TokenRateLimitPolicy and Authorino's 60 s cache
  local spec=$1 s; shift
  for s in "${@:-$SUB}"; do patch_limits "$s" "$(limits_json "$spec")"; done
  echo "  limits -> $spec on ${*:-$SUB} (waiting 75 s for policy + cache)"; sleep 75
}
PREFILL_ARGS=$(vllm_args "$NS" "$N" prefill)
restore() {
  [ "$(vllm_args "$NS" "$N" prefill)" = "$PREFILL_ARGS" ] || restore_prefill
  local s o; for s in $SUBS; do eval "o=\$ORIG_$(sub_n "$s")"; patch_limits "$s" "$o" 2>/dev/null; echo "  limits restored $s -> $o"; done
}
trap restore EXIT

# run_plan <label> <limit spec for the summary> <plan json>
# Plan: list of groups {name, key A|B, kind agent|batch|probe, ...}; see probe.py below.
run_plan() {
  oc create configmap mit-probe -n "$BENCH_NS" --from-literal=probe.py="$(cat <<'PYEOF'
import json, os, random, ssl, threading, time, urllib.request, urllib.error
E = os.environ.get; ctx = ssl._create_unverified_context()
VOC = "cluster gateway router scheduler cache token latency replica model pod node queue policy".split()
KEYS = {"A": E("TOKEN_A"), "B": E("TOKEN_B")}
lock = threading.Lock(); T0 = time.time()
def call(g, words, seed, question="Summarize."):
    # group options: max_tokens (32), ignore_eos (false); the same seed gives the same document (prefix reuse)
    rng = random.Random(seed)
    body = {"model": E("MODEL"), "max_tokens": g.get("max_tokens", 32), "stream": True, "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}, "ignore_eos": g.get("ignore_eos", False),
            "messages": [{"role": "user", "content": " ".join(rng.choice(VOC) + rng.choice("abcdefghij") for _ in range(words)) + "\n" + question}]}
    r = urllib.request.Request(E("URL"), json.dumps(body).encode(),
        {"Authorization": "Bearer " + KEYS[g["key"]], "Content-Type": "application/json"})
    t0 = time.time(); code = 0; usage = None; ttft = None
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=int(E("TIMEOUT", "300"))) as resp:
            code = resp.status
            for line in resp:
                if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
                    d = json.loads(line[5:]); usage = d.get("usage") or usage
                    if ttft is None and any((c.get("delta") or {}).get("content") for c in d.get("choices") or []):
                        ttft = time.time() - t0
    except urllib.error.HTTPError as e: code = e.code
    except Exception: code = -1
    u = usage or {}
    return {"t": round(t0 - T0, 2), "dur": round(time.time() - t0, 2), "code": code, "tokens": u.get("total_tokens"),
            "prompt": u.get("prompt_tokens"), "completion": u.get("completion_tokens"),
            "cached": (u.get("prompt_tokens_details") or {}).get("cached_tokens"), "ttft": ttft and round(ttft, 2)}
def log(**kw):
    with lock: print("REQ " + json.dumps(kw), flush=True)
def wait_for(g, k):  # seconds to wait before retry k (k = 0 for the first retry)
    p = g.get("retry", "none")
    if p == "immediate": return 0.2
    if p == "fixed": return g.get("retry_s", 1)
    if p == "backoff": return min(g.get("cap", 15), g.get("retry_s", 1) * 2 ** k) * random.uniform(0.5, 1.0)
    return None
def task(g, tid, words, seed=None, question="Summarize."):
    k = 0; first = None
    while True:
        x = call(g, words, hash((g["name"], tid, k, time.time())) if seed is None else seed, question)
        first = x["t"] if first is None else first
        log(g=g["name"], task=tid, attempt=k, done=x["code"] != 429, latency=round(x["t"] + x["dur"] - first, 2), **x)
        w = wait_for(g, k) if x["code"] == 429 else None
        if w is None: return
        time.sleep(w); k += 1
def agent(g, sid):  # loop: one long task, then `followups` short tasks
    end = T0 + g["seconds"]; n = 0
    while time.time() < end:
        task(g, f"{sid}-{n}-L", g["words"])
        for f in range(g.get("followups", 0)):
            if time.time() >= end: break
            task(g, f"{sid}-{n}-S{f}", g.get("short_words", 20))
        n += 1
def batch(g):  # `tasks` long tasks, at most `conc` in flight
    sem = threading.Semaphore(g["conc"]); ts = []
    def one(i):
        with sem: task(g, f"{i}", g["words"])
    for i in range(g["tasks"]):
        th = threading.Thread(target=one, args=(i,)); th.start(); ts.append(th)
    [th.join() for th in ts]
def pairs(g):  # `docs` documents, each asked `questions` in turn (same prefix -> prefix cache)
    for i in range(g["docs"]):
        for j, q in enumerate(g["questions"]):
            task(g, f"d{i}-q{j}", g["words"], seed=1000 * g.get("seed", 1) + i, question=q)
plan = json.loads(E("PLAN")); workers = []; done = threading.Event()
for g in plan:
    if g["kind"] == "agent":
        workers += [threading.Thread(target=agent, args=(g, s)) for s in range(g["sessions"])]
    elif g["kind"] == "batch":
        workers.append(threading.Thread(target=batch, args=(g,)))
    elif g["kind"] == "pairs":
        workers.append(threading.Thread(target=pairs, args=(g,)))
[w.start() for w in workers]
probes = [g for g in plan if g["kind"] == "probe"]
def probe(g):  # open loop: a short request every `interval` s (not waiting for the previous one) until
    i = 0; ts = []   # the other groups finish + `tail` s; no retry
    while not done.is_set():
        th = threading.Thread(target=task, args=(dict(g, retry="none"), f"p{i}", g.get("short_words", 20)))
        th.start(); ts.append(th); i += 1; time.sleep(g.get("interval", 1))
    [th.join() for th in ts]
pt = [threading.Thread(target=probe, args=(g,)) for g in probes]; [p.start() for p in pt]
[w.join() for w in workers]; time.sleep(probes[0].get("tail", 5) if probes else 0); done.set(); [p.join() for p in pt]
PYEOF
)" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc delete job mit-probe -n "$BENCH_NS" --ignore-not-found --wait=true >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: mit-probe, namespace: ${BENCH_NS}}
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
        - {name: PLAN, value: '$3'}
        - {name: TIMEOUT, value: "${MAAS_MIT_TIMEOUT:-300}"}
        - name: TOKEN_A
          valueFrom: {secretKeyRef: {name: loadgen-token, key: token}}
        - name: TOKEN_B
          valueFrom: {secretKeyRef: {name: loadgen-token-chat, key: token, optional: true}}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: s, mountPath: /app}]
      volumes: [{name: s, configMap: {name: mit-probe}}]
YAML
  until [ -n "$(oc get job mit-probe -n "$BENCH_NS" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]; do sleep 5; done
  oc logs job/mit-probe -n "$BENCH_NS" | sed -n 's/^REQ //p' | "$PY" -c '
import sys, json
lab, spec = sys.argv[1], sys.argv[2]
rows = sorted((json.loads(l) for l in sys.stdin), key=lambda r: r["t"])
for r in rows:
    print("  %-10s %-6s %-8s t=%6.1fs dur=%6.2fs ttft=%s code=%s tokens=%s prompt=%s completion=%s cached=%s" % (
        lab, r["g"], r["task"], r["t"], r["dur"], r.get("ttft"), r["code"], r["tokens"], r.get("prompt"), r.get("completion"), r.get("cached")))
# fixed-window replay per subscription key: max tokens charged inside one window (first limit of the spec)
lim, win = spec.split("+")[0].split("/"); lim = int(lim)
win = float(win[:-1]) * {"s": 1, "m": 60, "h": 3600}[win[-1]]
def worst(rs):
    start, cum, top = None, 0, 0
    for end, tok in sorted((r["t"] + r["dur"], r["tokens"] or 0) for r in rs if r["code"] == 200):
        if start is None or end >= start + win: start, cum = end, 0
        cum += tok; top = max(top, cum)
    return top
span = (max(r["t"] + r["dur"] for r in rows) - min(r["t"] for r in rows)) if rows else 0
print("  %-10s summary limits=%s run=%.0fs" % (lab, spec, span))
for g in sorted({r["g"] for r in rows}):
    rs = [r for r in rows if r["g"] == g]; ok = [r for r in rs if r["code"] == 200]
    lat = sorted(r["latency"] for r in rs if r["done"] and r["code"] == 200)
    tt = sorted(r["ttft"] for r in ok if r.get("ttft") is not None)
    codes = {}
    for r in rs: codes[r["code"]] = codes.get(r["code"], 0) + 1
    print("  %-10s   %-6s tasks_ok=%d attempts=%d 429=%d codes=%s tokens=%d latency_p50=%.1fs max=%.1fs ttft_p50=%.2fs max=%.2fs makespan=%.1fs" % (
        lab, g, len(ok), len(rs), sum(r["code"] == 429 for r in rs), json.dumps(codes),
        sum(r["tokens"] or 0 for r in ok), lat[len(lat) // 2] if lat else 0, lat[-1] if lat else 0,
        tt[len(tt) // 2] if tt else 0, tt[-1] if tt else 0,
        max(r["t"] + r["dur"] for r in ok) - min(r["t"] for r in rs) if ok else 0))
keyA = [r for r in rows if r["g"] != "chat"]
print("  %-10s   max tokens in one %gs window (key A): %d (%.1fx limit)" % (lab, win, worst(keyA), worst(keyA) / lim))' "$1" "$2"
}

# restore_prefill: put the original prefill VLLM_ADDITIONAL_ARGS back (restart)
restore_prefill() {
  local cur; cur=$(vllm_args "$NS" "$N" prefill)
  for f in enable-prefix-caching max-num-batched-tokens; do
    case " $PREFILL_ARGS " in *" --$f"*) ;; *) case " $cur " in *" --$f"*) set_vllm_flag "$NS" "$N" "$f" default prefill ;; esac ;; esac
  done
}
UNLIMITED="1000000000/1h"
for arm in $ARMS; do case $arm in
  single) L=8000/15s; set_limits "$L"
      say "single: one long request (~12k tokens) with limit $L, then a short probe every 1 s"
      run_plan "single" "$L" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":1,\"conc\":1,\"words\":$WORDS,\"retry\":\"none\"},{\"name\":\"short\",\"key\":\"A\",\"kind\":\"probe\",\"interval\":1,\"tail\":25}]"
      sleep 20 ;;
  io) L=5000/5m; set_limits "$L"
      say "io (a) input-heavy: 3 x (~2.4k prompt + 32 output), limit $L"
      run_plan "io:input" "$L" "[{\"name\":\"input\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":3,\"conc\":1,\"words\":1200,\"retry\":\"none\"}]"
      sleep 300   # let the 5 m window that started at the first charge expire
      say "io (b) output-heavy: 3 x (~60 prompt + 2400 output, ignore_eos), limit $L"
      run_plan "io:output" "$L" "[{\"name\":\"output\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":3,\"conc\":1,\"words\":20,\"max_tokens\":2400,\"ignore_eos\":true,\"retry\":\"none\"}]" ;;
  saturate) set_limits "$UNLIMITED"
      C=${MAAS_MIT_SATURATE_CONC:-48}
      say "saturate: $C long requests (~6k tokens) at once, no token limit"
      SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      MAAS_MIT_TIMEOUT=600 run_plan "saturate" "$UNLIMITED" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":$C,\"conc\":$C,\"words\":3000,\"retry\":\"none\"}]"
      echo "  EPP log lines mentioning flow control / rejections since $SINCE:"
      oc logs deploy/${N}-kserve-router-scheduler -n "$NS" --since-time="$SINCE" 2>/dev/null \
        | grep -iE "reject|shed|429|too many|saturat|capacity" | cut -c1-200 | sort | uniq -c | sort -rn | head -5 || true ;;
  prefix) set_limits "$UNLIMITED"
      for mode in default on; do
        set_vllm_flag "$NS" "$N" enable-prefix-caching "$mode" prefill
        say "prefix caching on prefill: $mode; 5 documents (~6k tokens) x 2 questions"
        run_plan "prefix:$mode" "$UNLIMITED" "[{\"name\":\"doc\",\"key\":\"A\",\"kind\":\"pairs\",\"docs\":5,\"words\":3000,\"seed\":$(date +%s),\"questions\":[\"Summarize.\",\"List three keywords.\"]}]"
      done
      restore_prefill ;;
  chunk) set_limits "$UNLIMITED"
      for b in ${MAAS_MIT_CHUNK:-2048 8192}; do
        set_vllm_flag "$NS" "$N" max-num-batched-tokens "$b" prefill
        say "prefill max-num-batched-tokens=$b: 4 long requests at once + short probe every 1 s"
        run_plan "chunk:$b" "$UNLIMITED" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":4,\"conc\":4,\"words\":$WORDS,\"retry\":\"none\"},{\"name\":\"short\",\"key\":\"A\",\"kind\":\"probe\",\"interval\":1,\"tail\":5}]"
      done
      restore_prefill ;;
  limit) for L in ${MAAS_MIT_LIMITS:-20000/15s 25000/15s 50000/15s 50000/15s+80000/2m}; do
        say "limit limit $L: ${MAAS_MIT_SESSIONS:-2} agent sessions (long + 3 short, retry 1 s) for ${MAAS_MIT_SECONDS:-90}s"
        set_limits "$L"
        run_plan "limit:$L" "$L" "[{\"name\":\"agent\",\"key\":\"A\",\"kind\":\"agent\",\"sessions\":${MAAS_MIT_SESSIONS:-2},\"seconds\":${MAAS_MIT_SECONDS:-90},\"words\":$WORDS,\"followups\":3,\"retry\":\"fixed\",\"retry_s\":1}]"
      done ;;
  conc) L="${MAAS_MIT_CONC_LIMIT:-20000/15s}"; set_limits "$L"
      for c in ${MAAS_MIT_CONC:-4 2 1}; do
        say "conc $TASKS long tasks at concurrency $c (retry 1 s) + short probe every 1 s, limit $L"
        run_plan "conc:c$c" "$L" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":$TASKS,\"conc\":$c,\"words\":$WORDS,\"retry\":\"fixed\",\"retry_s\":1},{\"name\":\"short\",\"key\":\"A\",\"kind\":\"probe\",\"interval\":1,\"tail\":5}]"
        sleep 20   # let the window expire before the next arm
      done ;;
  retry) L="${MAAS_MIT_RETRY_LIMIT:-20000/15s}"; set_limits "$L"
      for p in ${MAAS_MIT_POLICIES:-immediate fixed backoff}; do
        case $p in fixed) R="\"retry\":\"fixed\",\"retry_s\":15";; backoff) R="\"retry\":\"backoff\",\"retry_s\":1,\"cap\":15";; *) R="\"retry\":\"$p\"";; esac
        say "retry $TASKS sequential long tasks, retry=$p, limit $L"
        run_plan "retry:$p" "$L" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":$TASKS,\"conc\":1,\"words\":$WORDS,$R}]"
        sleep 20
      done ;;
  split) L="${MAAS_MIT_SPLIT_LIMIT:-20000/15s}"; set_limits "$L" "$SUB" "$SUB2"
      for k in A B; do
        say "split 4 long tasks at once (key A, $SUB) + short probe with key $k ($( [ $k = A ] && echo "$SUB" || echo "$SUB2" )), limit $L"
        run_plan "split:short=$k" "$L" "[{\"name\":\"long\",\"key\":\"A\",\"kind\":\"batch\",\"tasks\":4,\"conc\":4,\"words\":$WORDS,\"retry\":\"none\"},{\"name\":\"$( [ $k = A ] && echo short || echo chat )\",\"key\":\"$k\",\"kind\":\"probe\",\"interval\":1,\"tail\":20}]"
        sleep 20
      done ;;
esac; done
