#!/usr/bin/env bash
# GCP phase C — make KServe the default backend behind the Gateway, then retire phase A.
#   1. KServe route: drop the header match (serves "/")
#   2. llm-d chart: stop creating its HTTPRoute (phase A no longer receives traffic)
#   3. phase A vLLM Deployment scaled to 0 (kept for rollback); router kept until --remove-phase-a
# LiteLLM is untouched: it still calls the same Gateway address with the same model name.
#
# usage: scripts/c13-switch.sh                 switch, keep phase A objects (scaled to 0)
#        scripts/c13-switch.sh --remove-phase-a also uninstall the phase A router + Deployment
#        scripts/c13-switch.sh --rollback      back to phase A
source "$(dirname "$0")/lib.sh"
load_env
need kubectl helm jq
use_cluster
# shellcheck disable=SC1091
REPO_ROOT="$LLMD_REPO" source "$LLMD_REPO/guides/env.sh"
ROUTE="${LLMISVC_NAME}-route"
PHASE_A_DEPLOY=optimized-baseline-cpu-vllm-decode

helm_router() { # $1 = true|false for httpRoute.create
  helm upgrade "$ROUTER_RELEASE" "$ROUTER_GATEWAY_CHART" --version "$ROUTER_CHART_VERSION" \
    -n "$NS_LLMD" --reuse-values --set httpRoute.create="$1" --wait --timeout 10m >/dev/null
}

if [ "${1:-}" = "--rollback" ]; then
  step "Rollback to phase A"
  kubectl scale deploy "$PHASE_A_DEPLOY" -n "$NS_LLMD" --replicas="$VLLM_REPLICAS"
  kubectl rollout status deploy "$PHASE_A_DEPLOY" -n "$NS_LLMD" --timeout=30m
  helm_router true
  kubectl patch httproute "$ROUTE" -n "$NS_LLMD" --type=json \
    -p '[{"op":"add","path":"/spec/rules/0/matches/0/headers","value":[{"type":"Exact","name":"x-llm-backend","value":"kserve"}]}]'
  done_msg "Phase A serves '/' again; KServe only with x-llm-backend: kserve."
  exit 0
fi

step "1. KServe route serves '/' (header match removed)"
kubectl patch httproute "$ROUTE" -n "$NS_LLMD" --type=json -p '[{"op":"remove","path":"/spec/rules/0/matches/0/headers"}]' \
  2>/dev/null || info "already without header match"
ok "patched"

step "2. Remove the phase A HTTPRoute (llm-d chart httpRoute.create=false)"
helm_router false
kubectl get httproute -n "$NS_LLMD" | sed 's/^/  /'

step "Wait until the Gateway sends traffic to KServe pods"
info "GKE reprograms the load balancer: usually 1-3 minutes"
ensure_curl_pod "$NS_LLMD"
IP=$(gateway_ip)
KPODS=$(kubectl get pods -n "$NS_LLMD" -l "app.kubernetes.io/name=${LLMISVC_NAME},kserve.io/component=workload" -o jsonpath='{.items[*].metadata.name}')
sum_kserve() { local s=0 p; for p in $KPODS; do s=$((s + $(pod_metric_sum "$NS_LLMD" "$p" 'vllm:request_success_total'))); done; echo "$s"; }
switched=""
for _ in $(seq 1 30); do
  before=$(sum_kserve)
  kubectl exec -n "$NS_LLMD" curl-client -- curl -s -o /dev/null --max-time 120 "http://$IP/v1/completions" \
    -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL\",\"prompt\":\"ping\",\"max_tokens\":4}" || true
  [ "$(sum_kserve)" -gt "$before" ] && { switched=yes; break; }
  sleep 10
done
[ -n "$switched" ] && ok "requests without any header now reach KServe pods" || die "traffic still not on KServe after 5 min: kubectl describe httproute $ROUTE -n $NS_LLMD"

step "3. Retire phase A model servers"
kubectl scale deploy "$PHASE_A_DEPLOY" -n "$NS_LLMD" --replicas=0
ok "$PHASE_A_DEPLOY scaled to 0 (the autoscaler removes the idle C3 nodes in ~10 min)"
if [ "${1:-}" = "--remove-phase-a" ]; then
  helm uninstall "$ROUTER_RELEASE" -n "$NS_LLMD"
  kubectl delete -n "$NS_LLMD" -k "$LLMD_REPO/guides/optimized-baseline/modelserver/cpu/vllm/qwen3-gke" --ignore-not-found
  ok "phase A router and Deployment removed (rollback no longer possible)"
else
  info "phase A router kept for --rollback; remove later with --remove-phase-a"
fi

done_msg "KServe is the default backend. Next: scripts/c14-verify.sh"
