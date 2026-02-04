# kind with cilium + vcluster + flux multi-tenancy PoC

[vcluster](https://www.vcluster.com/) + [Flux Operator](https://fluxcd.control-plane.io/operator/) multi-tenancy PoC

vcluster - Create fully functional virtual Kubernetes clusters - Each vcluster runs inside a namespace of the underlying host k8s cluster.

## Requirements

- Linux laptop/workstation
- Docker installed
- Go installed
- Helm installed

Install Go
```bash
wget https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.25.0.linux-amd64.tar.gz

# file: ~/.profile
export PATH=$PATH:/usr/local/go/bin

# file: ~/.bashrc
export GOROOT=/usr/local/go
export PATH=${GOROOT}/bin:${PATH}
export GOPATH=$HOME/go
export PATH=${GOPATH}/bin:${PATH}

source ./.profile
go version
# go version go1.25.0 linux/amd64
```

## Install

Flux is managed via the [Flux Operator](https://fluxcd.control-plane.io/operator/) and a `FluxInstance` CRD (see [flux-instance.yaml](clusters/host-cluster/flux-instance.yaml)). The `make install` target installs the operator, creates Git credentials from `GITHUB_TOKEN`, and applies the FluxInstance.

```bash
export GITHUB_TOKEN=<your-personal-access-token>
make install
```

## Automated End-to-End Tests

Run the comprehensive test suite:

```bash
# Run full end-to-end tests (50+ tests)
./tests/e2e-test.sh
```

The e2e test validates:
- Host cluster health
- Flux GitOps reconciliation
- Infrastructure (MetalLB, Traefik, cert-manager, Prometheus)
- VClusters (vcluster-a, vcluster-b)
- Tenant workloads
- HTTP routing
- Network isolation between vClusters

See [tests/README.md](tests/README.md) for detailed test documentation.

## Adding a New Tenant

Each tenant gets its own virtual cluster (vcluster) with full isolation. An automated script handles all the file creation.

### IP Address Allocation

The MetalLB pool is `172.18.0.200-172.18.0.220`. Current allocations:

| Service | IP |
|---------|-----|
| Traefik | 172.18.0.200 |
| vcluster-a | 172.18.0.210 |
| vcluster-b | 172.18.0.211 |
| Grafana | 172.18.0.212 |
| Prometheus | 172.18.0.213 |
| vcluster-platform | 172.18.0.219 |

Pick an unused IP from the pool for each new tenant.

```bash
# Add a new tenant (e.g., tenant-d with vcluster IP 172.18.0.215)
make add-tenant TENANT_NAME=d TENANT_IP=172.18.0.215

# Commit and push
git add -A && git commit -m "Add tenant-d with vcluster-d" && git push

# Reconcile Flux (or wait for auto-reconciliation)
flux reconcile ks flux-system --with-source

# Verify
curl -Lk --resolve tenant-d.traefik.local:80:172.18.0.200 \
  --resolve tenant-d.traefik.local:443:172.18.0.200 \
  http://tenant-d.traefik.local
```

### What the Script Creates

Running `./hack/add-tenant.sh <name> <ip>` creates these files:

```
clusters/vcluster-<name>/                     # VCluster definition
  kustomization.yaml                          # Kustomize resource list
  vcluster-<name>_namespace.yaml              # Namespace for the vcluster
  vcluster-<name>_helmrepository.yaml         # Loft Helm chart repo
  vcluster-<name>_helmrelease.yaml            # VCluster Helm release with LoadBalancer IP

tenant/tenant-<name>/                         # Tenant workloads + routes
  kustomization.yaml                          # Kustomize resource list
  tenant-<name>_namespace.yaml                # Namespace for tenant routes
  workload_kustomization.yaml                 # Flux Kustomization (deploys to vcluster)
  routes_kustomization.yaml                   # Flux Kustomization (deploys HTTPRoute to host)
  workload/
    kustomization.yaml
    nginx_deployment.yaml                     # Sample nginx workload
    nginx_service.yaml
  routes/
    kustomization.yaml
    nginx_httproute.yaml                      # HTTPRoute for tenant-<name>.traefik.local

clusters/host-cluster/                        # Flux orchestration (new files)
  vcluster-<name>_kustomization.yaml          # Flux Kustomization for vcluster
  tenant-<name>_kustomization.yaml            # Flux Kustomization for tenant

infrastructure/network-policies/              # Network isolation
  vcluster-<name>-netpol.yaml                 # NetworkPolicies for the vcluster namespace
```

It also modifies:
- `clusters/host-cluster/kustomization.yaml` - registers the new Flux Kustomizations
- `clusters/host-cluster/infrastructure_kustomization.yaml` - adds vcluster as dependency for network-policies
- `infrastructure/traefik/config/referencegrant.yaml` - allows cross-namespace routing
- `infrastructure/network-policies/kustomization.yaml` - registers the new NetworkPolicy file
- `/etc/hosts` - adds `tenant-<name>.traefik.local` entry pointing to Traefik IP

### Test vCluster Connectivity

After adding a tenant, connect to verify:

```bash
# Connect to the new vcluster (--driver helm is required for Helm-managed vclusters)
./bin/vcluster connect vcluster-<name> -n vcluster-<name> --driver helm

# Check namespaces inside vcluster
kubectl get namespaces

# Check pods inside vcluster
kubectl get pods -A

# Expected: nginx pod in default namespace

# Check services
kubectl get svc

# Disconnect
./bin/vcluster disconnect
```

### Removing a Tenant

```bash
make remove-tenant TENANT_NAME=d
git add -A && git commit -m "Remove tenant-d and vcluster-d" && git push
flux reconcile ks flux-system --with-source
```

## Architecture

```
                    Host Cluster (kind)
                    +-----------------------------------------+
                    |                                         |
                    |  Traefik (Gateway API)                  |
                    |    172.18.0.200                         |
                    |    |                                    |
                    |    |-- tenant-a.traefik.local           |
                    |    |     HTTPRoute -> nginx-x-default-x-vcluster-a
                    |    |                                    |
                    |    `-- tenant-b.traefik.local           |
                    |          HTTPRoute -> nginx-x-default-x-vcluster-b
                    |                                         |
  Flux GitOps       |  vcluster-a (172.18.0.210)             |
  (auto-deploy) --> |    namespace: vcluster-a               |
                    |    synced svc: nginx-x-default-x-vcluster-a
                    |                                         |
                    |  vcluster-b (172.18.0.211)             |
                    |    namespace: vcluster-b               |
                    |    synced svc: nginx-x-default-x-vcluster-b
                    |                                         |
                    +-----------------------------------------+
```

Each vcluster syncs its services to the host cluster using the naming pattern `<service>-x-<namespace>-x-<vcluster-name>`. The HTTPRoutes reference these synced services, and ReferenceGrants allow cross-namespace access.

## Accessing Prometheus and Grafana

Both Prometheus and Grafana are deployed via the kube-prometheus-stack and exposed with MetalLB LoadBalancer IPs.

| Service | Internal IP | Port |
|---------|------------|------|
| Grafana | 172.18.0.212 | 80 |
| Prometheus | 172.18.0.213 | 9090 |

### Access from Browser (WSL2 / Local)

Since the MetalLB IPs are on Docker's internal network, use `kubectl port-forward` to expose them on localhost:

```bash
# Grafana on http://localhost:3000
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80

# Prometheus on http://localhost:9090 (open a separate terminal)
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-prometheus 9090:9090
```

Then open in your browser:
- **Grafana**: http://localhost:3000
- **Prometheus**: http://localhost:9090

To run port-forwards in the background:

```bash
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-prometheus 9090:9090 &

# Stop them later
kill %1 %2
# Or: pkill -f "port-forward.*kube-prometheus-stack"
```

### Grafana Credentials

The default username is `admin`. To retrieve the password:

```bash
kubectl get secret -n kube-prometheus-stack kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

---

## Network Isolation

The cluster uses Cilium CNI with NetworkPolicies to enforce tenant isolation. Each vcluster namespace has a default-deny ingress policy with explicit allow rules for required traffic.

### Verify NetworkPolicies Are Applied

```bash
# List NetworkPolicies per vcluster namespace
kubectl get networkpolicies -n vcluster-a
kubectl get networkpolicies -n vcluster-b

# Expected policies per namespace:
#   deny-all-ingress            - Default deny all inbound traffic
#   allow-same-namespace        - Pods within the namespace can communicate
#   allow-traefik-ingress       - Traefik can reach nginx on port 80
#   allow-flux-to-vcluster-api  - Flux can deploy workloads on port 8443
#   allow-dns                   - DNS resolution from kube-system
#   allow-prometheus-scraping   - Prometheus metrics scraping
#   allow-external-vcluster-api - External vcluster connect on port 8443
#   allow-metallb               - MetalLB speaker communication
```

### Test Cross-VCluster Isolation (Should Be Blocked)

These tests verify that pods in one vcluster namespace cannot reach pods in another. Each test runs a temporary busybox pod and attempts to connect to a nginx pod in a different namespace.

```bash
# Get nginx pod IPs
kubectl get pods -l app=nginx -A -o wide

# Test: vcluster-a -> vcluster-b (should timeout)
kubectl run test-isolation --rm -i --restart=Never --image=busybox -n vcluster-a \
  -- wget -qO- --timeout=3 http://nginx-x-default-x-vcluster-b.vcluster-b.svc:80
# Expected: "wget: download timed out" (blocked by NetworkPolicy)

# Test: vcluster-b -> vcluster-a (should timeout)
kubectl run test-isolation --rm -i --restart=Never --image=busybox -n vcluster-b \
  -- wget -qO- --timeout=3 http://nginx-x-default-x-vcluster-a.vcluster-a.svc:80
# Expected: "wget: download timed out"
```

You can also test using pod IPs directly (useful if DNS is not resolving cross-namespace):

```bash
# Get the target pod IP
NGINX_B_IP=$(kubectl get pod -n vcluster-b -l app=nginx -o jsonpath='{.items[0].status.podIP}')

# Test: vcluster-a -> vcluster-b by pod IP (should timeout)
kubectl run test-isolation --rm -i --restart=Never --image=busybox -n vcluster-a \
  -- wget -qO- --timeout=3 http://${NGINX_B_IP}:80
# Expected: "wget: download timed out"
```

### Test Same-Namespace Communication (Should Work)

```bash
# Test: pod in vcluster-a can reach nginx in vcluster-a (same namespace)
kubectl run test-same-ns --rm -i --restart=Never --image=busybox -n vcluster-a \
  -- wget -qO- --timeout=3 http://nginx-x-default-x-vcluster-a.vcluster-a.svc:80
# Expected: nginx welcome page HTML
```

### Test Traefik Ingress (Should Work)

```bash
TRAEFIK_IP=172.18.0.200

# Traefik -> tenant-a
curl -Lk --resolve tenant-a.traefik.local:80:${TRAEFIK_IP} \
  --resolve tenant-a.traefik.local:443:${TRAEFIK_IP} \
  http://tenant-a.traefik.local
# Expected: nginx welcome page

# Traefik -> tenant-b
curl -Lk --resolve tenant-b.traefik.local:80:${TRAEFIK_IP} \
  --resolve tenant-b.traefik.local:443:${TRAEFIK_IP} \
  http://tenant-b.traefik.local

```

### Test External VCluster API Access (Should Work)

```bash
# vcluster connect uses the LoadBalancer IP to reach the vcluster API
# --driver helm is required for Helm-managed vclusters (vcluster CLI v0.31+ defaults to platform driver)
./bin/vcluster connect vcluster-a -n vcluster-a --driver helm
kubectl get pods -A
./bin/vcluster disconnect

# Or test the API directly via curl
curl -sk https://172.18.0.210:443/healthz   # vcluster-a
curl -sk https://172.18.0.211:443/healthz   # vcluster-b
# Expected: "ok"
```

### Network Isolation Summary

| From | To | Port | Expected | Why |
|------|-----|------|----------|-----|
| vcluster-a pod | vcluster-b pod | 80 | BLOCKED | Cross-namespace isolation |
| vcluster-a pod | vcluster-a pod | any | ALLOWED | Same-namespace policy |
| Traefik (ns: traefik) | nginx in vcluster-X | 80 | ALLOWED | allow-traefik-ingress |
| Flux (ns: flux-system) | vcluster-X-0 | 8443 | ALLOWED | allow-flux-to-vcluster-api |
| External (vcluster connect) | vcluster-X-0 | 8443 | ALLOWED | allow-external-vcluster-api |
| kube-system (CoreDNS) | vcluster-X pods | 53 | ALLOWED | allow-dns |
| Prometheus | vcluster-X pods | metrics | ALLOWED | allow-prometheus-scraping |
| MetalLB speaker | vcluster-X pods | any | ALLOWED | allow-metallb |

---

## Hubble UI

The Hubble UI is running as a ClusterIP service. Use port-forward to access it:

```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

Then open http://localhost:12000 in your browser.

---

## vCluster Platform

The [vCluster Platform](https://www.vcluster.com/docs/platform) provides a management UI and API for all virtual clusters. It is deployed via Flux as a HelmRelease in the `vcluster-platform` namespace and exposed on MetalLB IP `172.18.0.219`.

The `make install` target runs `hack/setup-platform.sh` which automatically:
1. Waits for the platform to be healthy
2. Configures CLI access (obtains an access key via the API)
3. Imports vcluster-a and vcluster-b into the platform (requires an active license)

### Accessing the Platform UI

Since MetalLB IPs are on Docker's internal network, use port-forward:

```bash
kubectl port-forward -n vcluster-platform svc/loft 9443:443
```

Then open https://localhost:9443 in your browser.

**Credentials:** `admin` / `admin`

### Managing vClusters in the Platform

After adding a new tenant with `make add-tenant`, import it into the platform:

```bash
./bin/vcluster platform add vcluster <name> \
    --namespace <name> \
    --project default \
    --import-name <name> \
    --host "https://loft.vcluster-platform.svc:443" \
    --insecure
```

To remove a vcluster from the platform (does not delete the vcluster itself):

```bash
kubectl delete virtualclusterinstance <name> -n p-default
```

To list managed vclusters:

```bash
./bin/vcluster platform list vclusters --project default
```

> **Note:** Importing vclusters requires an activated platform license. Without a license the platform UI is accessible but vcluster management is disabled. Visit the platform UI to activate.

---

REF: https://github.com/loft-sh/vcluster

