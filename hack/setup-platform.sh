#!/bin/bash
#
# Bootstrap vCluster Platform after GitOps deployment.
#
# This script performs the imperative operations that cannot be
# expressed as Kubernetes manifests:
#   1. Wait for the vCluster Platform to be healthy
#   2. Login to the platform via LoadBalancer IP
#   3. Add the host cluster to the platform
#   4. Import each vCluster as managed into the platform
#
# Prerequisites:
#   - Kind cluster is running with Flux deployed
#   - All Flux Kustomizations are reconciled (make wait-for-workloads)
#   - vcluster CLI is available in ./bin/vcluster
#
# Usage:
#   ./hack/setup-platform.sh
#
# The script uses the LoadBalancer IP (not port-forward) so that
# the vcluster-platform-api-key secrets get the correct host value.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
VCLUSTER_CLI="${REPO_ROOT}/bin/vcluster"
PLATFORM_IP="${VCLUSTER_PLATFORM_IP:-172.18.0.219}"
PLATFORM_URL="https://${PLATFORM_IP}"
PLATFORM_NAMESPACE="vcluster-platform"
ADMIN_USER="admin"
ADMIN_PASSWORD="admin"
PROJECT="default"

# vCluster definitions: name:namespace
VCLUSTERS=(
    "vcluster-a:vcluster-a"
    "vcluster-b:vcluster-b"
)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ============================================================
# Phase 1: Wait for vCluster Platform to be healthy
# ============================================================
echo ""
echo "=== Phase 1: Waiting for vCluster Platform to be healthy ==="

info "Waiting for loft deployment to be available..."
kubectl wait deployment/loft -n "${PLATFORM_NAMESPACE}" \
    --for=condition=Available --timeout=10m

info "Waiting for loft pod to be ready..."
kubectl wait pod -l app=loft -n "${PLATFORM_NAMESPACE}" \
    --for=condition=Ready --timeout=5m

info "Waiting for LoadBalancer IP ${PLATFORM_IP}..."
until kubectl get svc loft -n "${PLATFORM_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q "${PLATFORM_IP}"; do
    sleep 5
done
ok "Platform LoadBalancer IP: ${PLATFORM_IP}"

info "Waiting for platform HTTPS health endpoint..."
until curl -sk --max-time 5 "${PLATFORM_URL}/healthz" 2>/dev/null | grep -q "ok"; do
    sleep 5
done
ok "Platform is healthy at ${PLATFORM_URL}"

# ============================================================
# Phase 2: Login to platform via LoadBalancer IP
# ============================================================
echo ""
echo "=== Phase 2: Login to vCluster Platform ==="

${VCLUSTER_CLI} login "${PLATFORM_URL}" \
    --username "${ADMIN_USER}" \
    --password "${ADMIN_PASSWORD}" \
    --insecure

ok "Logged in to platform at ${PLATFORM_URL}"

# ============================================================
# Phase 3: Add host cluster to platform
# ============================================================
echo ""
echo "=== Phase 3: Adding host cluster to platform ==="

# Switch to host cluster context
kubectl config use-context kind-host-cluster

if ${VCLUSTER_CLI} platform get cluster local-cluster --insecure &>/dev/null; then
    warn "Host cluster 'local-cluster' already registered, skipping."
else
    # Patch Helm ownership metadata on any existing platform secrets
    for secret_name in loft-agent-connection loft-agent-config loft-agent-token; do
        if kubectl get secret "${secret_name}" -n "${PLATFORM_NAMESPACE}" &>/dev/null; then
            kubectl annotate secret "${secret_name}" -n "${PLATFORM_NAMESPACE}" \
                "meta.helm.sh/release-name=loft" \
                "meta.helm.sh/release-namespace=${PLATFORM_NAMESPACE}" \
                --overwrite 2>/dev/null || true
            kubectl label secret "${secret_name}" -n "${PLATFORM_NAMESPACE}" \
                "app.kubernetes.io/managed-by=Helm" \
                --overwrite 2>/dev/null || true
        fi
    done

    ${VCLUSTER_CLI} platform add cluster local-cluster \
        --insecure \
        --wait
    ok "Host cluster 'local-cluster' added."
fi

# ============================================================
# Phase 4: Import vClusters as managed
# ============================================================
echo ""
echo "=== Phase 4: Importing vClusters into platform ==="

for entry in "${VCLUSTERS[@]}"; do
    VC_NAME="${entry%%:*}"
    VC_NS="${entry##*:}"

    echo ""
    info "Processing ${VC_NAME} in namespace ${VC_NS}..."

    # Wait for vCluster StatefulSet
    info "Waiting for StatefulSet ${VC_NAME} to be ready..."
    kubectl wait statefulset/"${VC_NAME}" -n "${VC_NS}" \
        --for=jsonpath='{.status.readyReplicas}'=1 --timeout=5m

    # Check if already imported
    if ${VCLUSTER_CLI} platform list vclusters --project "${PROJECT}" --insecure 2>/dev/null | grep -q "${VC_NAME}"; then
        warn "${VC_NAME} already imported, skipping."
        continue
    fi

    # Patch Helm ownership metadata on any existing secrets in the vCluster namespace
    for secret_name in loft-agent-connection loft-agent-config loft-agent-token; do
        if kubectl get secret "${secret_name}" -n "${VC_NS}" &>/dev/null; then
            kubectl annotate secret "${secret_name}" -n "${VC_NS}" \
                "meta.helm.sh/release-name=loft" \
                "meta.helm.sh/release-namespace=${VC_NS}" \
                --overwrite 2>/dev/null || true
            kubectl label secret "${secret_name}" -n "${VC_NS}" \
                "app.kubernetes.io/managed-by=Helm" \
                --overwrite 2>/dev/null || true
        fi
    done

    # Import vCluster as managed (not external)
    ${VCLUSTER_CLI} platform add vcluster "${VC_NAME}" \
        --namespace "${VC_NS}" \
        --project "${PROJECT}" \
        --import-name "${VC_NAME}" \
        --insecure \
        --external=false

    ok "${VC_NAME} imported as managed."
done

# ============================================================
# Phase 5: Verification
# ============================================================
echo ""
echo "=== Phase 5: Verification ==="

echo ""
info "Platform vClusters:"
${VCLUSTER_CLI} platform list vclusters --project "${PROJECT}" --insecure 2>/dev/null || true

echo ""
echo "=== Platform bootstrap complete ==="
echo ""
echo "  Platform UI: ${PLATFORM_URL}"
echo "  Credentials: ${ADMIN_USER} / ${ADMIN_PASSWORD}"
echo ""
