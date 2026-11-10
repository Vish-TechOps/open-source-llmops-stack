#!/usr/bin/env bash
# GCP phase B — self-hosted Langfuse (Helm chart 2.2.4 = Langfuse v4) with headless init:
# org, project, API keys and an admin user are created at first start, so nothing has
# to be clicked before LiteLLM can send traces. Secrets are generated once into run/langfuse.env.
source "$(dirname "$0")/lib.sh"
load_env
need helm kubectl openssl
use_cluster
LF_ENV="$RUN_DIR/langfuse.env"
UI_PORT="${LANGFUSE_UI_PORT:-3300}"

step "Secrets (generated once, kept in run/langfuse.env, mode 600)"
if [ ! -f "$LF_ENV" ]; then
  rnd() { openssl rand -hex "$1"; }
  umask 077
  cat >"$LF_ENV" <<EOF
LF_SALT=$(rnd 16)
LF_ENCRYPTION_KEY=$(rnd 32)
LF_NEXTAUTH_SECRET=$(rnd 32)
LF_PG_PASSWORD=$(rnd 16)
LF_CH_PASSWORD=$(rnd 16)
LF_REDIS_PASSWORD=$(rnd 16)
LF_S3_USER=langfuse$(rnd 4)
LF_S3_PASSWORD=$(rnd 16)
LANGFUSE_PUBLIC_KEY=pk-lf-$(rnd 16)
LANGFUSE_SECRET_KEY=sk-lf-$(rnd 24)
LANGFUSE_ADMIN_PASSWORD=$(rnd 12)
EOF
  ok "generated"
else
  ok "reusing existing run/langfuse.env"
fi
# shellcheck disable=SC1090
. "$LF_ENV"

kubectl create secret generic langfuse -n "$NS_LANGFUSE" --dry-run=client -o yaml \
  --from-literal=salt="$LF_SALT" \
  --from-literal=encryption-key="$LF_ENCRYPTION_KEY" \
  --from-literal=nextauth-secret="$LF_NEXTAUTH_SECRET" \
  --from-literal=postgresql-password="$LF_PG_PASSWORD" \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$LF_PG_PASSWORD" \
  --from-literal=POSTGRES_DB=langfuse \
  --from-literal=USERDB_USER=langfuse \
  --from-literal=USERDB_PASSWORD="$LF_PG_PASSWORD" \
  --from-literal=clickhouse-password="$LF_CH_PASSWORD" \
  --from-literal=redis-password="$LF_REDIS_PASSWORD" \
  --from-literal=default="$LF_REDIS_PASSWORD" \
  --from-literal=s3-user="$LF_S3_USER" \
  --from-literal=s3-password="$LF_S3_PASSWORD" \
  --from-literal=seaweedfs_s3_config="{\"identities\":[{\"name\":\"$LF_S3_USER\",\"credentials\":[{\"accessKey\":\"$LF_S3_USER\",\"secretKey\":\"$LF_S3_PASSWORD\"}],\"actions\":[\"Admin\",\"Read\",\"Write\",\"List\",\"Tagging\"]}]}" \
  | kubectl apply -f - >/dev/null
kubectl create secret generic langfuse-init -n "$NS_LANGFUSE" --dry-run=client -o yaml \
  --from-literal=LANGFUSE_INIT_ORG_ID=llmops-org \
  --from-literal=LANGFUSE_INIT_ORG_NAME=LLMOps \
  --from-literal=LANGFUSE_INIT_PROJECT_ID=llmops-stack \
  --from-literal=LANGFUSE_INIT_PROJECT_NAME=llmops-stack \
  --from-literal=LANGFUSE_INIT_PROJECT_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  --from-literal=LANGFUSE_INIT_PROJECT_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  --from-literal=LANGFUSE_INIT_USER_EMAIL="$LANGFUSE_ADMIN_EMAIL" \
  --from-literal=LANGFUSE_INIT_USER_NAME=admin \
  --from-literal=LANGFUSE_INIT_USER_PASSWORD="$LANGFUSE_ADMIN_PASSWORD" \
  | kubectl apply -f - >/dev/null
ok "Secrets langfuse and langfuse-init in $NS_LANGFUSE"

step "helm upgrade --install langfuse (chart $LANGFUSE_CHART_VERSION)"
info "First install pulls Postgres, ClickHouse, Valkey and SeaweedFS: 5-10 minutes."
helm upgrade --install langfuse oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse \
  --version "$LANGFUSE_CHART_VERSION" -n "$NS_LANGFUSE" \
  -f "$MANIFESTS/phase-b/langfuse-values.yaml" \
  --set langfuse.nextauth.url="http://localhost:${UI_PORT}" \
  --wait --timeout 20m
kubectl get pods -n "$NS_LANGFUSE" | sed 's/^/  /'

step "Health from inside the cluster"
ensure_curl_pod "$NS_APP"
for _ in $(seq 1 30); do
  h=$(kubectl exec -n "$NS_APP" curl-client -- curl -s --max-time 5 "http://langfuse-web.${NS_LANGFUSE}.svc.cluster.local:3000/api/public/health" || true)
  [ -n "$h" ] && echo "$h" | jq -e '.status=="OK"' >/dev/null 2>&1 && break
  sleep 10
done
echo "$h" | jq -e '.status=="OK"' >/dev/null 2>&1 && ok "Langfuse $(echo "$h" | jq -r .version) healthy" || die "Langfuse not healthy: kubectl logs -n $NS_LANGFUSE deploy/langfuse-web"
code=$(kubectl exec -n "$NS_APP" curl-client -- curl -s -o /dev/null -w '%{http_code}' \
  -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" "http://langfuse-web.${NS_LANGFUSE}.svc.cluster.local:3000/api/public/projects")
[ "$code" = "200" ] && ok "headless-init API keys accepted" || die "API keys rejected (HTTP $code): headless init did not run? kubectl logs -n $NS_LANGFUSE deploy/langfuse-web | grep -i init"

cat <<EOF

  Open the UI (from Cloud Shell or any machine with kubectl access to the cluster):
    kubectl port-forward -n $NS_LANGFUSE svc/langfuse-web ${UI_PORT}:3000
    http://localhost:${UI_PORT}   login: $LANGFUSE_ADMIN_EMAIL   password: in run/langfuse.env (LANGFUSE_ADMIN_PASSWORD)
  Port ${UI_PORT}, not 3000, so it does not clash with your local Langfuse.
EOF
done_msg "Langfuse ready. Next: scripts/b13-build-images.sh"
