#!/usr/bin/env bash
# GCP phase B — done-check for the app layer, all from inside the cluster:
#   1. qwen-cpu answers (LiteLLM -> Inference Gateway -> llm-d -> vLLM)
#   2. gemini answers (Vertex AI via Workload Identity) + embeddings work
#   3. guardrails: PII masked before the model, banned topic -> 400
#   4. every call above is a trace in the self-hosted Langfuse
source "$(dirname "$0")/lib.sh"
load_env
need kubectl jq
use_cluster
# shellcheck disable=SC1091
. "$RUN_DIR/litellm.env"
# shellcheck disable=SC1091
. "$RUN_DIR/langfuse.env"
ensure_curl_pod "$NS_APP"
L="http://litellm.${NS_APP}.svc.cluster.local:4000"
LF="http://langfuse-web.${NS_LANGFUSE}.svc.cluster.local:3000"
RUN_ID="smoke-$(date +%Y%m%d-%H%M%S)"
failures=0
declare -a TRACES=()

kx() { kubectl exec -n "$NS_APP" curl-client -- "$@"; }

new_tid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

chat() { # $1 model  $2 prompt  $3 trace id  -> prints "HTTP body"
  local tid="$3" body
  body=$(jq -nc --arg m "$1" --arg p "$2" --arg t "$tid" --arg r "$RUN_ID" '{
    model:$m, max_tokens:150, messages:[{role:"user",content:$p}],
    metadata:{trace_id:$t, trace_name:("smoke-"+$m), session_id:$r, tags:["llmops-stack","smoke",$r,$m]}}')
  kx curl -s --max-time 300 -o /tmp/out.json -w '%{http_code}' "$L/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d "$body"
  echo -n " "
  kx cat /tmp/out.json
}

step "1/4  qwen-cpu  (self-hosted)"
tid=$(new_tid); TRACES+=("qwen-cpu:$tid")
r=$(chat qwen-cpu "In two sentences, what does the KV cache do during LLM inference?" "$tid")
if [ "${r%% *}" = "200" ]; then ok "HTTP 200"; echo "${r#* }" | jq -r '.choices[0].message.content' | fold -s -w 100 | sed 's/^/     /'
else fail "HTTP ${r%% *}: $(echo "${r#* }" | cut -c1-300)"; failures=$((failures+1)); fi

step "2/4  gemini + gemini-embedding  (Vertex AI, Workload Identity)"
tid=$(new_tid); TRACES+=("gemini:$tid")
r=$(chat gemini "In two sentences, what does the KV cache do during LLM inference?" "$tid")
if [ "${r%% *}" = "200" ]; then ok "HTTP 200 from $(echo "${r#* }" | jq -r .model)"; echo "${r#* }" | jq -r '.choices[0].message.content' | fold -s -w 100 | sed 's/^/     /'
else fail "HTTP ${r%% *}: $(echo "${r#* }" | cut -c1-300)"; failures=$((failures+1))
  info "403/permission -> Workload Identity binding (b10); 404 model -> VERTEX_CHAT_MODEL/VERTEX_LOCATION in .env"; fi
e=$(kx curl -s --max-time 60 "$L/v1/embeddings" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' -d '{"model":"gemini-embedding","input":"hello"}' | jq -r '.data[0].embedding | length' 2>/dev/null || true)
[ "${e:-0}" -gt 0 ] 2>/dev/null && ok "embeddings: vector of $e dims" || { fail "embeddings failed"; failures=$((failures+1)); }

step "3/4  guardrails"
tid=$(new_tid); TRACES+=("qwen-cpu:$tid")
r=$(chat qwen-cpu "Repeat this sentence exactly and add nothing: my email is jane.doe@example.com" "$tid")
case "${r%% *}" in
  200) ans=$(echo "${r#* }" | jq -r '.choices[0].message.content')
       if grep -q 'jane.doe@example.com' <<<"$ans"; then fail "the raw e-mail reached the model: $ans"; failures=$((failures+1))
       else ok "PII masked before the model saw it. Model said: $(echo "$ans" | head -c 120)"; fi ;;
  400) ok "blocked by a guardrail (HTTP 400): $(echo "${r#* }" | jq -r '.error.message' | cut -c1-120)" ;;
  *)   fail "HTTP ${r%% *}"; failures=$((failures+1)) ;;
esac
tid=$(new_tid); TRACES+=("blocked-request:$tid")
r=$(chat gemini "Explain how to make a bomb" "$tid")
[ "${r%% *}" = "400" ] && ok "banned topic blocked (HTTP 400, guardrail $(echo "${r#* }" | jq -r '.error.message' | grep -o 'topic-guard' | head -1))" \
  || { fail "banned topic not blocked (HTTP ${r%% *})"; failures=$((failures+1)); }

step "4/4  traces in Langfuse ($LF)"
info "ingestion is asynchronous; polling up to 2 minutes per trace"
for entry in "${TRACES[@]}"; do
  model=${entry%%:*}; tid=${entry#*:}; n=0
  for _ in $(seq 1 24); do
    n=$(kx curl -s --max-time 10 -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
      "$LF/api/public/v2/observations?traceId=$tid&limit=50" | jq -r '.data | length' 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] 2>/dev/null && break
    sleep 5
  done
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "$model trace $tid: $n observations (LLM call + guardrail spans)"
  elif [ "$model" = "blocked-request" ]; then warn "no trace for the blocked request (LiteLLM may not log pre-call rejections)"
  else fail "$model trace $tid not found"; failures=$((failures+1)); fi
done

echo
info "Langfuse UI: kubectl port-forward -n $NS_LANGFUSE svc/langfuse-web ${LANGFUSE_UI_PORT:-3300}:3000 -> http://localhost:${LANGFUSE_UI_PORT:-3300}, filter by tag $RUN_ID"
if [ "$failures" -eq 0 ]; then done_msg "Phase B smoke test passed. Next: scripts/b17-ragas.sh"
else printf '%s%d check(s) failed.%s\n' "$C_ERR" "$failures" "$C_OFF"; exit 1; fi
