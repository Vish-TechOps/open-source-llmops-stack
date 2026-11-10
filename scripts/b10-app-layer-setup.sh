#!/usr/bin/env bash
# GCP phase B — app node pool, namespaces, and IAM:
#  - Workload Identity: the "litellm" Kubernetes ServiceAccount may call Vertex AI (no key)
#  - Cloud Build service account that can push to Artifact Registry
#  - GKE nodes can pull from Artifact Registry
source "$(dirname "$0")/lib.sh"
load_env
need gcloud kubectl
use_cluster
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

step "App node pool app-pool ($APP_MACHINE, $APP_NODES_MIN..$APP_NODES_MAX)"
if gcloud container node-pools describe app-pool --cluster "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  ok "exists"
else
  gcloud container node-pools create app-pool \
    --cluster "$CLUSTER_NAME" --zone "$ZONE" \
    --machine-type "$APP_MACHINE" \
    --num-nodes "$APP_NODES_MIN" --enable-autoscaling \
    --min-nodes "$APP_NODES_MIN" --max-nodes "$APP_NODES_MAX" \
    --node-labels workload=app \
    --disk-size 100 --workload-metadata=GKE_METADATA
  ok "created"
fi

step "Namespaces"
ensure_ns "$NS_APP"; ensure_ns "$NS_LANGFUSE"
ok "$NS_APP, $NS_LANGFUSE"

step "Workload Identity: ns/$NS_APP/sa/litellm -> roles/aiplatform.user"
MEMBER="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NS_APP}/sa/litellm"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "$MEMBER" \
  --role roles/aiplatform.user --condition=None >/dev/null
ok "bound (direct principal, no Google service account or key file)"

step "Cloud Build service account llmops-build"
BUILD_SA="llmops-build@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$BUILD_SA" >/dev/null 2>&1 \
  || gcloud iam service-accounts create llmops-build --display-name "llmops-stack image builds" >/dev/null
for role in roles/artifactregistry.writer roles/logging.logWriter roles/storage.objectViewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$BUILD_SA" \
    --role "$role" --condition=None >/dev/null
done
ok "$BUILD_SA: artifactregistry.writer, logging.logWriter, storage.objectViewer"
# The person running b13 must be allowed to run builds as that account.
gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA" \
  --member "user:$(gcloud config get-value account)" --role roles/iam.serviceAccountUser >/dev/null
ok "you can act as it"

step "Nodes can pull from Artifact Registry"
NODE_SA=$(gcloud container node-pools describe app-pool --cluster "$CLUSTER_NAME" --zone "$ZONE" \
  --format='value(config.serviceAccount)')
[ "$NODE_SA" = "default" ] && NODE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" --location "$REGION" \
  --member "serviceAccount:$NODE_SA" --role roles/artifactregistry.reader >/dev/null
ok "$NODE_SA: artifactregistry.reader on $AR_REPO"

done_msg "App layer prerequisites ready. Next: scripts/b11-operators.sh"
