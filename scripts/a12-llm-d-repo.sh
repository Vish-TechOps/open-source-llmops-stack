#!/usr/bin/env bash
# GCP phase A — fetch the llm-d repo (values files + model-server kustomize bases),
# drop in this bundle's Qwen3-0.6B CPU overlay, make sure the InferencePool CRD exists,
# and create the namespace (+ optional Hugging Face secret).
source "$(dirname "$0")/lib.sh"
load_env
need git kubectl
use_cluster

step "llm-d repo ($LLMD_BRANCH) -> $LLMD_REPO"
if [ -d "$LLMD_REPO/.git" ]; then
  git -C "$LLMD_REPO" fetch -q --depth 1 origin "$LLMD_BRANCH" && git -C "$LLMD_REPO" checkout -q FETCH_HEAD
  ok "updated"
else
  git clone -q --depth 1 -b "$LLMD_BRANCH" https://github.com/llm-d/llm-d.git "$LLMD_REPO"
  ok "cloned"
fi
# shellcheck disable=SC1091
REPO_ROOT="$LLMD_REPO" source "$LLMD_REPO/guides/env.sh"
info "GAIE $GAIE_VERSION, router chart $ROUTER_CHART_VERSION"

step "Qwen3-0.6B CPU overlay"
OVERLAY="$LLMD_REPO/guides/optimized-baseline/modelserver/cpu/vllm/qwen3-gke"
mkdir -p "$OVERLAY"
cp "$MANIFESTS/phase-a/vllm-qwen-cpu/kustomization.yaml" "$OVERLAY/"
render "$MANIFESTS/phase-a/vllm-qwen-cpu/patch-qwen.yaml.tmpl" MODEL VLLM_CPU_IMAGE VLLM_REPLICAS >"$OVERLAY/patch-qwen.yaml"
kubectl kustomize "$OVERLAY" >"$RUN_DIR/vllm-rendered.yaml"
ok "rendered $(grep -c '^kind:' "$RUN_DIR/vllm-rendered.yaml") objects -> run/vllm-rendered.yaml"

step "InferencePool CRD"
if kubectl api-resources --api-group=inference.networking.k8s.io 2>/dev/null | grep -q '^inferencepools'; then
  ok "present (GKE-managed)"
else
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml"
  ok "installed GAIE $GAIE_VERSION CRDs"
fi

step "Namespace $NS_LLMD"
ensure_ns "$NS_LLMD"
ok "ready"
if [ -n "${HF_TOKEN:-}" ]; then
  kubectl create secret generic llm-d-hf-token -n "$NS_LLMD" --from-literal=HF_TOKEN="$HF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Hugging Face token secret"
else
  info "no HF_TOKEN: the model downloads anonymously (fine for Qwen3-0.6B)"
fi

done_msg "Repo and namespace ready. Next: scripts/a13-gateway.sh"
