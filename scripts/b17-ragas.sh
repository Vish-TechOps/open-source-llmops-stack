#!/usr/bin/env bash
# GCP phase B — Ragas evaluation as a Kubernetes Job: the test set goes through LiteLLM to
# each model (each answer = a Langfuse trace), Gemini judges, scores land on those traces.
# usage: scripts/b17-ragas.sh [models]   default "qwen-cpu,gemini"
source "$(dirname "$0")/lib.sh"
load_env
need kubectl
use_cluster
[ -f "$RUN_DIR/images.env" ] || die "run b13 first"
# shellcheck disable=SC1091
. "$RUN_DIR/images.env"
RAGAS_MODELS="${1:-qwen-cpu,gemini}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
export RAGAS_IMAGE RAGAS_MODELS RUN_ID

step "Job ragas-$RUN_ID (models: $RAGAS_MODELS, judge: gemini)"
render "$MANIFESTS/phase-b/ragas-job.yaml.tmpl" NS_APP RAGAS_IMAGE RUN_ID RAGAS_MODELS | kubectl apply -f -
kubectl wait --for=condition=Ready pod -l job-name="ragas-$RUN_ID" -n "$NS_APP" --timeout=5m >/dev/null 2>&1 || true
info "streaming logs (CPU answers take a few seconds each; whole run ~5-15 min)"
kubectl logs -f "job/ragas-$RUN_ID" -n "$NS_APP" || true

st=$(kubectl get job "ragas-$RUN_ID" -n "$NS_APP" -o jsonpath='{.status.succeeded}')
if [ "$st" = "1" ]; then
  done_msg "Ragas job succeeded. In Langfuse: Traces -> filter tag ragas-$RUN_ID -> Scores column; or the Scores page."
else
  fail "job did not succeed: kubectl describe job ragas-$RUN_ID -n $NS_APP"; exit 1
fi
