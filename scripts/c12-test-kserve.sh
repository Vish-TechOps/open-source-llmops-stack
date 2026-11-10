#!/usr/bin/env bash
# GCP phase C — run phase A's routing comparison against the KServe pods, through the same
# Gateway, selected with the x-llm-backend: kserve header (phase A still serves everything else).
source "$(dirname "$0")/lib.sh"
load_env
POD_SELECTOR="app.kubernetes.io/name=${LLMISVC_NAME},kserve.io/component=workload" \
EXTRA_HEADER="x-llm-backend: kserve" \
  bash "$(dirname "$0")/a16-test-routing.sh"
echo
info "Same pattern as phase A means KServe's scheduler does the same prefix-aware routing."
info "Next: scripts/c13-switch.sh makes KServe the default backend."
