#!/usr/bin/env bash
# GCP phase A — llm-d router in *gateway* mode (chart llm-d-router-gateway, provider gke):
# Endpoint Picker + InferencePool + HTTPRoute (Gateway -> InferencePool) + GKE
# HealthCheckPolicy/GCPBackendPolicy. Same values files as the local demo, plus a GKE size-down.
source "$(dirname "$0")/lib.sh"
load_env
need helm kubectl
use_cluster
[ -d "$LLMD_REPO" ] || die "run a12 first"
# shellcheck disable=SC1091
REPO_ROOT="$LLMD_REPO" source "$LLMD_REPO/guides/env.sh"

step "helm upgrade --install $ROUTER_RELEASE ($ROUTER_GATEWAY_CHART $ROUTER_CHART_VERSION)"
helm upgrade --install "$ROUTER_RELEASE" "$ROUTER_GATEWAY_CHART" --version "$ROUTER_CHART_VERSION" \
  -f "$LLMD_REPO/guides/recipes/router/base.values.yaml" \
  -f "$LLMD_REPO/guides/optimized-baseline/router/optimized-baseline.values.yaml" \
  -f "$ROOT_DIR/values/router-gke.values.yaml" \
  --set provider.name=gke \
  --set httpRoute.create=true \
  --set httpRoute.inferenceGatewayName=llm-d-inference-gateway \
  -n "$NS_LLMD" --wait --timeout 10m
ok "installed"

step "What the chart created"
kubectl get deploy,svc,inferencepool,httproute,healthcheckpolicy,gcpbackendpolicy -n "$NS_LLMD" 2>/dev/null | grep -v '^$' | sed 's/^/  /'
info "The InferencePool selects pods labelled llm-d.ai/guide=optimized-baseline; none exist until a15."

done_msg "Router ready. Next: scripts/a15-vllm.sh"
