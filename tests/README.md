# End-to-End Testing Suite

This directory contains the end-to-end testing script for the kind-vcluster-flux-poc project.

## Test Script

### End-to-End Test (`e2e-test.sh`)

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
- **Traefik**: Deployment, LoadBalancer service (172.18.0.200), Gateway configuration
- **Gateway API**: GatewayClass and Gateway resources
- **Kube-Prometheus-Stack**: Prometheus StatefulSet

#### Virtual Clusters
- VCluster namespaces (vcluster-a, vcluster-b, vcluster-c)
- VCluster StatefulSets
- VCluster pod readiness
- LoadBalancer IP assignments (172.18.0.210 for vcluster-a, 172.18.0.211 for vcluster-b, 172.18.0.214 for vcluster-c)

#### Tenant Workloads
- Tenant namespaces (tenant-a, tenant-b, tenant-c)
- HTTPRoute configurations
- Nginx service sync from vclusters to host cluster

#### HTTP Routes (End-to-End)
- Traefik endpoint accessibility
- Tenant A nginx HTTP endpoint (http://tenant-a.traefik.local)
- Tenant B nginx HTTP endpoint (http://tenant-b.traefik.local)
- Tenant C nginx HTTP endpoint (http://tenant-c.traefik.local)
- Response content validation
- Uses `--resolve` flags to avoid `/etc/hosts` dependency

#### Network Isolation
- NetworkPolicy existence in each vcluster namespace (deny-all-ingress, allow-same-namespace, allow-traefik-ingress, allow-flux-to-vcluster-api, allow-external-vcluster-api)
- Cross-vcluster isolation (traffic between vcluster namespaces should be blocked)
- Same-namespace communication (traffic within a vcluster namespace should be allowed)
- External vcluster API access via LoadBalancer IPs

#### Resource Summary
- Overview of all namespaces, HelmReleases, Kustomizations, HTTPRoutes, and Gateways

**Test Results:**
The script provides color-coded output:
- GREEN: Test passed
- RED: Test failed
- YELLOW: Test in progress
- BLUE: Informational message

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
   - /etc/hosts is configured (optional -- tests use `--resolve` flags)

## Quick Start

1. If cluster is not running, deploy it:
   ```bash
   export GITHUB_TOKEN=<your-github-token>
   make install
   ```

2. Run end-to-end tests:
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
kubectl get statefulsets -n vcluster-c

# Check VCluster logs
kubectl logs -n vcluster-a statefulset/vcluster-a
kubectl logs -n vcluster-b statefulset/vcluster-b
kubectl logs -n vcluster-c statefulset/vcluster-c
```

### Network Isolation Test Failures
If cross-vcluster isolation tests fail:
```bash
# Check NetworkPolicies are applied
kubectl get networkpolicies -n vcluster-a
kubectl get networkpolicies -n vcluster-b
kubectl get networkpolicies -n vcluster-c

# Verify Cilium is running
kubectl get pods -n kube-system -l k8s-app=cilium
```

## Test Results Interpretation

### All Tests Pass (Exit Code 0)
The entire stack is deployed correctly and functional:
- Host cluster is healthy
- Flux is reconciling successfully
- All infrastructure components are running
- All VClusters (a, b, c) are operational
- Tenant workloads are accessible via HTTP
- Network isolation between vclusters is enforced

### Some Tests Fail (Exit Code 1)
Check the test output to identify which component failed:
- **Host Cluster failures**: Check node status, Docker daemon
- **Flux failures**: Check Flux logs, GitRepository reconciliation
- **Infrastructure failures**: Check specific component logs
- **VCluster failures**: Check StatefulSet status, LoadBalancer configuration
- **Tenant failures**: Check deployment status, HTTPRoute configuration
- **HTTP failures**: Check /etc/hosts, Traefik service, network connectivity
- **Network isolation failures**: Check NetworkPolicies, Cilium status

## Continuous Integration

These tests can be integrated into CI/CD pipelines:

```bash
# In your CI script
./tests/e2e-test.sh || exit 1
```

## Test Coverage

The test suite provides comprehensive coverage:
- Cluster provisioning and configuration
- GitOps deployment via Flux
- Infrastructure components (MetalLB, Traefik, cert-manager, Prometheus)
- Virtual cluster multi-tenancy (vcluster-a, vcluster-b, vcluster-c)
- Tenant workload deployment
- Network routing and ingress
- End-to-end HTTP connectivity
- Network isolation between vclusters

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
