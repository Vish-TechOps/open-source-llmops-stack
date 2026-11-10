#!/usr/bin/env bash
# Delete everything this bundle created that costs money.
#   default        : the GKE cluster (and with it the Gateway's load balancer, nodes, disks)
#   --all          : also the Artifact Registry repo, the proxy-only subnet, the build SA and IAM bindings
# Asks for confirmation. run/ (generated secrets) is kept; delete it yourself if you like.
source "$(dirname "$0")/lib.sh"
load_env
need gcloud

echo "This deletes cluster $CLUSTER_NAME in $PROJECT_ID${1:+ and shared resources ($1)}."
read -r -p "Type the cluster name to confirm: " answer
[ "$answer" = "$CLUSTER_NAME" ] || die "not confirmed"

step "Delete cluster $CLUSTER_NAME (5-10 minutes)"
if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE" --quiet
  ok "deleted"
else
  ok "already gone"
fi
info "If a load balancer was mid-provisioning, check: gcloud compute forwarding-rules list --regions $REGION"

if [ "${1:-}" = "--all" ]; then
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  step "Artifact Registry repo $AR_REPO"
  gcloud artifacts repositories delete "$AR_REPO" --location "$REGION" --quiet 2>/dev/null && ok "deleted" || ok "not found"
  step "Proxy-only subnet proxy-only-$REGION"
  gcloud compute networks subnets delete "proxy-only-$REGION" --region "$REGION" --quiet 2>/dev/null && ok "deleted" \
    || info "not deleted (absent, or still used by another load balancer)"
  step "IAM"
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" --role roles/aiplatform.user --condition=None \
    --member "principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NS_APP}/sa/litellm" \
    >/dev/null 2>&1 && ok "Workload Identity binding removed" || ok "binding not found"
  BUILD_SA="llmops-build@${PROJECT_ID}.iam.gserviceaccount.com"
  for role in roles/artifactregistry.writer roles/logging.logWriter roles/storage.objectViewer; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$BUILD_SA" --role "$role" --condition=None >/dev/null 2>&1 || true
  done
  gcloud iam service-accounts delete "$BUILD_SA" --quiet 2>/dev/null && ok "build service account deleted" || ok "build service account not found"
fi
done_msg "Teardown finished."
