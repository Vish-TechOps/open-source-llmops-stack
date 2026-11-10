#!/usr/bin/env bash
# GCP phase A — done-check: real answers through the Inference Gateway, then the 2x2
# routing comparison from the local demo (plain Kubernetes Service vs llm-d), now with
# vLLM's real prefix-cache hit counters next to the request counts.
#
# Reused by phase C:  POD_SELECTOR=... bash scripts/a16-test-routing.sh
source "$(dirname "$0")/lib.sh"
load_env
need kubectl jq
use_cluster

POD_SELECTOR="${POD_SELECTOR:-llm-d.ai/guide=optimized-baseline}"
N="${ROUTING_REQUESTS:-8}"
EXTRA_HEADER="${EXTRA_HEADER:-}"     # phase C sets a routing header while both stacks run
IP=$(gateway_ip)
[ -n "$IP" ] || die "Gateway has no address (a13)"
PODS=$(kubectl get pods -n "$NS_LLMD" -l "$POD_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
[ -n "$PODS" ] || die "no running model pods match $POD_SELECTOR"

step "Client pod and plain Service (the control: no llm-d in the path)"
ensure_curl_pod "$NS_LLMD"
sel_yaml=$(echo "$POD_SELECTOR" | tr ',' '\n' | sed 's/=/: "/; s/$/"/; s/^/    /')
kubectl apply -n "$NS_LLMD" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vllm-direct
spec:
  type: ClusterIP
  selector:
$sel_yaml
  ports:
    - {name: http, port: 8000, targetPort: 8000}
EOF
ok "curl-client pod + Service vllm-direct (same pods, kube-proxy only)"

step "1 question through the Gateway (http://$IP)"
kubectl exec -n "$NS_LLMD" curl-client -- curl -s --max-time 300 "http://$IP/v1/chat/completions" \
  -H 'Content-Type: application/json' ${EXTRA_HEADER:+-H "$EXTRA_HEADER"} \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":120,\"chat_template_kwargs\":{\"enable_thinking\":false},
       \"messages\":[{\"role\":\"user\",\"content\":\"In two sentences: how does self-attention work in a Transformer?\"}]}" \
  >"$RUN_DIR/a16-answer.json" || true
if jq -e '.choices[0].message.content' "$RUN_DIR/a16-answer.json" >/dev/null 2>&1; then
  ok "real answer from $(jq -r .model "$RUN_DIR/a16-answer.json"):"
  jq -r '.choices[0].message.content' "$RUN_DIR/a16-answer.json" | fold -s -w 100 | sed 's/^/     /'
  info "usage: $(jq -c .usage "$RUN_DIR/a16-answer.json")"
else
  cat "$RUN_DIR/a16-answer.json"; die "no answer through the Gateway (backends healthy? kubectl describe httproute -n $NS_LLMD)"
fi

# --- helpers ---------------------------------------------------------------
snapshot() { # prints "pod requests hits queries"
  local p
  for p in $PODS; do
    printf '%s %s %s %s\n' "$p" \
      "$(pod_metric_sum "$NS_LLMD" "$p" 'vllm:request_success_total')" \
      "$(pod_metric_sum "$NS_LLMD" "$p" 'vllm:prefix_cache_hits_total')" \
      "$(pod_metric_sum "$NS_LLMD" "$p" 'vllm:prefix_cache_queries_total')"
  done
}

# Runs inside the client pod: one curl process per request + Connection: close,
# so kube-proxy (which balances per TCP connection) gets a fair chance to spread.
LOAD_SCRIPT='
P=""
if [ "$SHARED" = "yes" ]; then
  P=$(for i in $(seq 1 100); do printf "The llm-d router keeps a conversation on the server that already caches its prefix. "; done)
fi
ok=0
for i in $(seq 1 "$N"); do
  if [ "$SHARED" = "yes" ]; then prompt="$P Question $i: what is llm-d?"
  else prompt="Distinct topic $i about $RANDOM$RANDOM and nothing else. Explain briefly."; fi
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 300 -H "Connection: close" \
    -H "Content-Type: application/json" ${HDR:+-H "$HDR"} \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"$prompt\",\"max_tokens\":16}" "$URL/v1/completions")
  [ "$code" = "200" ] && ok=$((ok+1))
done
echo "$ok"
'

run_case() { # $1 label  $2 url  $3 shared(yes/no)  $4 header-or-empty
  local before after okn t0 t1
  before=$(snapshot)
  t0=$(date +%s)
  okn=$(kubectl exec -n "$NS_LLMD" curl-client -- env URL="$2" SHARED="$3" N="$N" MODEL="$MODEL" HDR="$4" bash -c "$LOAD_SCRIPT" | tail -1)
  t1=$(date +%s)
  after=$(snapshot)
  local reqs="" hits=""
  while read -r pod r h q; do
    read -r _ r0 h0 q0 < <(grep "^$pod " <<<"$before")
    reqs="$reqs $((r - r0))"
    local dq=$((q - q0)) dh=$((h - h0))
    if [ "$dq" -gt 0 ]; then hits="$hits $((100 * dh / dq))%"; else hits="$hits -"; fi
  done <<<"$after"
  printf '%-14s %-18s %3s/%-3s HTTP 200  %4ss   requests per pod:%-10s prefix-cache hit rate per pod:%s\n' \
    "$1" "$( [ "$3" = yes ] && echo 'shared prefix' || echo 'no shared prefix')" "$okn" "$N" "$((t1 - t0))" "$reqs" "$hits"
}

step "Routing comparison ($N requests per row; CPU prefill takes a few seconds each)"
info "pods: $PODS"
SVC_URL="http://vllm-direct.$NS_LLMD.svc.cluster.local:8000"
echo "=============================================================================================================="
run_case "K8s Service" "$SVC_URL" yes ""
run_case "K8s Service" "$SVC_URL" no  ""
run_case "llm-d Gateway" "http://$IP" yes "$EXTRA_HEADER"
run_case "llm-d Gateway" "http://$IP" no  "$EXTRA_HEADER"
echo "=============================================================================================================="
cat <<'EOF'
  How to read it:
  - K8s Service rows look alike: kube-proxy never sees the prompt, so a shared prefix changes nothing
    about where requests land.
  - llm-d + shared prefix: (almost) all requests on one pod. The prefix is computed once and every
    later request hits the cache.
  - K8s Service + shared prefix still shows cache hits, but every pod must compute the prefix once
    first (one cold prefill per pod instead of one in total). With 2 pods the gap is modest; with
    more pods and more concurrent conversations the wasted prefills, and the latency, grow.
  - llm-d + no shared prefix: spread across pods again (token-load scorer), no cache hits.
  - Hit rate = vLLM prefix_cache_hits / prefix_cache_queries (tokens) during that row.
EOF
done_msg "Phase A done-check finished. Clean up the test objects any time: kubectl delete pod/curl-client svc/vllm-direct -n $NS_LLMD"
