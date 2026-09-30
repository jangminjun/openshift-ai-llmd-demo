#!/usr/bin/env python3
"""Minimal OpenAI-compatible load generator (stdlib only) for llm-d scenarios.

Runs in-cluster as a Job (see harness.sh llmd-loadgen) or locally. Streams
responses to measure TTFT, counts HTTP codes client-side (server metrics miss
connection-level failures, see scenario 12), prints one JSON summary line.

Env:
  URL          full chat-completions URL (required)
  MODEL        model field (required)
  TOKEN        bearer token; default: in-cluster ServiceAccount token
  CONCURRENCY  parallel workers (default 4)
  REQUESTS     total requests (default 0 = use DURATION)
  DURATION     seconds to run when REQUESTS=0 (default 60)
  INTERVAL     per-worker pause between requests in seconds (default 0)
  MAX_TOKENS   (default 64)
  PROMPT_MODE  short | shared-prefix | multi-prefix | unique-long | image | multi-turn (default short)
  DOCS         number of distinct documents for multi-prefix (default 100)
  DOC_OFFSET   first document id (use a new range per run to start with cold caches)
  DOC_ORDER    multi-prefix: random (default) | seq = request i uses document DOC_OFFSET + i % DOCS
  PREFIX_TOKENS approx. size of shared/unique prompt body (default 2000)
  IMAGE_URLS   comma-separated image URLs/data-URLs for PROMPT_MODE=image; a single URL containing
               "{n}" is a template filled with DOC_OFFSET + random(DOCS) (e.g. seeded image service)
  SESSIONS     multi-turn: number of conversations, each with its own PREFIX_TOKENS document (default 64)
  TURNS        multi-turn: user turns per conversation; history (incl. answers) is resent (default 3)
  SESSION_HEADER multi-turn: response header echoed back on later turns (default x-session-token,
               set by the EPP session-affinity plugins)
  PAUSE_AFTER_TURN multi-turn: run turns [0, N) of every conversation, print "PHASE_PAUSE", sleep
               PAUSE_SECONDS (default 180), then run the remaining turns; lets the caller change the
               cluster (e.g. restart the EPP) between phases. Pause time is excluded from wall_s/rps.
  IGNORE_EOS   1 = vLLM ignore_eos: always generate MAX_TOKENS (decode-bound workloads)
  HEADERS      JSON object of extra request headers
  LABEL        free-text label copied into the summary
  TIMEOUT      per-request timeout seconds (default 300)
"""
import json, os, random, ssl, string, threading, time, urllib.parse, http.client

E = os.environ.get
URL = E("URL") or exit("URL required")
MODEL = E("MODEL") or exit("MODEL required")
TOKEN = E("TOKEN") or (open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
                       if os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount/token") else "")
CONC = int(E("CONCURRENCY", "4")); REQS = int(E("REQUESTS", "0")); DUR = float(E("DURATION", "60"))
INTERVAL = float(E("INTERVAL", "0")); MAXTOK = int(E("MAX_TOKENS", "64"))
MODE = E("PROMPT_MODE", "short"); PREFIX = int(E("PREFIX_TOKENS", "2000"))
DOCS = int(E("DOCS", "100")); DOC_OFFSET = int(E("DOC_OFFSET", "0")); DOC_ORDER = E("DOC_ORDER", "random")
IMAGES = [u for u in E("IMAGE_URLS", "").split(",") if u]
HDRS = json.loads(E("HEADERS", "{}")); LABEL = E("LABEL", ""); TIMEOUT = float(E("TIMEOUT", "300"))
SESSIONS = int(E("SESSIONS", "64")); TURNS = int(E("TURNS", "3")); SESSION_HEADER = E("SESSION_HEADER", "x-session-token")
IGNORE_EOS = E("IGNORE_EOS", "") == "1"
PAUSE_AFTER = int(E("PAUSE_AFTER_TURN", "0")); PAUSE_S = float(E("PAUSE_SECONDS", "180"))

u = urllib.parse.urlparse(URL)
CTX = ssl._create_unverified_context()
WORDS = "cluster gateway router scheduler cache token latency replica model pod node queue policy".split()
def words(seed):  # one RNG per text: a fresh Random(seed) per word repeats a single word
    rng = random.Random(seed); return " ".join(rng.choice(WORDS) for _ in range(PREFIX))

SHARED = words(42)
QUESTIONS = ["Summarize the text.", "List three keywords.", "What is the main topic?", "Give a title.",
             "Count repeated words.", "Write one sentence about it.", "Is it technical?", "Translate the first line."]

def messages(i):
    if MODE == "shared-prefix":
        return [{"role": "system", "content": "Reference document: " + SHARED},
                {"role": "user", "content": QUESTIONS[i % len(QUESTIONS)]}]
    if MODE == "multi-prefix":  # random doc out of DOCS, each a stable PREFIX_TOKENS-long text
        d = DOC_OFFSET + (i % DOCS if DOC_ORDER == "seq" else random.randrange(DOCS))
        text = words(d)
        return [{"role": "system", "content": "Document %d: %s" % (d, text)},
                {"role": "user", "content": random.choice(QUESTIONS)}]
    if MODE == "unique-long":
        body = " ".join(random.choice(WORDS) + random.choice(string.ascii_lowercase) for _ in range(PREFIX))
        return [{"role": "user", "content": body + "\nSummarize the text."}]
    if MODE == "image":
        if len(IMAGES) == 1 and "{n}" in IMAGES[0]:
            img = IMAGES[0].replace("{n}", str(DOC_OFFSET + random.randrange(DOCS)))
        else:
            img = IMAGES[i % len(IMAGES)]
        return [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}},
                                             {"type": "text", "text": random.choice(QUESTIONS)}]}]
    return [{"role": "user", "content": "Explain Kubernetes in one sentence. (%d)" % i}]

results, lock = [], threading.Lock()
counter = iter(range(10**9))

def doc(d):  # stable PREFIX_TOKENS-long document per id
    return "Document %d: %s" % (d, words(d))

def one(i, msgs=None, extra=None, turn=None):
    """Send one streamed request; returns (answer text, response headers)."""
    req = {"model": MODEL, "messages": msgs or messages(i), "max_tokens": MAXTOK, "stream": True,
           "stream_options": {"include_usage": True}}
    if IGNORE_EOS:
        req["ignore_eos"] = True
    body = json.dumps(req)
    h = {"Content-Type": "application/json", **HDRS, **(extra or {})}
    if TOKEN:
        h["Authorization"] = "Bearer " + TOKEN
    t0 = time.time(); ttft = None; code = 0; toks = 0; err = ""; text = []; rh = {}
    try:
        c = (http.client.HTTPSConnection(u.netloc, context=CTX, timeout=TIMEOUT) if u.scheme == "https"
             else http.client.HTTPConnection(u.netloc, timeout=TIMEOUT))
        c.request("POST", u.path, body, h)
        r = c.getresponse(); code = r.status; rh = {k.lower(): v for k, v in r.getheaders()}
        if code != 200:
            err = r.read(300).decode(errors="replace")
        else:
            for line in r:
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if data == b"[DONE]":
                    break
                d = json.loads(data)
                piece = d["choices"][0].get("delta", {}).get("content") if d.get("choices") else None
                if piece:
                    text.append(piece)
                    if ttft is None:
                        ttft = time.time() - t0
                if d.get("usage"):
                    toks = d["usage"].get("completion_tokens", 0)
        c.close()
    except Exception as ex:  # connection-level failures count as code 0
        err = type(ex).__name__ + ": " + str(ex)[:200]
    with lock:
        results.append({"code": code, "ttft": ttft, "e2e": time.time() - t0, "toks": toks, "err": err, "t": t0,
                        "turn": turn, "stoken": SESSION_HEADER in rh})
    return "".join(text), rh

sessions = iter(range(SESSIONS)); state = {}; turn_range = (0, TURNS)

def conversation(sid):  # user turns over one growing history; echoes the session header
    st = state.setdefault(sid, {"hist": [{"role": "system", "content": doc(DOC_OFFSET + sid)}], "extra": {}})
    for t in range(*turn_range):
        st["hist"].append({"role": "user", "content": QUESTIONS[(sid + t) % len(QUESTIONS)]})
        answer, rh = one(0, st["hist"], st["extra"], t)
        st["hist"].append({"role": "assistant", "content": answer or "(no answer)"})
        if rh.get(SESSION_HEADER):
            st["extra"] = {SESSION_HEADER: rh[SESSION_HEADER]}
        if INTERVAL:
            time.sleep(INTERVAL)

def worker(deadline):
    if MODE == "multi-turn":
        for sid in sessions:
            conversation(sid)
        return
    while True:
        i = next(counter)
        if (REQS and i >= REQS) or (not REQS and time.time() >= deadline):
            return
        one(i)
        if INTERVAL:
            time.sleep(INTERVAL)

def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    return round(xs[min(len(xs) - 1, int(len(xs) * p))], 3) if xs else None

def run_threads():
    threads = [threading.Thread(target=worker, args=(start + DUR,)) for _ in range(CONC)]
    [t.start() for t in threads]; [t.join() for t in threads]

start = time.time(); paused = 0.0
if MODE == "multi-turn" and 0 < PAUSE_AFTER < TURNS:
    turn_range = (0, PAUSE_AFTER); run_threads()
    print("PHASE_PAUSE after turn %d, sleeping %ds" % (PAUSE_AFTER, PAUSE_S), flush=True)
    time.sleep(PAUSE_S); paused = PAUSE_S
    sessions = iter(range(SESSIONS)); turn_range = (PAUSE_AFTER, TURNS)
run_threads()
wall = time.time() - start - paused
ok = [r for r in results if r["code"] == 200]
codes = {}
for r in results:
    codes[str(r["code"])] = codes.get(str(r["code"]), 0) + 1
summary = {"label": LABEL, "start_epoch": round(start, 3), "mode": MODE, "concurrency": CONC, "n": len(results), "ok": len(ok), "codes": codes,
           "wall_s": round(wall, 1), "rps": round(len(ok) / wall, 2) if wall else 0,
           "out_tok_s": round(sum(r["toks"] for r in ok) / wall, 1) if wall else 0,
           "ttft_p50": pct([r["ttft"] for r in ok], .5), "ttft_p95": pct([r["ttft"] for r in ok], .95),
           "e2e_p50": pct([r["e2e"] for r in ok], .5), "e2e_p95": pct([r["e2e"] for r in ok], .95),
           "errors": sorted({r["err"] for r in results if r["err"]})[:3]}
if MODE == "multi-turn":  # first turn = cold document, later turns = history already cached somewhere
    summary["ttft_p50_turn1"] = pct([r["ttft"] for r in ok if r["turn"] == 0], .5)
    summary["ttft_p50_later"] = pct([r["ttft"] for r in ok if r["turn"]], .5)
    summary["session_token_resp"] = sum(r["stoken"] for r in ok)
if E("TIMELINE"):
    summary["timeline"] = [[round(r["t"] - start, 1), r["code"], r["ttft"] and round(r["ttft"], 3)] for r in sorted(results, key=lambda r: r["t"])]
print("SUMMARY " + json.dumps(summary))
