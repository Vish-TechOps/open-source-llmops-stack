#!/usr/bin/env bash
# Undo 90-pause.sh: restore node pool sizes and autoscaling from .env, then wait for workloads.
source "$(dirname "$0")/lib.sh"
load_env
need gcloud kubectl

resume() { # pool min max
  gcloud container node-pools describe "$1" --cluster "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1 || return 0
  step "$1 -> $2..$3 nodes"
  gcloud container node-pools update "$1" --cluster "$CLUSTER_NAME" --zone "$ZONE" \
    --enable-autoscaling --min-nodes "$2" --max-nodes "$3" --quiet >/dev/null
  gcloud container clusters resize "$CLUSTER_NAME" --node-pool "$1" --num-nodes "$2" --zone "$ZONE" --quiet >/dev/null
  ok "resized"
}
resume model-pool "$MODEL_NODES_MIN" "$MODEL_NODES_MAX"
resume app-pool "$APP_NODES_MIN" "$APP_NODES_MAX"

use_cluster
step "Waiting for pods (vLLM needs 5-10 minutes to start again)"
for ns in "$NS_LANGFUSE" "$NS_APP" "$NS_LLMD"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl wait --for=condition=Ready pod --all -n "$ns" --timeout=30m --field-selector=status.phase!=Succeeded >/dev/null 2>&1 \
    && ok "$ns ready" || warn "$ns: some pods not ready yet (kubectl get pods -n $ns)"
done
done_msg "Resumed."
