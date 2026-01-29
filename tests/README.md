# End-to-End Testing Suite

This directory contains comprehensive testing scripts for the kind-vcluster-flux-poc project.

## Test Scripts

### 1. Prerequisites Check (`check-prerequisites.sh`)

Validates that all prerequisites are met and checks the current state of the cluster.

**Usage:**
```bash
./tests/check-prerequisites.sh
```

**What it checks:**
- Docker installation and status
- kubectl installation
- Go installation
- curl availability
- Local tools (kind, flux, vcluster) in `./bin/` directory
- `/etc/hosts` configuration
- Cluster running status
- Basic deployment status (if cluster is running)

**When to use:**
- Before deploying the cluster
- To troubleshoot setup issues
- To verify prerequisites are met

### 2. End-to-End Test (`e2e-test.sh`)

Comprehensive end-to-end test suite that validates the entire deployment.

**Usage:**
```bash
./tests/e2e-test.sh
```

**What it tests:**

#### Host Cluster
- kubectl context configuration
- Cluster reachability
- Node readiness status

#### Flux GitOps
- Flux namespace existence
- All Flux controllers (source, kustomize, helm, notification)
- Kustomization reconciliation status
- HelmRelease status

#### Infrastructure Components
- **MetalLB**: Controller deployment, IPAddressPool configuration
- **cert-manager**: Controller deployment
- **Traefik**: Deployment, LoadBalancer service, Gateway configuration
- **Gateway API**: GatewayClass and Gateway resources
- **Kube-Prometheus-Stack**: Prometheus StatefulSet

#### Virtual Clusters
- VCluster namespaces
- VCluster StatefulSets
- VCluster pod readiness
- LoadBalancer IP assignments (172.17.0.210 for vcluster-a, 172.17.0.211 for vcluster-b)

#### Tenant Workloads
- Tenant namespaces (tenant-a, tenant-b)
- Nginx deployments
- HTTPRoute configurations

#### HTTP Routes (End-to-End)
- Traefik endpoint accessibility
- Tenant A nginx HTTP endpoint (http://tenant-a.traefik.local)
- Tenant B nginx HTTP endpoint (http://tenant-b.traefik.local)
- Response content validation

#### Resource Summary
- Overview of all namespaces, HelmReleases, Kustomizations, HTTPRoutes, and Gateways

**Test Results:**
The script provides color-coded output:
- 🟢 GREEN: Test passed
- 🔴 RED: Test failed
- 🟡 YELLOW: Test in progress
- 🔵 BLUE: Informational message

## Prerequisites

Before running the end-to-end tests, ensure:

1. **Cluster is deployed:**
   ```bash
   export GITHUB_TOKEN=<your-github-token>
   make install
   ```

2. **All prerequisites are met:**
   - Docker is running
   - kubectl is installed
   - /etc/hosts is configured

3. **Verify setup:**
   ```bash
   ./tests/check-prerequisites.sh
   ```

## Quick Start

1. Check prerequisites:
   ```bash
   ./tests/check-prerequisites.sh
   ```

2. If cluster is not running, deploy it:
   ```bash
   export GITHUB_TOKEN=<your-github-token>
   make install
   ```

3. Run end-to-end tests:
   ```bash
   ./tests/e2e-test.sh
   ```

## Troubleshooting

### Cluster Not Running
If you see "Cannot switch to kind-host-cluster context":
```bash
# Check if cluster exists
docker ps | grep host-cluster

# If not running, deploy it
make install
```

### Failed HTTP Tests
If HTTP route tests fail:
```bash
# Check /etc/hosts
cat /etc/hosts | grep traefik

# If missing, add entries
sudo ./hack/add_host.sh 172.18.0.200 traefik.local
sudo ./hack/add_host.sh 172.18.0.200 tenant-a.traefik.local
sudo ./hack/add_host.sh 172.18.0.200 tenant-b.traefik.local

# Verify Traefik LoadBalancer IP
kubectl get svc -n traefik
```

### Flux Reconciliation Issues
If Flux components fail:
```bash
# Check Flux status
flux check
flux get all

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization flux-system
```

### VCluster Issues
If VClusters are not ready:
```bash
# Check VCluster status
kubectl get statefulsets -n vcluster-a
kubectl get statefulsets -n vcluster-b

# Check VCluster logs
kubectl logs -n vcluster-a statefulset/vcluster-a
kubectl logs -n vcluster-b statefulset/vcluster-b
```

## Test Results Interpretation

### All Tests Pass (Exit Code 0)
The entire stack is deployed correctly and functional:
- Host cluster is healthy
- Flux is reconciling successfully
- All infrastructure components are running
- Both VClusters are operational
- Tenant workloads are accessible via HTTP

### Some Tests Fail (Exit Code 1)
Check the test output to identify which component failed:
- **Host Cluster failures**: Check node status, Docker daemon
- **Flux failures**: Check Flux logs, GitRepository reconciliation
- **Infrastructure failures**: Check specific component logs
- **VCluster failures**: Check StatefulSet status, LoadBalancer configuration
- **Tenant failures**: Check deployment status, HTTPRoute configuration
- **HTTP failures**: Check /etc/hosts, Traefik service, network connectivity

## Continuous Integration

These tests can be integrated into CI/CD pipelines:

```bash
# In your CI script
./tests/check-prerequisites.sh || exit 1
./tests/e2e-test.sh || exit 1
```

## Test Coverage

The test suite provides comprehensive coverage:
- ✅ Cluster provisioning and configuration
- ✅ GitOps deployment via Flux
- ✅ Infrastructure components
- ✅ Virtual cluster multi-tenancy
- ✅ Tenant workload deployment
- ✅ Network routing and ingress
- ✅ End-to-end HTTP connectivity

## Adding New Tests

To add new tests to `e2e-test.sh`:

1. Create a new test function:
   ```bash
   test_my_component() {
       print_header "Testing My Component"

       run_test "Check my component" \
           "kubectl get deployment my-component -n my-namespace" \
           "My component exists"
   }
   ```

2. Call it from the `main()` function:
   ```bash
   main() {
       # ... existing tests ...
       test_my_component
       # ...
   }
   ```

## License

Same as parent project.
