# Scenario 2-06-1..2-06-5: per-role GPU memory settings of a P/D model. Applies ONE named configuration to
# prefill and decode (one restart), waits for startup or detects OOM, and prints the startup memory lines.
# The load (2-03 L1/L2) is run by harness.sh cmd_scenario2_06 after this script. Prepended with lib/bench.sh.
#   S26_CONFIG   base | r1 | r2 | eager | chunk | seqs | c1 (docs/scenarios-2/06-*.md); custom: S26_PREFILL/S26_DECODE
#   S26_PREFILL / S26_DECODE  flag specs "<flag>=<value|on|default> ..." (override the named config)
# Last line: "S26_RESULT <config> ok|fail:<reason>".
NS="${LLMD_NAMESPACE:-llmd-pd}"; N="${LLMD_NAME:-qwen38-int4-pd}"; C="${S26_CONFIG:-base}"

# Every config sets all four prefill flags and the decode util, so configs do not depend on the previous one.
base_p="gpu-memory-utilization=0.85 enforce-eager=default max-num-batched-tokens=default max-num-seqs=64"
base_d="gpu-memory-utilization=0.85"
case $C in
  base)  P="$base_p"; D="$base_d" ;;
  r1)    P="$base_p gpu-memory-utilization=0.75"; D="gpu-memory-utilization=0.90" ;;          # 2-06-1
  r2)    P="$base_p gpu-memory-utilization=0.75"; D="gpu-memory-utilization=0.95" ;;          # 2-06-1 limit
  eager) P="$base_p enforce-eager=on"; D="$base_d" ;;                                         # 2-06-2
  chunk) P="$base_p max-num-batched-tokens=2048"; D="$base_d" ;;                              # 2-06-3
  seqs)  P="$base_p max-num-seqs=8"; D="$base_d" ;;                                           # 2-06-4
  c1)    P="gpu-memory-utilization=0.75 enforce-eager=on max-num-batched-tokens=2048 max-num-seqs=8"
         D="gpu-memory-utilization=0.90" ;;                                                   # 2-06-5
  *)     P=""; D="" ;;
esac
P="${S26_PREFILL:-$P}"; D="${S26_DECODE:-$D}"
[ -n "$P$D" ] || die "unknown S26_CONFIG=$C (set S26_PREFILL/S26_DECODE for a custom one)"

say "2-06 config $C"
echo "  prefill: $P"; echo "  decode : $D"
t0=$(date +%s)
st=$(set_vllm_flags "$NS" "$N" "$P" "$D")
if [ "$st" = changed ]; then r=$(pd_wait_start "$NS" "$N" "${S26_START_TIMEOUT:-1800}"); else r=ok; echo "  (no change, no restart)"; fi
echo "  startup: $r ($(( $(date +%s) - t0 ))s)"

say "startup memory ($C)"
for role in prefill decode; do
  for p in $(oc get pods -n "$NS" -l "llm-d.ai/role=$role" -o name | grep "/${N}-"); do
    echo "  [$role] ${p#pod/}"
    oc logs "$p" -n "$NS" -c main 2>/dev/null \
      | grep -E 'Model loading took|Available KV cache memory|GPU KV cache size|CUDA graph|Graph capturing finished|torch.compile takes|torch.compile took|init engine.*took|out of memory|No available memory' \
      | grep -vE 'Capturing CUDA graphs|CUDA graph memory profiling is enabled'       | sed -E 's/^.*\] //' | tail -12 | sed 's/^/    /'
  done
done
thanos_print "GPU memory used (MiB) by pod" "max by (exported_pod) (DCGM_FI_DEV_FB_USED{exported_namespace=\"$NS\"})"
oc get pods -n "$NS" -l 'llm-d.ai/role in (prefill,decode)' | sed 's/^/  /'
echo "S26_RESULT $C $r"
