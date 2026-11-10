#!/usr/bin/env bash
# GCP phase B — cluster operators the Langfuse v4 chart needs (and KServe reuses in phase C):
# cert-manager, and the ClickHouse operator (Langfuse renders ClickHouseCluster CRs).
source "$(dirname "$0")/lib.sh"
load_env
need helm kubectl
use_cluster

step "cert-manager $CERT_MANAGER_VERSION"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 10m >/dev/null
kubectl wait --for=condition=Established crd/certificates.cert-manager.io crd/issuers.cert-manager.io --timeout=120s >/dev/null
ok "installed"

step "ClickHouse operator $CLICKHOUSE_OPERATOR_VERSION"
helm upgrade --install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm \
  --version "$CLICKHOUSE_OPERATOR_VERSION" --namespace clickhouse-operator --create-namespace \
  --wait --timeout 10m >/dev/null
kubectl wait --for=condition=Established crd/clickhouseclusters.clickhouse.com crd/keeperclusters.clickhouse.com --timeout=120s >/dev/null
ok "installed"

done_msg "Operators ready. Next: scripts/b12-langfuse.sh"
