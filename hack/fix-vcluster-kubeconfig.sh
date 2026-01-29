#!/bin/bash
#
# Fix vcluster kubeconfig secret to use LoadBalancer IP instead of localhost.
#
# VCluster generates kubeconfigs pointing to localhost:8443, but Flux needs
# to reach the vcluster API server via the MetalLB LoadBalancer IP.
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

echo "=== Fixing kubeconfig for ${VCLUSTER} ==="

# Wait for the vcluster pod to be ready
echo "Waiting for ${VCLUSTER} pod to be ready..."
kubectl wait --for=condition=Ready pod/${VCLUSTER}-0 -n "${VCLUSTER}" --timeout=300s

# Get the LoadBalancer IP
echo "Getting LoadBalancer IP..."
VCLUSTER_IP=""
for i in $(seq 1 30); do
    VCLUSTER_IP=$(kubectl get svc -n "${VCLUSTER}" "${VCLUSTER}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${VCLUSTER_IP}" ]]; then
        break
    fi
    echo "  Waiting for LoadBalancer IP (attempt ${i}/30)..."
    sleep 5
done

if [[ -z "${VCLUSTER_IP}" ]]; then
    echo "ERROR: Could not get LoadBalancer IP for ${VCLUSTER}"
    exit 1
fi

echo "LoadBalancer IP: ${VCLUSTER_IP}"

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

# Check if it already points to the correct IP
if echo "${KUBECONFIG_DATA}" | grep -q "https://${VCLUSTER_IP}:443"; then
    echo "Kubeconfig already points to ${VCLUSTER_IP}:443. No fix needed."
    exit 0
fi

# Replace localhost:8443 with LoadBalancer IP
FIXED_KUBECONFIG=$(echo "${KUBECONFIG_DATA}" | sed "s|https://localhost:8443|https://${VCLUSTER_IP}:443|g")

# Update the secret
echo "Updating kubeconfig secret..."
kubectl get secret -n "${VCLUSTER}" "${SECRET}" -o json | \
    jq --arg config "$(echo "${FIXED_KUBECONFIG}" | base64 -w 0)" '.data.config = $config' | \
    kubectl apply -f -

echo ""
echo "=== Kubeconfig fixed for ${VCLUSTER} ==="
echo "API server: https://${VCLUSTER_IP}:443"
echo ""
echo "Flux will now be able to deploy workloads to ${VCLUSTER}."
echo "Trigger reconciliation: flux reconcile ks ${VCLUSTER} --with-source"
