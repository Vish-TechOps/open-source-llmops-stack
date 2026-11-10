#!/usr/bin/env bash
# GCP phase C — done-check: every earlier test passes unchanged with KServe as the backend.
#   - phase A routing comparison (no header now)
#   - phase B smoke test (LiteLLM qwen-cpu now lands on KServe pods; nothing in LiteLLM changed)
#   - optional Ragas run: scripts/b17-ragas.sh qwen-cpu
source "$(dirname "$0")/lib.sh"
load_env
D="$(dirname "$0")"

step "Routing comparison against KServe pods (default route)"
POD_SELECTOR="app.kubernetes.io/name=${LLMISVC_NAME},kserve.io/component=workload" bash "$D/a16-test-routing.sh"

step "Phase B smoke test through LiteLLM"
bash "$D/b16-smoke-test.sh"

done_msg "Phase C done. For quality numbers on the KServe deployment: scripts/b17-ragas.sh qwen-cpu"
