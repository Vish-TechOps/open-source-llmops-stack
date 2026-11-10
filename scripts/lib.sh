# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are used by the scripts that source this file
# Shared helpers for llmops-stack/gcp scripts. Source it; do not run it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT_DIR/run"
ENV_FILE="$ROOT_DIR/.env"
MANIFESTS="$ROOT_DIR/manifests"
mkdir -p "$RUN_DIR"

if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
fail() { printf '  %s[fail]%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()  { fail "$*"; exit 1; }
done_msg() { printf '\n%s%s%s\n' "$C_OK" "$*" "$C_OFF"; }

load_env() {
  [ -f "$ENV_FILE" ] || die "No .env found. Run: cp .env.example .env && chmod 600 .env, then fill it in."
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  : "${PROJECT_ID:?}" "${REGION:?}" "${ZONE:?}" "${CLUSTER_NAME:?}"
  : "${NS_LLMD:=llmd}" "${NS_APP:=llmops}" "${NS_LANGFUSE:=langfuse}"
  : "${ROUTER_RELEASE:=qwen-router}" "${MODEL:=Qwen/Qwen3-0.6B}"
  LLMD_REPO="$RUN_DIR/llm-d"
  AR_HOST="${REGION}-docker.pkg.dev"
  AR_PATH="${AR_HOST}/${PROJECT_ID}/${AR_REPO:-llmops}"
  export LLMD_REPO AR_HOST AR_PATH
  export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
}

need() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "Missing commands: ${missing[*]}"
}

# Point kubectl at the cluster (idempotent).
use_cluster() {
  gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null 2>&1 \
    || die "Cannot get credentials for cluster $CLUSTER_NAME (run a11 first?)"
}

# Render a template with envsubst, substituting ONLY the listed variables,
# so any other $ in the file (shell snippets, regexes) is left alone.
# usage: render <template> VAR1 VAR2 ...
render() {
  local tmpl="$1"; shift
  local vars=""
  for v in "$@"; do vars="$vars \${$v}"; done
  envsubst "$vars" <"$tmpl"
}

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

gateway_ip() {
  kubectl get gateway llm-d-inference-gateway -n "$NS_LLMD" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

# One-shot in-cluster client pod used by the tests (curl + jq + bash).
CURL_IMAGE="docker.io/cfmanteiga/alpine-bash-curl-jq:latest"
ensure_curl_pod() { # $1 = namespace
  local ns="$1"
  if ! kubectl get pod curl-client -n "$ns" >/dev/null 2>&1; then
    kubectl run curl-client -n "$ns" --image="$CURL_IMAGE" --restart=Never \
      --command -- sh -c "sleep 86400" >/dev/null
  fi
  kubectl wait --for=condition=Ready pod/curl-client -n "$ns" --timeout=180s >/dev/null
}

# Sum a vLLM counter over all its series for one pod. $1=ns $2=pod $3=metric regex
pod_metric_sum() {
  kubectl get --raw "/api/v1/namespaces/$1/pods/$2:8000/proxy/metrics" 2>/dev/null \
    | grep -E "^($3)(\{| )" | awk '{s+=$NF} END {printf "%d", s+0}'
}
