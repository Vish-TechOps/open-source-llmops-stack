#!/usr/bin/env bash
# GCP phase B — LiteLLM gateway in the cluster:
#   qwen-cpu         -> GKE Inference Gateway -> llm-d -> vLLM CPU (phase A)
#   gemini           -> Vertex AI via Workload Identity
#   gemini-embedding -> Vertex AI embeddings (for Ragas)
# with Guardrails AI on every call and every call traced to the self-hosted Langfuse.
source "$(dirname "$0")/lib.sh"
load_env
need kubectl jq openssl sha256sum
use_cluster
[ -f "$RUN_DIR/images.env" ] || die "run b13 first"
[ -f "$RUN_DIR/langfuse.env" ] || die "run b12 first"
# shellcheck disable=SC1091
. "$RUN_DIR/images.env"
# shellcheck disable=SC1091
. "$RUN_DIR/langfuse.env"
GATEWAY_IP=$(gateway_ip)
[ -n "$GATEWAY_IP" ] || die "Inference Gateway has no address (phase A)"
export GATEWAY_IP LITELLM_IMAGE

step "Master key (generated once into run/litellm.env)"
if [ ! -f "$RUN_DIR/litellm.env" ]; then
  (umask 077; echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)" >"$RUN_DIR/litellm.env")
  ok "generated"
else
  ok "reusing run/litellm.env"
fi
# shellcheck disable=SC1091
. "$RUN_DIR/litellm.env"

step "Secret litellm-env + ConfigMap litellm-config"
kubectl create secret generic litellm-env -n "$NS_APP" --dry-run=client -o yaml \
  --from-literal=LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  --from-literal=LANGFUSE_HOST="http://langfuse-web.${NS_LANGFUSE}.svc.cluster.local:3000" \
  --from-literal=LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  --from-literal=LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  | kubectl apply -f - >/dev/null
render "$ROOT_DIR/config/litellm.config.yaml.tmpl" MODEL GATEWAY_IP PROJECT_ID VERTEX_CHAT_MODEL \
  VERTEX_LOCATION VERTEX_EMBEDDING_MODEL VERTEX_EMBEDDING_LOCATION NS_APP >"$RUN_DIR/litellm.config.yaml"
kubectl create configmap litellm-config -n "$NS_APP" --from-file=config.yaml="$RUN_DIR/litellm.config.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
CONFIG_SHA=$(sha256sum "$RUN_DIR/litellm.config.yaml" | cut -c1-16)
export CONFIG_SHA
ok "qwen-cpu -> http://$GATEWAY_IP/v1, gemini -> vertex_ai/$VERTEX_CHAT_MODEL ($VERTEX_LOCATION)"

step "Deploy LiteLLM ($LITELLM_IMAGE)"
render "$MANIFESTS/phase-b/litellm.yaml.tmpl" NS_APP LITELLM_IMAGE CONFIG_SHA | kubectl apply -f -
kubectl rollout status deploy/litellm -n "$NS_APP" --timeout=10m

step "Models served"
ensure_curl_pod "$NS_APP"
kubectl exec -n "$NS_APP" curl-client -- curl -s "http://litellm.${NS_APP}.svc.cluster.local:4000/v1/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq -r '.data[].id' | sed 's/^/  /'

done_msg "LiteLLM ready. Next: scripts/b16-smoke-test.sh"
