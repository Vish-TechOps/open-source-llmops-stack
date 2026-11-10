#!/usr/bin/env bash
# GCP phase A — real vLLM CPU pods (Qwen3-0.6B), one per C3 node. The InferencePool
# picks them up through their labels: no router change needed (same as the simulators locally).
source "$(dirname "$0")/lib.sh"
load_env
need kubectl
use_cluster
OVERLAY="$LLMD_REPO/guides/optimized-baseline/modelserver/cpu/vllm/qwen3-gke"
[ -d "$OVERLAY" ] || die "run a12 first"

step "Apply vLLM ($MODEL x $VLLM_REPLICAS)"
kubectl apply -n "$NS_LLMD" -k "$OVERLAY"
info "First start pulls a ~3 GB image and downloads the weights: 5-10 minutes."
kubectl rollout status deploy/optimized-baseline-cpu-vllm-decode -n "$NS_LLMD" --timeout=30m
kubectl get pods -n "$NS_LLMD" -l llm-d.ai/guide=optimized-baseline -o wide | sed 's/^/  /'

step "Router sees the pods"
sleep 5
kubectl logs -n "$NS_LLMD" "deploy/${ROUTER_RELEASE}-epp" --tail=200 2>/dev/null | grep -i 'pod added' | tail -5 | cut -c1-200 | sed 's/^/  /' \
  || info "no 'Pod added' lines yet (log format may differ); a16 checks routing end to end"

step "Gateway backend health"
info "GKE health-checks the pods on /health through the HealthCheckPolicy; first green can take ~1-2 min."

done_msg "Model servers ready. Next: scripts/a16-test-routing.sh"
