#!/bin/bash
#
# Add a new tenant with its own vcluster to the GitOps repository.
#
# Usage:
#   ./hack/add-tenant.sh <name> <vcluster-ip>
#
# Example:
#   ./hack/add-tenant.sh d 172.18.0.215
#
# This creates:
#   - VCluster definition (clusters/vcluster-<name>/)
#   - Tenant workloads and routes (tenant/tenant-<name>/)
#   - Flux orchestration (clusters/host-cluster/)
#   - ReferenceGrant for cross-namespace routing
#   - NetworkPolicy for vcluster namespace isolation
#   - /etc/hosts entry for tenant-<name>.traefik.local
#
# After running this script:
#   1. git add -A && git commit -m "Add tenant-<name> with vcluster-<name>"
#   2. git push
#   3. Wait for Flux reconciliation (or run: flux reconcile ks flux-system --with-source)
#   4. Fix vcluster kubeconfig: ./hack/fix-vcluster-kubeconfig.sh <name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Argument parsing ---
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <name> <vcluster-ip>"
    echo ""
    echo "Arguments:"
    echo "  name        Short tenant name (e.g., 'd' creates tenant-d / vcluster-d)"
    echo "  vcluster-ip MetalLB IP for the vcluster LoadBalancer (e.g., 172.18.0.215)"
    echo ""
    echo "Current IP allocations:"
    echo "  172.18.0.200  - Traefik"
    echo "  172.18.0.210  - vcluster-a"
    echo "  172.18.0.211  - vcluster-b"
    echo "  172.18.0.212  - Grafana"
    echo "  172.18.0.213  - Prometheus"
    echo "  172.18.0.214  - vcluster-c"
    echo "  Pool range: 172.18.0.200-172.18.0.220"
    exit 1
fi

NAME="$1"
VCLUSTER_IP="$2"
TENANT="tenant-${NAME}"
VCLUSTER="vcluster-${NAME}"
HOSTNAME="${TENANT}.traefik.local"
TRAEFIK_IP="172.18.0.200"

echo "=== Adding tenant: ${TENANT} with vcluster: ${VCLUSTER} (IP: ${VCLUSTER_IP}) ==="
echo ""

# --- Validate IP not already in use ---
if grep -rq "loadBalancerIPs: ${VCLUSTER_IP}" "${REPO_ROOT}/clusters/" "${REPO_ROOT}/infrastructure/" 2>/dev/null; then
    echo "ERROR: IP ${VCLUSTER_IP} is already allocated. Check current allocations."
    exit 1
fi

# --- Validate tenant doesn't already exist ---
if [[ -d "${REPO_ROOT}/clusters/${VCLUSTER}" ]]; then
    echo "ERROR: ${VCLUSTER} already exists at clusters/${VCLUSTER}/"
    exit 1
fi
if [[ -d "${REPO_ROOT}/tenant/${TENANT}" ]]; then
    echo "ERROR: ${TENANT} already exists at tenant/${TENANT}/"
    exit 1
fi

# ============================================================
# 1. VCluster definition: clusters/vcluster-<name>/
# ============================================================
echo "[1/7] Creating vcluster definition: clusters/${VCLUSTER}/"

mkdir -p "${REPO_ROOT}/clusters/${VCLUSTER}"

cat > "${REPO_ROOT}/clusters/${VCLUSTER}/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${VCLUSTER}
resources:
  - ${VCLUSTER}_helmrelease.yaml
  - ${VCLUSTER}_helmrepository.yaml
  - ${VCLUSTER}_namespace.yaml
EOF

cat > "${REPO_ROOT}/clusters/${VCLUSTER}/${VCLUSTER}_namespace.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${VCLUSTER}
EOF

cat > "${REPO_ROOT}/clusters/${VCLUSTER}/${VCLUSTER}_helmrepository.yaml" << EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: loft
spec:
  interval: 2m
  url: https://charts.loft.sh
EOF

cat > "${REPO_ROOT}/clusters/${VCLUSTER}/${VCLUSTER}_helmrelease.yaml" << EOF
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${VCLUSTER}
spec:
  chart:
    spec:
      chart: vcluster
      sourceRef:
        kind: HelmRepository
        name: loft
      version: "0.30.4"
  interval: 2m
  values:
    controlPlane:
      service:
        annotations:
          metallb.universe.tf/loadBalancerIPs: ${VCLUSTER_IP}
        spec:
          type: LoadBalancer
      distro:
        k3s:
          enabled: true
          extraArgs:
            - --tls-san=${VCLUSTER_IP}
      statefulSet:
        env:
          - name: K3S_KUBECONFIG_OUTPUT
            value: /data/k3s-config/kube-config.yaml
          - name: K3S_KUBECONFIG_MODE
            value: "644"
      proxy:
        extraSANs:
          - ${VCLUSTER_IP}
    exportKubeConfig:
      server: "https://${VCLUSTER}.${VCLUSTER}:443"
    external:
      platform:
        apiServerHost: ${VCLUSTER_IP}
        apiServerPort: 443
    sync:
      toHost:
        pods:
          enabled: true
        services:
          enabled: true
        configMaps:
          enabled: true
        secrets:
          enabled: true
        endpoints:
          enabled: true
        persistentVolumeClaims:
          enabled: true
EOF

# ============================================================
# 2. Tenant workloads: tenant/tenant-<name>/
# ============================================================
echo "[2/7] Creating tenant workloads: tenant/${TENANT}/"

mkdir -p "${REPO_ROOT}/tenant/${TENANT}/workload"
mkdir -p "${REPO_ROOT}/tenant/${TENANT}/routes"

cat > "${REPO_ROOT}/tenant/${TENANT}/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${TENANT}_namespace.yaml
  - workload_kustomization.yaml
  - routes_kustomization.yaml
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/${TENANT}_namespace.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${TENANT}
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/workload_kustomization.yaml" << EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: workload
  namespace: ${VCLUSTER}
spec:
  kubeConfig:
    secretRef:
      name: vc-${VCLUSTER}
      key: config
  targetNamespace: default
  interval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  path: ./tenant/${TENANT}/workload
  prune: true
  timeout: 5m
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/routes_kustomization.yaml" << EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: routes
  namespace: ${TENANT}
spec:
  dependsOn:
    - name: workload
      namespace: ${VCLUSTER}
    - name: gateway-api
      namespace: flux-system
  targetNamespace: ${TENANT}
  interval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  path: ./tenant/${TENANT}/routes
  prune: true
  timeout: 5m
EOF

# --- Workload manifests (nginx) ---
cat > "${REPO_ROOT}/tenant/${TENANT}/workload/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - nginx_deployment.yaml
  - nginx_service.yaml
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/workload/nginx_deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - image: nginx:1.27-alpine
        name: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/workload/nginx_service.yaml" << EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
EOF

# --- Routes (HTTPRoute) ---
cat > "${REPO_ROOT}/tenant/${TENANT}/routes/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - nginx_httproute.yaml
EOF

cat > "${REPO_ROOT}/tenant/${TENANT}/routes/nginx_httproute.yaml" << EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx
spec:
  parentRefs:
    - name: traefik
      namespace: traefik
  hostnames:
    - "${HOSTNAME}"
  rules:
    - backendRefs:
        - kind: Service
          name: nginx-x-default-x-${VCLUSTER}
          namespace: ${VCLUSTER}
          port: 80
EOF

# ============================================================
# 3. Flux orchestration: clusters/host-cluster/
# ============================================================
echo "[3/7] Creating Flux orchestration in clusters/host-cluster/"

cat > "${REPO_ROOT}/clusters/host-cluster/${VCLUSTER}_kustomization.yaml" << EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${VCLUSTER}
  namespace: flux-system
spec:
  dependsOn:
    - name: metallb
    - name: metallb-config
    - name: gateway-api
    - name: traefik
  interval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./clusters/${VCLUSTER}
  prune: true
  timeout: 5m
EOF

cat > "${REPO_ROOT}/clusters/host-cluster/${TENANT}_kustomization.yaml" << EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${TENANT}
  namespace: flux-system
spec:
  dependsOn:
    - name: ${VCLUSTER}
  interval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./tenant/${TENANT}
  prune: true
EOF

# ============================================================
# 4. Register in root kustomization
# ============================================================
echo "[4/7] Updating clusters/host-cluster/kustomization.yaml"

KUSTOMIZATION_FILE="${REPO_ROOT}/clusters/host-cluster/kustomization.yaml"

# Add vcluster kustomization if not already present
if ! grep -q "${VCLUSTER}_kustomization.yaml" "${KUSTOMIZATION_FILE}"; then
    sed -i "/^resources:/a\\  - ${VCLUSTER}_kustomization.yaml" "${KUSTOMIZATION_FILE}"
fi

# Add tenant kustomization if not already present
if ! grep -q "${TENANT}_kustomization.yaml" "${KUSTOMIZATION_FILE}"; then
    sed -i "/^resources:/a\\  - ${TENANT}_kustomization.yaml" "${KUSTOMIZATION_FILE}"
fi

# ============================================================
# 5. Add ReferenceGrant
# ============================================================
echo "[5/7] Adding ReferenceGrant for ${TENANT} -> ${VCLUSTER}"

REFERENCEGRANT_FILE="${REPO_ROOT}/infrastructure/traefik/config/referencegrant.yaml"

# Check if ReferenceGrant already exists
if ! grep -q "allow-${TENANT}-to-${VCLUSTER}" "${REFERENCEGRANT_FILE}"; then
    cat >> "${REFERENCEGRANT_FILE}" << EOF
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-${TENANT}-to-${VCLUSTER}
  namespace: ${VCLUSTER}
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: ${TENANT}
  to:
    - group: ""
      kind: Service
EOF
fi

# ============================================================
# 6. Add /etc/hosts entry
# ============================================================
echo "[6/7] Adding /etc/hosts entry for ${HOSTNAME}"

"${SCRIPT_DIR}/add_host.sh" "${TRAEFIK_IP}" "${HOSTNAME}"

# ============================================================
# 7. Add NetworkPolicy for vcluster namespace isolation
# ============================================================
echo "[7/7] Adding NetworkPolicy for ${VCLUSTER} namespace isolation"

NETPOL_DIR="${REPO_ROOT}/infrastructure/network-policies"
NETPOL_FILE="${NETPOL_DIR}/${VCLUSTER}-netpol.yaml"
NETPOL_KUSTOMIZATION="${NETPOL_DIR}/kustomization.yaml"
INFRA_KUSTOMIZATION="${REPO_ROOT}/clusters/host-cluster/infrastructure_kustomization.yaml"

if [[ ! -f "${NETPOL_FILE}" ]]; then
    cat > "${NETPOL_FILE}" << EOF
# Default deny all ingress traffic to ${VCLUSTER} namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
# Allow pods within ${VCLUSTER} to communicate with each other
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
---
# Allow Traefik to reach synced nginx services (HTTP routing)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-traefik-ingress
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: 80
---
# Allow Flux to reach the vcluster API server (workload deployment)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-flux-to-vcluster-api
  namespace: ${VCLUSTER}
spec:
  podSelector:
    matchLabels:
      app: vcluster
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: flux-system
      ports:
        - protocol: TCP
          port: 8443
---
# Allow DNS resolution from kube-system
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Allow Prometheus to scrape metrics
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scraping
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-prometheus-stack
---
# Allow external access to vcluster API (vcluster connect, kubectl)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-vcluster-api
  namespace: ${VCLUSTER}
spec:
  podSelector:
    matchLabels:
      app: vcluster
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 172.18.0.0/16
      ports:
        - protocol: TCP
          port: 8443
---
# Allow MetalLB speaker communication
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-metallb
  namespace: ${VCLUSTER}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: metallb-system
EOF

    # Add to network-policies kustomization
    if ! grep -q "${VCLUSTER}-netpol.yaml" "${NETPOL_KUSTOMIZATION}"; then
        sed -i "/^resources:/a\\  - ${VCLUSTER}-netpol.yaml" "${NETPOL_KUSTOMIZATION}"
    fi

    # Add vcluster as dependency for network-policies Flux Kustomization
    if ! grep -q "name: ${VCLUSTER}$" "${INFRA_KUSTOMIZATION}"; then
        sed -i "/name: network-policies/,/timeout:/{/  interval: 2m/i\\    - name: ${VCLUSTER}
}" "${INFRA_KUSTOMIZATION}"
    fi
else
    echo "  NetworkPolicy already exists: ${NETPOL_FILE}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Done! Files created: ==="
echo ""
echo "  clusters/${VCLUSTER}/"
echo "    - kustomization.yaml"
echo "    - ${VCLUSTER}_namespace.yaml"
echo "    - ${VCLUSTER}_helmrepository.yaml"
echo "    - ${VCLUSTER}_helmrelease.yaml"
echo ""
echo "  tenant/${TENANT}/"
echo "    - kustomization.yaml"
echo "    - ${TENANT}_namespace.yaml"
echo "    - workload_kustomization.yaml"
echo "    - routes_kustomization.yaml"
echo "    - workload/kustomization.yaml"
echo "    - workload/nginx_deployment.yaml"
echo "    - workload/nginx_service.yaml"
echo "    - routes/kustomization.yaml"
echo "    - routes/nginx_httproute.yaml"
echo ""
echo "  clusters/host-cluster/"
echo "    - ${VCLUSTER}_kustomization.yaml"
echo "    - ${TENANT}_kustomization.yaml"
echo "    - kustomization.yaml (modified)"
echo ""
echo "  infrastructure/traefik/config/"
echo "    - referencegrant.yaml (modified)"
echo ""
echo "  infrastructure/network-policies/"
echo "    - ${VCLUSTER}-netpol.yaml"
echo "    - kustomization.yaml (modified)"
echo ""
echo "=== Next steps: ==="
echo ""
echo "  1. Commit and push:"
echo "     git add -A && git commit -m 'Add ${TENANT} with ${VCLUSTER}' && git push"
echo ""
echo "  2. Reconcile Flux (or wait for auto-reconciliation):"
echo "     flux reconcile ks flux-system --with-source"
echo ""
echo "  3. Wait for vcluster to be ready, then fix kubeconfig:"
echo "     ./hack/fix-vcluster-kubeconfig.sh ${NAME}"
echo ""
echo "  4. Verify:"
echo "     kubectl get pods -n ${VCLUSTER}"
echo "     kubectl get svc -n ${VCLUSTER} nginx-x-default-x-${VCLUSTER}"
echo "     kubectl get httproute -n ${TENANT}"
echo "     curl -Lk --resolve ${HOSTNAME}:80:${TRAEFIK_IP} --resolve ${HOSTNAME}:443:${TRAEFIK_IP} http://${HOSTNAME}"
