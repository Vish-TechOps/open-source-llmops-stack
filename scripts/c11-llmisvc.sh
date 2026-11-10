#!/usr/bin/env bash
# GCP phase C — deploy Qwen3-0.6B through KServe, BESIDE the phase A deployment.
# KServe creates vLLM pods + EPP + InferencePool; this script adds the GKE route
# (header-gated: x-llm-backend: kserve) and the GKE health-check/backend policies.
# The model pool autoscales up to MODEL_NODES_MAX for the extra pods.
source "$(dirname "$0")/lib.sh"
load_env
need kubectl
use_cluster
kubectl get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1 || die "run c10 first"
export LLMISVC_NAME NS_LLMD MODEL VLLM_CPU_IMAGE VLLM_REPLICAS

step "HTTPRoute $LLMISVC_NAME-route (header x-llm-backend: kserve) + GKE policies"
render "$MANIFESTS/phase-c/httproute-kserve.yaml.tmpl" LLMISVC_NAME NS_LLMD | kubectl apply -f -
render "$MANIFESTS/phase-c/gke-policies.yaml.tmpl" LLMISVC_NAME NS_LLMD | kubectl apply -f -

step "LLMInferenceService $LLMISVC_NAME"
render "$MANIFESTS/phase-c/llmisvc-qwen.yaml.tmpl" LLMISVC_NAME NS_LLMD MODEL VLLM_CPU_IMAGE VLLM_REPLICAS | kubectl apply -f -
info "KServe downloads the model (storage initializer), the autoscaler may add C3 nodes: 5-15 minutes."
kubectl wait --for=condition=Ready "llminferenceservice/$LLMISVC_NAME" -n "$NS_LLMD" --timeout=40m \
  || { kubectl describe llminferenceservice "$LLMISVC_NAME" -n "$NS_LLMD" | tail -40; die "not Ready"; }
ok "Ready"

step "What KServe created"
kubectl get pods,svc,inferencepool -n "$NS_LLMD" -l "app.kubernetes.io/name=$LLMISVC_NAME" 2>/dev/null | sed 's/^/  /'
kubectl get inferencepool -n "$NS_LLMD" | sed 's/^/  /'
kubectl get httproute -n "$NS_LLMD" | sed 's/^/  /'

done_msg "KServe deployment ready beside phase A. Next: scripts/c12-test-kserve.sh"
