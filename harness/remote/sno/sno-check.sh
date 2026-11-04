#!/usr/bin/env bash
# Single Node OpenShift readiness report for the llm-d scenarios. Read-only.
#   1. Topology: one node holding control-plane + worker roles
#   2. GPU: product, allocatable, free (GPU Operator labels)
#   3. OpenShift / RHOAI versions, DataScienceCluster Ready, llm-d CRD
#   4. LLMInferenceServiceConfig version prefix (manifests baseRefs follow it)
#   5. Operators the harness relies on (RHCL, Service Mesh, Tempo, OpenTelemetry, COO)
#   6. Scenario fit by GPU count (SNO_GPU_NEEDS: "<scenario>:<gpus> ...")
set -euo pipefail
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
FAIL=0

echo "== 1. Topology =="
nodes=$(oc get nodes --no-headers | wc -l | tr -d ' ')
if [ "$nodes" = 1 ]; then
  ok "single node: $(oc get nodes -o jsonpath='{.items[0].metadata.name} ({.items[0].metadata.labels.node\.kubernetes\.io/instance-type})')"
else
  warn "$nodes nodes -- not SNO; consider HARNESS_PROFILE=aws"
fi
[ "$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')" = SingleReplica ] \
  && ok "controlPlaneTopology=SingleReplica" || warn "controlPlaneTopology=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')"

echo "== 2. GPU =="
total=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')
used=$(oc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.nvidia\.com/gpu}{"\n"}{end}{end}' | awk '{s+=$1} END{print s+0}')
product=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null)
[ "$total" -gt 0 ] && ok "GPU ${product:-?}: allocatable $total, free $((total - used))" \
  || bad "no allocatable nvidia.com/gpu (oc get clusterpolicy; oc get pods -n nvidia-gpu-operator)"
if [ "$total" -gt 0 ] && [ "$used" -ge "$total" ]; then
  warn "no idle GPU -- llmd-test-up stays Pending until one of these is removed or scaled to 0:"
  oc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' \
    | awk '$2>0{print "         " $1 " (gpu " $2 ")"}'
fi

echo "== 3. Versions =="
ok "OpenShift $(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
rhoai=$(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift AI")]}{.spec.version}{end}' 2>/dev/null)
case "$rhoai" in 3.5.*|3.[6-9].*) ok "RHOAI $rhoai" ;; "") bad "RHOAI operator not installed (oc get csv -n redhat-ods-operator)" ;; *) bad "RHOAI $rhoai -- harness needs 3.5+" ;; esac
[ "$(oc get datasciencecluster -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
  && ok "DataScienceCluster $(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}') Ready" || bad "DataScienceCluster not Ready"
oc get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1 && ok "LLMInferenceService CRD" || bad "LLMInferenceService CRD missing"

echo "== 4. LLMInferenceServiceConfig =="
pfx=$(oc get llminferenceserviceconfig -n redhat-ods-applications -o name 2>/dev/null \
  | sed -n 's#.*/\(v[0-9-]*\)-kserve-config-llm-tokenizer$#\1#p' | head -1)
[ -n "$pfx" ] && ok "config prefix $pfx (llmd-test-up rewrites manifest baseRefs to it)" || warn "no *-kserve-config-llm-tokenizer config"

echo "== 5. Operators =="
csvs=$(oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | sort -u)
for o in rhcl-operator:"RHCL (harness.sh maas / sno-enable-features)" servicemeshoperator3:"Service Mesh 3" \
         tempo-operator:"Tempo (harness.sh tracing)" opentelemetry-operator:"OpenTelemetry (harness.sh tracing)" \
         cluster-observability-operator:"COO (harness.sh tracing)"; do
  grep -q "^${o%%:*}" <<< "$csvs" && ok "${o#*:}: $(grep "^${o%%:*}" <<< "$csvs" | head -1)" || warn "${o#*:}: not installed"
done

echo "== 6. Scenario fit ($total GPU) =="
for e in ${SNO_GPU_NEEDS:-}; do
  s=${e%%:*}; n=${e#*:}
  [ "$total" -ge "$n" ] && echo "  [RUN]  $s (needs $n)" || echo "  [SKIP] $s (needs $n GPU)"
done
echo "  [RUN]  others (1 GPU, llmd-test replicas 1)"
[ "${GPU_ROLLOUT:-surge}" = recreate ] && echo "         GPU_ROLLOUT=recreate: tracing / vLLM-arg changes scale the model to 0 and back (brief outage)"
exit $FAIL
