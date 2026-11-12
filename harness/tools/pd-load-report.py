#!/usr/bin/env python3
"""P/D load report: GuideLLM benchmarks.json + prefill/decode counters before/after (remote/pd-counters.sh).

usage: pd-load-report.py <before.json> <after.json> <benchmarks.json>
Prints per-concurrency latency/throughput and whole-run disaggregation ratios:
  prefill requests / client requests sent, decode generated tokens / client output tokens,
  NIXL transfers and failures.
"""
import json
import sys

before, after, bench = (json.load(open(p)) for p in sys.argv[1:4])
delta = {r: {k: after[r].get(k, 0) - before[r].get(k, 0) for k in after[r]} for r in after}


def stat(m, key, field="successful", pct="p50"):
    v = (m.get(key) or {}).get(field) or {}
    return (v.get("percentiles") or {}).get(pct) or 0.0


sent = out_tok = 0
print("  %-8s %5s %5s %5s %10s %10s %9s %9s %10s" % (
    "streams", "ok", "incmp", "err", "TTFT p50", "TTFT p95", "ITL p50", "ITL p95", "out tok/s"))
for b in bench["benchmarks"]:
    m = b["metrics"]; t = m["request_totals"]
    streams = (b.get("config") or {}).get("strategy", {}).get("streams") or (b.get("config") or {}).get("profile", {}).get("streams") or "-"
    sent += t["successful"] + t["incomplete"] + t["errored"]
    for f in ("successful", "incomplete", "errored"):
        out_tok += ((m["output_token_count"].get(f) or {}).get("total_sum") or 0)
    print("  %-8s %5d %5d %5d %9.0fms %9.0fms %7.1fms %7.1fms %10.1f" % (
        streams, t["successful"], t["incomplete"], t["errored"],
        stat(m, "time_to_first_token_ms"), stat(m, "time_to_first_token_ms", pct="p95"),
        stat(m, "inter_token_latency_ms"), stat(m, "inter_token_latency_ms", pct="p95"),
        ((m.get("output_tokens_per_second") or {}).get("successful") or {}).get("mean") or 0.0))

p, d = delta["prefill"], delta["decode"]
print("  requests sent (ok+incomplete+errored): %d" % sent)
print("  prefill request_success: %d (ratio %.2f), prefill generation tokens: %d" % (
    p.get("request_success_total", 0), p.get("request_success_total", 0) / max(sent, 1), p.get("generation_tokens_total", 0)))
print("  decode request_success: %d, decode generation tokens: %d / client output tokens %d (ratio %.2f)" % (
    d.get("request_success_total", 0), d.get("generation_tokens_total", 0), out_tok, d.get("generation_tokens_total", 0) / max(out_tok, 1)))
print("  prompt tokens counted: decode %d, prefill %d (decode counts them even when the KV is transferred)" % (
    d.get("prompt_tokens_total", 0), p.get("prompt_tokens_total", 0)))
print("  NIXL transfers (decode, per TP rank): %d, failed: %d, expired KV (prefill): %d, MB moved: %.0f" % (
    d.get("nixl_xfer_time_seconds_count", 0), d.get("nixl_num_failed_transfers_total", 0),
    p.get("nixl_num_kv_expired_reqs_total", 0), d.get("nixl_bytes_transferred_sum", 0) / 1e6))
print("  preemptions: prefill %d, decode %d" % (p.get("num_preemptions_total", 0), d.get("num_preemptions_total", 0)))
