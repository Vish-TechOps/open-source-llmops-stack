#!/usr/bin/env bash
# GCP phase C — KServe LLMInferenceService controller (KServe v0.21), installed the way
# KServe's own quick-install does it, minus the parts GKE already provides:
#   - no Envoy Gateway / Istio: the GKE Gateway from phase A is used
#   - createGIECRDs=false: GKE manages the InferencePool CRD
#   - no LeaderWorkerSet: only needed for multi-node models
# cert-manager comes from b11.
source "$(dirname "$0")/lib.sh"
load_env
need helm kubectl
use_cluster
CHARTS=oci://ghcr.io/kserve/charts

step "cert-manager present"
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || die "cert-manager missing: run b11 first"
ok "yes"

step "kserve-llmisvc-crd $KSERVE_VERSION"
helm upgrade --install kserve-llmisvc-crd "$CHARTS/kserve-llmisvc-crd" --version "$KSERVE_VERSION" \
  -n kserve --create-namespace --wait --timeout 10m >/dev/null
kubectl wait --for=condition=Established crd/llminferenceservices.serving.kserve.io --timeout=120s >/dev/null
ok "CRDs LLMInferenceService / LLMInferenceServiceConfig"

step "kserve-llmisvc-resources $KSERVE_VERSION (controller)"
helm upgrade --install kserve-llmisvc-resources "$CHARTS/kserve-llmisvc-resources" --version "$KSERVE_VERSION" \
  -n kserve --set kserve.version="$KSERVE_VERSION" \
  --set kserve.llmisvc.createGIECRDs=false \
  --set kserve.llmisvc.controller.imagePullPolicy=IfNotPresent \
  --wait --timeout 10m >/dev/null
kubectl rollout status deploy/llmisvc-controller-manager -n kserve --timeout=5m
# The config presets below are checked by the controller's webhook: wait until it has endpoints.
for _ in $(seq 1 30); do
  ep=$(kubectl get endpoints llmisvc-webhook-server-service -n kserve -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  [ -n "$ep" ] && break; sleep 5
done
[ -n "$ep" ] && ok "controller + webhook ready" || die "llmisvc webhook has no endpoints: kubectl get pods -n kserve"

step "kserve-runtime-configs $KSERVE_VERSION (LLMInferenceServiceConfig presets only)"
helm upgrade --install kserve-runtime-configs "$CHARTS/kserve-runtime-configs" --version "$KSERVE_VERSION" \
  -n kserve --set kserve.version="$KSERVE_VERSION" \
  --set kserve.servingruntime.enabled=false --set kserve.llmisvcConfigs.enabled=true \
  --wait --timeout 10m >/dev/null
kubectl get llminferenceserviceconfig -n kserve --no-headers 2>/dev/null | awk '{print "  " $1}'
ok "presets installed"

done_msg "KServe ready. Next: scripts/c11-llmisvc.sh"
