#!/usr/bin/env bash
# Save money between sessions: scale the model and app node pools to 0 nodes.
# Keeps the cluster, disks (Langfuse data), Gateway and everything deployed.
# What still costs money while paused: the system node, the zonal cluster fee
# (covered by GKE's free tier for one zonal cluster), persistent disks, the internal LB.
# Resume with scripts/91-resume.sh.
source "$(dirname "$0")/lib.sh"
load_env
need gcloud

for pool in model-pool app-pool; do
  if gcloud container node-pools describe "$pool" --cluster "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
    step "$pool -> 0 nodes"
    gcloud container node-pools update "$pool" --cluster "$CLUSTER_NAME" --zone "$ZONE" \
      --enable-autoscaling --min-nodes 0 --max-nodes 0 --quiet >/dev/null
    gcloud container clusters resize "$CLUSTER_NAME" --node-pool "$pool" --num-nodes 0 --zone "$ZONE" --quiet >/dev/null
    ok "scaled to 0"
  fi
done
done_msg "Paused. Resume: scripts/91-resume.sh"
