## kind + vcluster + flux multi-tenancy PoC
[vcluster](https://www.vcluster.com/) + [flux](https://fluxcd.io/) multi-tenancy  PoC

vcluster - Create fully functional virtual Kubernetes clusters - Each vcluster runs inside a namespace of the underlying k8s cluster. It's cheaper than creating separate full-blown clusters and it offers better multi-tenancy and isolation than regular namespaces.

### Requirenments
- Linux laptop/workstation
- Docker installed
- Go installed

Install Go
```
$ wget https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
$ sudo tar -C /usr/local -xzf go1.25.0.linux-amd64.tar.gz

file: ~/.profile 
export PATH=$PATH:/usr/local/go/bin

file ~/.bashrc
export GOROOT=/usr/local/go
export PATH=${GOROOT}/bin:${PATH}
export GOPATH=$HOME/go
export PATH=${GOPATH}/bin:${PATH}

$ source ./.profile
$ go version
go version go1.25.0 linux/amd64

```

### Install

```bash
export GITHUB_TOKEN=<your-personal-access-token>
make install
```
### Quick Health Check Script

```bash
./tests/health-check.sh
```

### Automated End-to-End Tests

Run the comprehensive test suite:

```bash
# Check prerequisites first
./tests/check-prerequisites.sh

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

### Adding a New Tenant

Each tenant gets its own virtual cluster (vcluster) with full isolation. An automated script handles all the file creation.

#### Quick Start

```bash
# Add a new tenant (e.g., tenant-d with vcluster IP 172.18.0.215)
make add-tenant TENANT_NAME=d TENANT_IP=172.18.0.215

# Commit and push
git add -A && git commit -m "Add tenant-d with vcluster-d" && git push

# Reconcile Flux (or wait for auto-reconciliation)
flux reconcile ks flux-system --with-source

# Wait for vcluster to be ready, then fix the kubeconfig
make fix-kubeconfig TENANT_NAME=d

# Verify
curl -Lk --resolve tenant-d.traefik.local:80:172.18.0.200 \
         --resolve tenant-d.traefik.local:443:172.18.0.200 \
         http://tenant-d.traefik.local
```

#### IP Address Allocation

The MetalLB pool is `172.18.0.200-172.18.0.220`. Current allocations:

| Service | IP |
|---------|-----|
| Traefik | 172.18.0.200 |
| vcluster-a | 172.18.0.210 |
| vcluster-b | 172.18.0.211 |
| Grafana | 172.18.0.212 |
| Prometheus | 172.18.0.213 |
| vcluster-c | 172.18.0.214 |

Pick an unused IP from the pool for each new tenant.

#### What the Script Creates

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
```

It also modifies:
- `clusters/host-cluster/kustomization.yaml` - registers the new Flux Kustomizations
- `infrastructure/traefik/config/referencegrant.yaml` - allows cross-namespace routing

#### Step-by-Step (Manual)

If you prefer to create files manually instead of using the script:

1. **Create vcluster definition** - Copy `clusters/vcluster-a/` to `clusters/vcluster-<name>/` and replace all occurrences of `vcluster-a` with `vcluster-<name>` and the IP `172.18.0.210` with your chosen IP.

2. **Create tenant workloads** - Copy `tenant/tenant-a/` to `tenant/tenant-<name>/` and replace all occurrences of `tenant-a` with `tenant-<name>` and `vcluster-a` with `vcluster-<name>`.

3. **Create Flux orchestration** - Copy `clusters/host-cluster/vcluster-a_kustomization.yaml` and `clusters/host-cluster/tenant-a_kustomization.yaml`, renaming and updating references.

4. **Register in root kustomization** - Add the two new files to `clusters/host-cluster/kustomization.yaml`.

5. **Add ReferenceGrant** - Append a new ReferenceGrant block to `infrastructure/traefik/config/referencegrant.yaml`.

6. **Add /etc/hosts entry** - `sudo ./hack/add_host.sh 172.18.0.200 tenant-<name>.traefik.local`

7. **Commit, push, reconcile, fix kubeconfig** (same as Quick Start above).

#### Why Fix the Kubeconfig?

VCluster generates a kubeconfig secret (`vc-vcluster-<name>`) pointing to `localhost:8443`. Flux needs to reach the vcluster API server via its MetalLB LoadBalancer IP. The `fix-vcluster-kubeconfig.sh` script rewrites the kubeconfig to use `https://<vcluster-ip>:443`.

This is a one-time fix per vcluster. After fixing, Flux can deploy workloads to the vcluster.

#### Removing a Tenant

```bash
make remove-tenant TENANT_NAME=d
git add -A && git commit -m "Remove tenant-d and vcluster-d" && git push
flux reconcile ks flux-system --with-source
```

#### Architecture

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
                    |    |-- tenant-b.traefik.local           |
                    |    |     HTTPRoute -> nginx-x-default-x-vcluster-b
                    |    |                                    |
                    |    `-- tenant-c.traefik.local           |
                    |          HTTPRoute -> nginx-x-default-x-vcluster-c
                    |                                         |
  Flux GitOps       |  vcluster-a (172.18.0.210)             |
  (auto-deploy) --> |    namespace: vcluster-a               |
                    |    synced svc: nginx-x-default-x-vcluster-a
                    |                                         |
                    |  vcluster-b (172.18.0.211)             |
                    |    namespace: vcluster-b               |
                    |    synced svc: nginx-x-default-x-vcluster-b
                    |                                         |
                    |  vcluster-c (172.18.0.214)             |
                    |    namespace: vcluster-c               |
                    |    synced svc: nginx-x-default-x-vcluster-c
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
# Get Grafana admin password
kubectl get secret -n kube-prometheus-stack kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```


REF: https://github.com/loft-sh/vcluster

[Credits](https://github.com/mmontes11/vcluster-poc)

