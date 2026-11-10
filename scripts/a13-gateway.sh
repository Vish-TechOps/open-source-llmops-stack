#!/usr/bin/env bash
# GCP phase A — the Inference Gateway: a GKE-managed regional *internal* Application
# Load Balancer (GatewayClass gke-l7-rilb), from llm-d's own gateway recipe.
# Internal = reachable only inside the VPC (pods, Cloud Shell needs port-forward), no public IP.
source "$(dirname "$0")/lib.sh"
load_env
need kubectl
use_cluster
[ -d "$LLMD_REPO" ] || die "run a12 first"

step "Gateway llm-d-inference-gateway (gke-l7-rilb) in $NS_LLMD"
kubectl apply -n "$NS_LLMD" -k "$LLMD_REPO/guides/recipes/gateway/gke-l7-rilb"
info "GKE provisions the load balancer; PROGRAMMED usually turns True in 2-5 minutes"
for _ in $(seq 1 60); do
  prog=$(kubectl get gateway llm-d-inference-gateway -n "$NS_LLMD" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [ "$prog" = "True" ] && break
  sleep 10
done
kubectl get gateway llm-d-inference-gateway -n "$NS_LLMD"
[ "$(kubectl get gateway llm-d-inference-gateway -n "$NS_LLMD" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" = "True" ] \
  || die "Gateway not programmed after 10 min: kubectl describe gateway llm-d-inference-gateway -n $NS_LLMD (proxy-only subnet? a10)"
ok "programmed, address $(gateway_ip)"

done_msg "Gateway ready. Next: scripts/a14-router.sh"
