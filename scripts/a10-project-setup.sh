#!/usr/bin/env bash
# GCP phase A — project setup: APIs, proxy-only subnet (for the internal Inference Gateway),
# Artifact Registry repo (used in phase B). Idempotent.
source "$(dirname "$0")/lib.sh"
load_env
need gcloud

step "Enable APIs (takes a minute the first time)"
gcloud services enable \
  container.googleapis.com compute.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com \
  aiplatform.googleapis.com iam.googleapis.com \
  --project "$PROJECT_ID"
ok "container, compute, artifactregistry, cloudbuild, aiplatform, iam"

step "Proxy-only subnet in $REGION (required by gke-l7-rilb)"
existing=$(gcloud compute networks subnets list --project "$PROJECT_ID" \
  --filter="region:($REGION) AND purpose=REGIONAL_MANAGED_PROXY AND role=ACTIVE" \
  --format='value(name,ipCidrRange)' | head -1)
if [ -n "$existing" ]; then
  ok "already present: $existing"
else
  gcloud compute networks subnets create "proxy-only-$REGION" \
    --project "$PROJECT_ID" --region "$REGION" --network "$NETWORK" \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --range="$PROXY_ONLY_SUBNET_RANGE"
  ok "created proxy-only-$REGION ($PROXY_ONLY_SUBNET_RANGE)"
fi

step "Artifact Registry repo $AR_REPO ($REGION)"
if gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  ok "exists"
else
  gcloud artifacts repositories create "$AR_REPO" --repository-format=docker \
    --location "$REGION" --project "$PROJECT_ID" --description "llmops-stack images"
  ok "created"
fi

done_msg "Project ready. Next: scripts/a11-cluster.sh"
