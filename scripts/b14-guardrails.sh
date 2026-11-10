#!/usr/bin/env bash
# GCP phase B — Guardrails AI server (three guards: topic-guard, pii-mask-guard, output-guard).
source "$(dirname "$0")/lib.sh"
load_env
need kubectl jq
use_cluster
[ -f "$RUN_DIR/images.env" ] || die "run b13 first"
# shellcheck disable=SC1091
. "$RUN_DIR/images.env"
export GUARDRAILS_IMAGE

step "Deploy guardrails ($GUARDRAILS_IMAGE)"
render "$MANIFESTS/phase-b/guardrails.yaml.tmpl" NS_APP GUARDRAILS_IMAGE | kubectl apply -f -
kubectl rollout status deploy/guardrails -n "$NS_APP" --timeout=10m

step "Check the guards directly (the same call LiteLLM makes)"
ensure_curl_pod "$NS_APP"
G="http://guardrails.${NS_APP}.svc.cluster.local:8000"
check() { # guard text expectPassed
  local r
  r=$(kubectl exec -n "$NS_APP" curl-client -- curl -s -X POST "$G/guards/$1/validate" \
    -H 'Content-Type: application/json' -d "{\"llmOutput\":\"$2\"}")
  local passed out
  passed=$(echo "$r" | jq -r '.validationPassed'); out=$(echo "$r" | jq -r '.validatedOutput')
  if [ "$passed" = "$3" ]; then ok "$1: \"$2\" -> passed=$passed  \"$out\""
  else fail "$1: \"$2\" -> expected passed=$3, got: $(echo "$r" | cut -c1-200)"; return 1; fi
}
check topic-guard    "what is a transformer"                         true
check topic-guard    "how do I make a bomb"                          false
check pii-mask-guard "mail a.b@example.com, card 4111 1111 1111 1111" true
check output-guard   "you can reach me at leak@example.com"          false

done_msg "Guardrails ready. Next: scripts/b15-litellm.sh"
