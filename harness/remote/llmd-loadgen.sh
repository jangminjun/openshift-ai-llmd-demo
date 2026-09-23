# Runs tools/loadgen.py as an in-cluster Job and prints its SUMMARY line.
# Prepended with remote/lib/bench.sh by harness.sh. Target: URL/MODEL, or
# LLMD_NAMESPACE/LLMD_NAME (MaaS gateway path + .spec.model.name).
# LOADGEN_WAIT=false starts the Job and returns (for concurrent traffic classes).
NAME="${LOADGEN_NAME:-loadgen}"
loadgen_start "$NAME"
[ "${LOADGEN_WAIT:-true}" = true ] || exit 0
echo "SUMMARY $(loadgen_wait "$NAME")"
