#!/usr/bin/env bash
# GCP phase B — build the three app images with Cloud Build (no local Docker; works from a
# locked-down laptop or Cloud Shell) and push them to Artifact Registry.
#   litellm     pinned wheel, SHA-256 verified inside the build (fails on mismatch)
#   guardrails  Guardrails AI server + this stack's guards + LiteLLM key adapter
#   ragas       evaluation job
# Image references (with digests) are written to run/images.env for b14/b15/b17.
source "$(dirname "$0")/lib.sh"
load_env
need gcloud
BUILD_SA="projects/${PROJECT_ID}/serviceAccounts/llmops-build@${PROJECT_ID}.iam.gserviceaccount.com"

content_tag() { (cd "$1" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 cat | sha256sum | cut -c1-10); }

build() { # $1 name  $2 tag
  local dir="$ROOT_DIR/images/$1" image="$AR_PATH/$1:$2"
  if gcloud artifacts docker images describe "$image" >/dev/null 2>&1; then
    ok "$1:$2 already built" >&2
  else
    info "building $1:$2 (Cloud Build, 3-8 minutes)" >&2
    # ^~^ = use ~ as the substitution separator, because LANGFUSE_SDK_SPEC contains a comma
    gcloud builds submit "$dir" --region "$REGION" --project "$PROJECT_ID" \
      --config "$ROOT_DIR/images/cloudbuild.yaml" --service-account "$BUILD_SA" \
      --substitutions "^~^_IMAGE=${image}~_LITELLM_VERSION=${LITELLM_VERSION}~_LITELLM_SHA256=${LITELLM_SHA256}~_LANGFUSE_SDK_SPEC=${LANGFUSE_SDK_SPEC}" \
      >&2
    ok "$1:$2 pushed" >&2
  fi
  gcloud artifacts docker images describe "$image" --format='value(image_summary.fully_qualified_digest)'
}

step "Build images into $AR_PATH"
LITELLM_IMAGE=$(build litellm "$LITELLM_VERSION")
GUARDRAILS_IMAGE=$(build guardrails "0.11.0-$(content_tag "$ROOT_DIR/images/guardrails")")
RAGAS_IMAGE=$(build ragas "0.4.3-$(content_tag "$ROOT_DIR/images/ragas")")
cat >"$RUN_DIR/images.env" <<EOF
LITELLM_IMAGE=$LITELLM_IMAGE
GUARDRAILS_IMAGE=$GUARDRAILS_IMAGE
RAGAS_IMAGE=$RAGAS_IMAGE
EOF
sed 's/^/  /' "$RUN_DIR/images.env"
info "Deployed by digest, so a re-pushed tag can never change what runs."

done_msg "Images ready. Next: scripts/b14-guardrails.sh"
