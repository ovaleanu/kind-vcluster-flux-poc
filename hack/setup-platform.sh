#!/bin/bash
#
# Bootstrap vCluster Platform after GitOps deployment.
#
# This script performs the imperative operations that cannot be
# expressed as Kubernetes manifests:
#   1. Wait for the vCluster Platform to be healthy
#   2. Configure CLI access (write config directly, no login command)
#   3. Check platform license activation
#   4. Import each vCluster into the platform (if licensed)
#
# The platform automatically knows about its own cluster (loft-cluster),
# so we do NOT run "vcluster platform add cluster" which would install
# an agent Helm chart that conflicts with the Flux-managed HelmRelease.
#
# Prerequisites:
#   - Kind cluster is running with Flux deployed
#   - All Flux Kustomizations are reconciled (make wait-for-workloads)
#   - vcluster CLI is available in ./bin/vcluster
#
# Usage:
#   ./hack/setup-platform.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
VCLUSTER_CLI="${REPO_ROOT}/bin/vcluster"
PLATFORM_IP="${VCLUSTER_PLATFORM_IP:-172.18.0.219}"
PLATFORM_URL="https://${PLATFORM_IP}"
PLATFORM_INTERNAL_HOST="https://loft.vcluster-platform.svc:443"
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
until curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${PLATFORM_URL}/healthz" 2>/dev/null | grep -q "200"; do
    sleep 5
done
ok "Platform is healthy at ${PLATFORM_URL}"

# ============================================================
# Phase 2: Configure CLI access to platform
# ============================================================
echo ""
echo "=== Phase 2: Configure CLI access to vCluster Platform ==="

info "Obtaining access key via platform API..."
ACCESS_KEY=$(curl -sk --max-time 10 -X POST "${PLATFORM_URL}/auth/password/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    | sed -n 's/.*"accessKey":"\([^"]*\)".*/\1/p')

if [ -z "${ACCESS_KEY}" ]; then
    echo "ERROR: Failed to obtain access key from platform API"
    exit 1
fi

# Write CLI config directly instead of running "vcluster platform login"
# which tries to verify user access and fails with session-scoped keys.
VCLUSTER_CONFIG_DIR="${HOME}/.vcluster"
VCLUSTER_CONFIG="${VCLUSTER_CONFIG_DIR}/config.json"

mkdir -p "${VCLUSTER_CONFIG_DIR}"
cat > "${VCLUSTER_CONFIG}" <<CFGEOF
{
  "platform": {
    "kind": "Config",
    "apiVersion": "storage.loft.sh/v1",
    "host": "${PLATFORM_URL}",
    "accesskey": "${ACCESS_KEY}",
    "insecure": true
  }
}
CFGEOF

ok "CLI configured for platform at ${PLATFORM_URL}"

# Ensure kubectl points at the host cluster
kubectl config use-context kind-host-cluster

# ============================================================
# Phase 3: Check platform license and import vClusters
# ============================================================
echo ""
echo "=== Phase 3: Importing vClusters into platform ==="

# Check if the platform is activated by testing whether we can create
# a VirtualClusterInstance (the license limit for unactivated instances is 0).
LICENSE_OK=true
LICENSE_RESPONSE=$(curl -sk "${PLATFORM_URL}/kubernetes/management/apis/management.loft.sh/v1/licenses/request" \
    -H "Authorization: Bearer ${ACCESS_KEY}" 2>/dev/null)
if echo "${LICENSE_RESPONSE}" | grep -q "instance-not-activated"; then
    warn "Platform instance is not activated."
    warn "Virtual cluster management requires an activated license."
    warn "Activate at: ${PLATFORM_URL} (Settings > License)"
    warn "Skipping vCluster import."
    LICENSE_OK=false
fi

if [ "${LICENSE_OK}" = true ]; then
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

        # Import vCluster using internal service address to avoid hairpin networking.
        # --external=true (default) creates a platform secret in the vCluster namespace
        # without modifying any Helm releases.
        ${VCLUSTER_CLI} platform add vcluster "${VC_NAME}" \
            --namespace "${VC_NS}" \
            --project "${PROJECT}" \
            --import-name "${VC_NAME}" \
            --host "${PLATFORM_INTERNAL_HOST}" \
            --insecure

        ok "${VC_NAME} imported into platform."
    done
fi

# ============================================================
# Phase 4: Verification
# ============================================================
echo ""
echo "=== Phase 4: Verification ==="

echo ""
info "Platform clusters:"
${VCLUSTER_CLI} platform list clusters 2>/dev/null || true

if [ "${LICENSE_OK}" = true ]; then
    echo ""
    info "Platform vClusters:"
    ${VCLUSTER_CLI} platform list vclusters --project "${PROJECT}" 2>/dev/null || true
fi

echo ""
echo "=== Platform bootstrap complete ==="
echo ""
echo "  Platform UI: ${PLATFORM_URL}"
echo "  Credentials: ${ADMIN_USER} / ${ADMIN_PASSWORD}"
if [ "${LICENSE_OK}" = false ]; then
    echo ""
    echo "  NOTE: Activate the platform to enable vCluster management."
    echo "  Visit ${PLATFORM_URL} and follow the activation prompts."
fi
echo ""
