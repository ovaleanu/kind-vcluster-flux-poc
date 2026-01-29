#!/bin/bash
#
# Remove a tenant and its vcluster from the GitOps repository.
#
# Usage:
#   ./hack/remove-tenant.sh <name>
#
# Example:
#   ./hack/remove-tenant.sh d    # removes tenant-d / vcluster-d
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <name>"
    echo "  name: short tenant name (e.g., 'd' for tenant-d / vcluster-d)"
    exit 1
fi

NAME="$1"
TENANT="tenant-${NAME}"
VCLUSTER="vcluster-${NAME}"

echo "=== Removing tenant: ${TENANT} / ${VCLUSTER} ==="
echo ""

# --- Validate tenant exists ---
if [[ ! -d "${REPO_ROOT}/clusters/${VCLUSTER}" ]] && [[ ! -d "${REPO_ROOT}/tenant/${TENANT}" ]]; then
    echo "ERROR: Neither clusters/${VCLUSTER}/ nor tenant/${TENANT}/ exist."
    exit 1
fi

# 1. Remove vcluster directory
if [[ -d "${REPO_ROOT}/clusters/${VCLUSTER}" ]]; then
    echo "[1/7] Removing clusters/${VCLUSTER}/"
    rm -rf "${REPO_ROOT}/clusters/${VCLUSTER}"
else
    echo "[1/7] clusters/${VCLUSTER}/ not found, skipping"
fi

# 2. Remove tenant directory
if [[ -d "${REPO_ROOT}/tenant/${TENANT}" ]]; then
    echo "[2/7] Removing tenant/${TENANT}/"
    rm -rf "${REPO_ROOT}/tenant/${TENANT}"
else
    echo "[2/7] tenant/${TENANT}/ not found, skipping"
fi

# 3. Remove Flux orchestration files
echo "[3/7] Removing Flux orchestration files"
rm -f "${REPO_ROOT}/clusters/host-cluster/${VCLUSTER}_kustomization.yaml"
rm -f "${REPO_ROOT}/clusters/host-cluster/${TENANT}_kustomization.yaml"

# 4. Remove from root kustomization
echo "[4/7] Updating clusters/host-cluster/kustomization.yaml"
KUSTOMIZATION_FILE="${REPO_ROOT}/clusters/host-cluster/kustomization.yaml"
sed -i "/- ${VCLUSTER}_kustomization.yaml/d" "${KUSTOMIZATION_FILE}"
sed -i "/- ${TENANT}_kustomization.yaml/d" "${KUSTOMIZATION_FILE}"

# 5. Remove ReferenceGrant
echo "[5/7] Removing ReferenceGrant from infrastructure/traefik/config/referencegrant.yaml"
REFERENCEGRANT_FILE="${REPO_ROOT}/infrastructure/traefik/config/referencegrant.yaml"
if grep -q "allow-${TENANT}-to-${VCLUSTER}" "${REFERENCEGRANT_FILE}"; then
    # Remove the ReferenceGrant block (from --- to the next --- or end of file)
    python3 -c "
import re, sys
with open('${REFERENCEGRANT_FILE}', 'r') as f:
    content = f.read()
# Split into YAML documents
docs = content.split('---')
# Filter out the one matching this tenant
filtered = [d for d in docs if 'allow-${TENANT}-to-${VCLUSTER}' not in d]
# Rejoin, removing empty docs
result = '---'.join(d for d in filtered if d.strip())
if not result.endswith('\n'):
    result += '\n'
with open('${REFERENCEGRANT_FILE}', 'w') as f:
    f.write(result)
"
fi

# 6. Remove NetworkPolicy
echo "[6/7] Removing NetworkPolicy for ${VCLUSTER}"
NETPOL_FILE="${REPO_ROOT}/infrastructure/network-policies/${VCLUSTER}-netpol.yaml"
NETPOL_KUSTOMIZATION="${REPO_ROOT}/infrastructure/network-policies/kustomization.yaml"
if [[ -f "${NETPOL_FILE}" ]]; then
    rm -f "${NETPOL_FILE}"
    sed -i "/${VCLUSTER}-netpol.yaml/d" "${NETPOL_KUSTOMIZATION}"
else
    echo "  NetworkPolicy file not found, skipping"
fi

# 7. Remove vcluster from network-policies dependency
echo "[7/7] Removing ${VCLUSTER} from network-policies dependencies"
INFRA_KUSTOMIZATION="${REPO_ROOT}/clusters/host-cluster/infrastructure_kustomization.yaml"
sed -i "/- name: ${VCLUSTER}$/d" "${INFRA_KUSTOMIZATION}"

echo ""
echo "=== Done! ==="
echo ""
echo "Next steps:"
echo "  1. git add -A && git commit -m 'Remove ${TENANT} and ${VCLUSTER}' && git push"
echo "  2. flux reconcile ks flux-system --with-source"
echo ""
echo "Flux prune will clean up the Kubernetes resources automatically."
