#!/usr/bin/env bash
# Preflight for all GCP phases: tools, login, project, .env. Changes nothing.
source "$(dirname "$0")/lib.sh"
load_env

errors=0
bad() { fail "$*"; errors=$((errors + 1)); }

step "Tools (Cloud Shell has all of these)"
for c in gcloud kubectl helm jq git envsubst curl openssl; do
  if command -v "$c" >/dev/null; then ok "$c"; else bad "$c not found"; fi
done
if command -v helm >/dev/null; then
  hv=$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')
  read -r hmaj hmin <<<"$hv"
  { [ "${hmaj:-0}" -gt 3 ] || { [ "${hmaj:-0}" -eq 3 ] && [ "${hmin:-0}" -ge 8 ]; }; } \
    && ok "helm $(helm version --short) supports OCI charts" || bad "helm >= 3.8 needed for OCI charts"
fi

step "gcloud"
acct=$(gcloud config get-value account 2>/dev/null || true)
[ -n "$acct" ] && ok "logged in as $acct" || bad "not logged in: gcloud auth login"
if gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1; then
  ok "project $PROJECT_ID reachable"
  billing=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo unknown)
  [ "$billing" = "True" ] && ok "billing enabled" || warn "billing state: $billing (needs to be enabled)"
else
  bad "cannot access project $PROJECT_ID"
fi

step ".env"
[ "$(stat -c '%a' "$ENV_FILE")" = "600" ] && ok ".env is mode 600" || warn "run: chmod 600 .env"
[[ "${LANGFUSE_ADMIN_EMAIL:-}" == *@* && "$LANGFUSE_ADMIN_EMAIL" != "you@example.com" ]] \
  && ok "LANGFUSE_ADMIN_EMAIL set" || warn "set LANGFUSE_ADMIN_EMAIL before phase B"
[ -n "${LITELLM_SHA256:-}" ] && ok "LITELLM_SHA256 set" || bad "LITELLM_SHA256 empty (use the hash you verified for local phase A)"
for v in 1.82.7 1.82.8 1.107.0; do [ "${LITELLM_VERSION:-}" = "$v" ] && bad "LiteLLM $v is a known-malicious release"; done
gcloud compute machine-types describe "$MODEL_MACHINE" --zone "$ZONE" --format='value(name)' >/dev/null 2>&1 \
  && ok "$MODEL_MACHINE available in $ZONE" || bad "$MODEL_MACHINE not offered in $ZONE: pick another ZONE"

step "Quota (CPUs in $REGION)"
q=$(gcloud compute regions describe "$REGION" --format=json 2>/dev/null \
  | jq -r '.quotas[] | select(.metric=="CPUS") | "\(.usage) \(.limit)"' || true)
if [ -n "$q" ]; then
  read -r used limit <<<"$q"
  need_cpu=$(( 4 + 8 * ${MODEL_NODES_MAX:-4} + 8 * ${APP_NODES_MAX:-2} ))
  info "CPUs used ${used%.*} of ${limit%.*}; this stack can grow to ~${need_cpu}"
  [ $(( ${limit%.*} - ${used%.*} )) -ge "$need_cpu" ] && ok "enough CPU quota" \
    || warn "CPU quota may be tight at peak (phase C). Lower MODEL_NODES_MAX/APP_NODES_MAX or request more"
  c3=$(gcloud compute regions describe "$REGION" --format=json | jq -r '.quotas[] | select(.metric=="C3_CPUS") | "\(.usage) \(.limit)"' || true)
  [ -n "$c3" ] && info "C3 CPUs: $c3 (used limit)"
else
  warn "could not read quotas"
fi

echo
if [ "$errors" -eq 0 ]; then done_msg "Preflight passed. Next: scripts/a10-project-setup.sh"
else printf '%s%d problem(s).%s\n' "$C_ERR" "$errors" "$C_OFF"; exit 1; fi
