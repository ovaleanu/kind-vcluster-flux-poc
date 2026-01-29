#!/bin/bash
#
# Fix vcluster kubeconfig secret to use internal service DNS instead of localhost.
#
# VCluster generates kubeconfigs pointing to localhost:8443, but Flux needs
# to reach the vcluster API server via the internal Kubernetes service DNS.
# Using the internal DNS (vcluster-X.vcluster-X:443) instead of the LoadBalancer
# IP ensures NetworkPolicies can properly identify the source namespace.
#
# Usage:
#   ./hack/fix-vcluster-kubeconfig.sh <name>
#
# Example:
#   ./hack/fix-vcluster-kubeconfig.sh d    # fixes vcluster-d
#

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <name>"
    echo "  name: short tenant name (e.g., 'd' for vcluster-d)"
    exit 1
fi

NAME="$1"
VCLUSTER="vcluster-${NAME}"
SECRET="vc-${VCLUSTER}"
INTERNAL_SERVER="https://${VCLUSTER}.${VCLUSTER}:443"

echo "=== Fixing kubeconfig for ${VCLUSTER} ==="

# Wait for the vcluster pod to be ready
echo "Waiting for ${VCLUSTER} pod to be ready..."
kubectl wait --for=condition=Ready pod/${VCLUSTER}-0 -n "${VCLUSTER}" --timeout=300s

# Wait for the kubeconfig secret to exist
echo "Waiting for kubeconfig secret ${SECRET}..."
for i in $(seq 1 30); do
    if kubectl get secret -n "${VCLUSTER}" "${SECRET}" &>/dev/null; then
        break
    fi
    echo "  Waiting for secret (attempt ${i}/30)..."
    sleep 5
done

# Get current kubeconfig
KUBECONFIG_DATA=$(kubectl get secret -n "${VCLUSTER}" "${SECRET}" -o jsonpath='{.data.config}' | base64 -d)

# Check if it already points to the correct internal DNS
if echo "${KUBECONFIG_DATA}" | grep -q "${INTERNAL_SERVER}"; then
    echo "Kubeconfig already points to ${INTERNAL_SERVER}. No fix needed."
    exit 0
fi

# Replace localhost:8443 with internal service DNS
FIXED_KUBECONFIG=$(echo "${KUBECONFIG_DATA}" | sed "s|https://localhost:8443|${INTERNAL_SERVER}|g")

# Update the secret
echo "Updating kubeconfig secret..."
kubectl get secret -n "${VCLUSTER}" "${SECRET}" -o json | \
    jq --arg config "$(echo "${FIXED_KUBECONFIG}" | base64 -w 0)" '.data.config = $config' | \
    kubectl apply -f -

echo ""
echo "=== Kubeconfig fixed for ${VCLUSTER} ==="
echo "API server: ${INTERNAL_SERVER}"
echo ""
echo "Flux will now be able to deploy workloads to ${VCLUSTER}."
echo "Trigger reconciliation: flux reconcile ks ${VCLUSTER} --with-source"
