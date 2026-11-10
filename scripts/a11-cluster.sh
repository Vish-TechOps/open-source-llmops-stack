#!/usr/bin/env bash
# GCP phase A — zonal GKE cluster with Gateway API + Workload Identity, and a tainted
# C3 node pool for vLLM. ~10 minutes. Idempotent (skips what exists).
source "$(dirname "$0")/lib.sh"
load_env
need gcloud kubectl

step "Cluster $CLUSTER_NAME ($ZONE, channel $RELEASE_CHANNEL)"
if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  ok "exists"
else
  # --gateway-api=standard: GKE installs Gateway API CRDs and (1.34.0-gke.1626000+) the v1 InferencePool CRD.
  # --workload-pool: Workload Identity, so LiteLLM calls Vertex AI without a key file (phase B).
  gcloud container clusters create "$CLUSTER_NAME" \
    --project "$PROJECT_ID" --zone "$ZONE" \
    --release-channel "$RELEASE_CHANNEL" \
    --machine-type "$SYSTEM_MACHINE" --num-nodes 1 \
    --gateway-api=standard \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-ip-alias \
    --addons=HttpLoadBalancing \
    --monitoring=SYSTEM --logging=SYSTEM,WORKLOAD
  ok "created"
fi
use_cluster
ver=$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --format='value(currentMasterVersion)')
ok "control plane $ver"

step "Model node pool model-pool ($MODEL_MACHINE, $MODEL_NODES_MIN..$MODEL_NODES_MAX, tainted workload=model)"
if gcloud container node-pools describe model-pool --cluster "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  ok "exists"
else
  gcloud container node-pools create model-pool \
    --cluster "$CLUSTER_NAME" --zone "$ZONE" \
    --machine-type "$MODEL_MACHINE" \
    --num-nodes "$MODEL_NODES_MIN" --enable-autoscaling \
    --min-nodes "$MODEL_NODES_MIN" --max-nodes "$MODEL_NODES_MAX" \
    --node-taints workload=model:NoSchedule \
    --node-labels workload=model \
    --disk-size 100 --workload-metadata=GKE_METADATA
  ok "created"
fi

step "APIs available in the cluster"
for _ in $(seq 1 30); do
  kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null | grep -q '^gateways' && break
  sleep 10
done
kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q '^gateways' && ok "Gateway API" || die "Gateway API CRDs missing"
if kubectl api-resources --api-group=inference.networking.k8s.io 2>/dev/null | grep -q '^inferencepools'; then
  ok "InferencePool v1 (managed by GKE)"
else
  warn "InferencePool CRD not installed by GKE (control plane $ver < 1.34.0-gke.1626000?) — a12 installs it"
fi
kubectl get gatewayclass gke-l7-rilb >/dev/null 2>&1 && ok "GatewayClass gke-l7-rilb" || warn "GatewayClass gke-l7-rilb not visible yet (can take a few minutes)"
kubectl get nodes -L cloud.google.com/gke-nodepool --no-headers | awk '{print "  " $1, $NF}'

done_msg "Cluster ready. Next: scripts/a12-llm-d-repo.sh"
