#!/bin/bash
#
# End-to-End Test for kind-vcluster-flux-poc
# This script validates the entire setup including host cluster, Flux, infrastructure, vclusters, and tenant workloads
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Configuration
CLUSTER_NAME="host-cluster"
VCLUSTER_A="vcluster-a"
VCLUSTER_B="vcluster-b"
VCLUSTER_C="vcluster-c"
TENANT_A_URL="http://tenant-a.traefik.local"
TENANT_B_URL="http://tenant-b.traefik.local"
TENANT_C_URL="http://tenant-c.traefik.local"
TRAEFIK_URL="http://traefik.local"

# Helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
    ((TOTAL_TESTS++))
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_TESTS++))
}

print_failure() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_TESTS++))
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"

    print_test "$test_name"

    if eval "$test_command"; then
        if [ -n "$expected_result" ]; then
            print_success "$test_name - $expected_result"
        else
            print_success "$test_name"
        fi
    else
        print_failure "$test_name"
    fi

    # Always return 0 to continue running all tests
    return 0
}

# Wait for resource with timeout
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local timeout="${4:-300}"
    local condition="${5:-ready}"

    print_info "Waiting for $resource_type/$resource_name in namespace $namespace to be $condition (timeout: ${timeout}s)"

    if kubectl wait --for=condition=$condition --timeout=${timeout}s -n "$namespace" "$resource_type/$resource_name" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Test 1: Host Cluster
test_host_cluster() {
    print_header "Testing Host Cluster"

    run_test "Check kubectl context is set to kind-$CLUSTER_NAME" \
        "kubectl config current-context | grep -q 'kind-$CLUSTER_NAME'" \
        "Context is correctly set"

    run_test "Verify host cluster is reachable" \
        "kubectl cluster-info &>/dev/null" \
        "Cluster is responding"

    run_test "Check all nodes are ready" \
        "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v 'Ready' | wc -l | grep -q '^0$'" \
        "All nodes are in Ready state"

    # List nodes
    print_info "Cluster nodes:"
    kubectl get nodes -o wide
}

# Test 2: Flux GitOps
test_flux() {
    print_header "Testing Flux GitOps"

    run_test "Check Flux namespace exists" \
        "kubectl get namespace flux-system &>/dev/null" \
        "flux-system namespace exists"

    run_test "Verify source-controller is running" \
        "kubectl get deployment -n flux-system source-controller -o jsonpath='{.status.availableReplicas}' | grep -q '^1$'" \
        "source-controller is available"

    run_test "Verify kustomize-controller is running" \
        "kubectl get deployment -n flux-system kustomize-controller -o jsonpath='{.status.availableReplicas}' | grep -q '^1$'" \
        "kustomize-controller is available"

    run_test "Verify helm-controller is running" \
        "kubectl get deployment -n flux-system helm-controller -o jsonpath='{.status.availableReplicas}' | grep -q '^1$'" \
        "helm-controller is available"

    run_test "Verify notification-controller is running" \
        "kubectl get deployment -n flux-system notification-controller -o jsonpath='{.status.availableReplicas}' | grep -q '^1$'" \
        "notification-controller is available"

    # Check Flux reconciliation status
    print_info "Flux Kustomizations status:"
    kubectl get kustomizations -A

    print_info "\nFlux HelmReleases status:"
    kubectl get helmreleases -A
}

# Test 3: Infrastructure Components
test_infrastructure() {
    print_header "Testing Infrastructure Components"

    # MetalLB
    run_test "Check MetalLB namespace exists" \
        "kubectl get namespace metallb-system &>/dev/null" \
        "metallb-system namespace exists"

    run_test "Verify MetalLB controller is running" \
        "kubectl get deployment -n metallb-system metallb-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1$'" \
        "MetalLB controller is available"

    run_test "Check MetalLB IPAddressPool exists" \
        "kubectl get ipaddresspool -n metallb-system loadbalancer &>/dev/null" \
        "MetalLB IPAddressPool configured"

    # Cert-Manager
    run_test "Check cert-manager namespace exists" \
        "kubectl get namespace cert-manager &>/dev/null" \
        "cert-manager namespace exists"

    run_test "Verify cert-manager is running" \
        "kubectl get deployment -n cert-manager cert-manager -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1$'" \
        "cert-manager is available"

    # Traefik
    run_test "Check traefik namespace exists" \
        "kubectl get namespace traefik &>/dev/null" \
        "traefik namespace exists"

    run_test "Verify Traefik is running" \
        "kubectl get deployment -n traefik traefik -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1$'" \
        "Traefik is available"

    run_test "Check Traefik LoadBalancer service" \
        "kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '172.18.0.200'" \
        "Traefik has correct LoadBalancer IP (172.18.0.200)"

    # Gateway API
    run_test "Check GatewayClass exists" \
        "kubectl get gatewayclass traefik &>/dev/null" \
        "GatewayClass configured"

    run_test "Check Gateway exists" \
        "kubectl get gateway -n traefik traefik-gateway &>/dev/null" \
        "Gateway configured"

    # Kube-Prometheus-Stack
    run_test "Check kube-prometheus-stack namespace exists" \
        "kubectl get namespace kube-prometheus-stack &>/dev/null" \
        "kube-prometheus-stack namespace exists"

    run_test "Verify Prometheus is running" \
        "kubectl get statefulset -n kube-prometheus-stack prometheus-kube-prometheus-stack-prometheus -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$'" \
        "Prometheus is available"

    print_info "\nInfrastructure pods status:"
    kubectl get pods -n metallb-system
    kubectl get pods -n cert-manager
    kubectl get pods -n traefik
    kubectl get pods -n kube-prometheus-stack
}

# Test 4: VClusters
test_vclusters() {
    print_header "Testing Virtual Clusters"

    # VCluster A
    run_test "Check vcluster-a namespace exists" \
        "kubectl get namespace $VCLUSTER_A &>/dev/null" \
        "$VCLUSTER_A namespace exists"

    run_test "Verify vcluster-a StatefulSet exists" \
        "kubectl get statefulset -n $VCLUSTER_A $VCLUSTER_A &>/dev/null" \
        "vcluster-a StatefulSet exists"

    run_test "Verify vcluster-a pods are running" \
        "kubectl get statefulset -n $VCLUSTER_A $VCLUSTER_A -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$'" \
        "vcluster-a is running"

    run_test "Check vcluster-a LoadBalancer IP" \
        "kubectl get svc -n $VCLUSTER_A $VCLUSTER_A -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '172.18.0.210'" \
        "vcluster-a has correct LoadBalancer IP"

    # VCluster B
    run_test "Check vcluster-b namespace exists" \
        "kubectl get namespace $VCLUSTER_B &>/dev/null" \
        "$VCLUSTER_B namespace exists"

    run_test "Verify vcluster-b StatefulSet exists" \
        "kubectl get statefulset -n $VCLUSTER_B $VCLUSTER_B &>/dev/null" \
        "vcluster-b StatefulSet exists"

    run_test "Verify vcluster-b pods are running" \
        "kubectl get statefulset -n $VCLUSTER_B $VCLUSTER_B -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$'" \
        "vcluster-b is running"

    run_test "Check vcluster-b LoadBalancer IP" \
        "kubectl get svc -n $VCLUSTER_B $VCLUSTER_B -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '172.18.0.211'" \
        "vcluster-b has correct LoadBalancer IP"

    # VCluster C
    run_test "Check vcluster-c namespace exists" \
        "kubectl get namespace $VCLUSTER_C &>/dev/null" \
        "$VCLUSTER_C namespace exists"

    run_test "Verify vcluster-c StatefulSet exists" \
        "kubectl get statefulset -n $VCLUSTER_C $VCLUSTER_C &>/dev/null" \
        "vcluster-c StatefulSet exists"

    run_test "Verify vcluster-c pods are running" \
        "kubectl get statefulset -n $VCLUSTER_C $VCLUSTER_C -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$'" \
        "vcluster-c is running"

    run_test "Check vcluster-c LoadBalancer IP" \
        "kubectl get svc -n $VCLUSTER_C $VCLUSTER_C -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '172.18.0.214'" \
        "vcluster-c has correct LoadBalancer IP"

    print_info "\nVCluster pods status:"
    kubectl get pods -n $VCLUSTER_A
    kubectl get pods -n $VCLUSTER_B
    kubectl get pods -n $VCLUSTER_C
}

# Test 5: Tenant Workloads
test_tenant_workloads() {
    print_header "Testing Tenant Workloads"

    # Tenant A
    run_test "Check tenant-a namespace exists" \
        "kubectl get namespace tenant-a &>/dev/null" \
        "tenant-a namespace exists"

    run_test "Check tenant-a HTTPRoute" \
        "kubectl get httproute -n tenant-a nginx &>/dev/null" \
        "tenant-a HTTPRoute exists"

    run_test "Verify tenant-a nginx service synced from vcluster" \
        "kubectl get svc -n vcluster-a nginx-x-default-x-vcluster-a &>/dev/null" \
        "tenant-a nginx service is synced to host cluster"

    # Tenant B
    run_test "Check tenant-b namespace exists" \
        "kubectl get namespace tenant-b &>/dev/null" \
        "tenant-b namespace exists"

    run_test "Check tenant-b HTTPRoute" \
        "kubectl get httproute -n tenant-b nginx &>/dev/null" \
        "tenant-b HTTPRoute exists"

    run_test "Verify tenant-b nginx service synced from vcluster" \
        "kubectl get svc -n vcluster-b nginx-x-default-x-vcluster-b &>/dev/null" \
        "tenant-b nginx service is synced to host cluster"

    # Tenant C
    run_test "Check tenant-c namespace exists" \
        "kubectl get namespace tenant-c &>/dev/null" \
        "tenant-c namespace exists"

    run_test "Check tenant-c HTTPRoute" \
        "kubectl get httproute -n tenant-c nginx &>/dev/null" \
        "tenant-c HTTPRoute exists"

    run_test "Verify tenant-c nginx service synced from vcluster" \
        "kubectl get svc -n vcluster-c nginx-x-default-x-vcluster-c &>/dev/null" \
        "tenant-c nginx service is synced to host cluster"

    print_info "\nTenant HTTPRoutes status:"
    kubectl get httproutes -n tenant-a
    kubectl get httproutes -n tenant-b
    kubectl get httproutes -n tenant-c

    print_info "\nSynced services from vclusters:"
    kubectl get svc -n vcluster-a | grep nginx || echo "No nginx service found in vcluster-a"
    kubectl get svc -n vcluster-b | grep nginx || echo "No nginx service found in vcluster-b"
    kubectl get svc -n vcluster-c | grep nginx || echo "No nginx service found in vcluster-c"
}

# Test 6: HTTP Routes (End-to-End)
test_http_routes() {
    print_header "Testing HTTP Routes (End-to-End)"

    # Get Traefik LoadBalancer IP for direct testing (no /etc/hosts dependency)
    local TRAEFIK_IP
    TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

    if [ -z "$TRAEFIK_IP" ]; then
        print_failure "Cannot determine Traefik LoadBalancer IP - skipping HTTP tests"
        ((TOTAL_TESTS++))
        ((FAILED_TESTS++))
        return 0
    fi

    print_info "Using Traefik LoadBalancer IP: $TRAEFIK_IP"

    # curl flags: --resolve avoids /etc/hosts, -L follows HTTP->HTTPS redirect, -k accepts self-signed certs
    local CURL_OPTS="--max-time 10 --connect-timeout 5 --resolve tenant-a.traefik.local:80:$TRAEFIK_IP --resolve tenant-a.traefik.local:443:$TRAEFIK_IP --resolve tenant-b.traefik.local:80:$TRAEFIK_IP --resolve tenant-b.traefik.local:443:$TRAEFIK_IP --resolve tenant-c.traefik.local:80:$TRAEFIK_IP --resolve tenant-c.traefik.local:443:$TRAEFIK_IP --resolve traefik.local:80:$TRAEFIK_IP --resolve traefik.local:443:$TRAEFIK_IP -L -k"

    # Test Traefik endpoint
    run_test "Test Traefik endpoint accessibility" \
        "curl -s -o /dev/null -w '%{http_code}' $CURL_OPTS http://traefik.local 2>/dev/null | grep -qE '^(200|404|301|302)$'" \
        "Traefik is accessible"

    # Test Tenant A
    run_test "Test Tenant A nginx via HTTP" \
        "curl -s -o /dev/null -w '%{http_code}' $CURL_OPTS http://tenant-a.traefik.local 2>/dev/null | grep -q '^200$'" \
        "Tenant A nginx is accessible and responding with 200"

    run_test "Verify Tenant A response content" \
        "curl -s $CURL_OPTS http://tenant-a.traefik.local 2>/dev/null | grep -q 'Welcome to nginx'" \
        "Tenant A nginx returns correct content"

    # Test Tenant B
    run_test "Test Tenant B nginx via HTTP" \
        "curl -s -o /dev/null -w '%{http_code}' $CURL_OPTS http://tenant-b.traefik.local 2>/dev/null | grep -q '^200$'" \
        "Tenant B nginx is accessible and responding with 200"

    run_test "Verify Tenant B response content" \
        "curl -s $CURL_OPTS http://tenant-b.traefik.local 2>/dev/null | grep -q 'Welcome to nginx'" \
        "Tenant B nginx returns correct content"

    # Test Tenant C
    run_test "Test Tenant C nginx via HTTP" \
        "curl -s -o /dev/null -w '%{http_code}' $CURL_OPTS http://tenant-c.traefik.local 2>/dev/null | grep -q '^200$'" \
        "Tenant C nginx is accessible and responding with 200"

    run_test "Verify Tenant C response content" \
        "curl -s $CURL_OPTS http://tenant-c.traefik.local 2>/dev/null | grep -q 'Welcome to nginx'" \
        "Tenant C nginx returns correct content"

    # Show full responses for manual inspection
    print_info "\nTenant A response:"
    curl -s $CURL_OPTS http://tenant-a.traefik.local 2>/dev/null | head -10 || echo "Failed to fetch"

    print_info "\nTenant B response:"
    curl -s $CURL_OPTS http://tenant-b.traefik.local 2>/dev/null | head -10 || echo "Failed to fetch"

    print_info "\nTenant C response:"
    curl -s $CURL_OPTS http://tenant-c.traefik.local 2>/dev/null | head -10 || echo "Failed to fetch"
}

# Test 7: Network Isolation
test_network_isolation() {
    print_header "Testing Network Isolation (NetworkPolicies)"

    # Discover all vcluster namespaces dynamically
    local VCLUSTER_NAMESPACES
    VCLUSTER_NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep '^vcluster-' | sort)

    if [ -z "$VCLUSTER_NAMESPACES" ]; then
        print_failure "No vcluster namespaces found - skipping network isolation tests"
        ((TOTAL_TESTS++))
        ((FAILED_TESTS++))
        return 0
    fi

    # Test: NetworkPolicies exist in each vcluster namespace
    for ns in $VCLUSTER_NAMESPACES; do
        run_test "Check NetworkPolicies exist in $ns" \
            "kubectl get networkpolicy -n $ns deny-all-ingress &>/dev/null" \
            "deny-all-ingress policy exists"

        run_test "Check allow-same-namespace policy in $ns" \
            "kubectl get networkpolicy -n $ns allow-same-namespace &>/dev/null" \
            "allow-same-namespace policy exists"

        run_test "Check allow-traefik-ingress policy in $ns" \
            "kubectl get networkpolicy -n $ns allow-traefik-ingress &>/dev/null" \
            "allow-traefik-ingress policy exists"

        run_test "Check allow-flux-to-vcluster-api policy in $ns" \
            "kubectl get networkpolicy -n $ns allow-flux-to-vcluster-api &>/dev/null" \
            "allow-flux-to-vcluster-api policy exists"

        run_test "Check allow-external-vcluster-api policy in $ns" \
            "kubectl get networkpolicy -n $ns allow-external-vcluster-api &>/dev/null" \
            "allow-external-vcluster-api policy exists"
    done

    # Test: Cross-vcluster isolation (should be blocked)
    # Pick first two vcluster namespaces for cross-namespace tests
    local NS_ARRAY=($VCLUSTER_NAMESPACES)
    if [ ${#NS_ARRAY[@]} -lt 2 ]; then
        print_info "Only one vcluster namespace found - skipping cross-vcluster isolation tests"
        return 0
    fi

    local SRC_NS="${NS_ARRAY[0]}"
    local DST_NS="${NS_ARRAY[1]}"

    # Get the target nginx pod IP in the destination namespace
    local DST_NGINX_IP
    DST_NGINX_IP=$(kubectl get pod -n "$DST_NS" -l app=nginx -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

    if [ -z "$DST_NGINX_IP" ]; then
        print_info "No nginx pod found in $DST_NS - skipping cross-vcluster isolation test"
    else
        print_test "Cross-vcluster isolation: $SRC_NS -> $DST_NS nginx ($DST_NGINX_IP) should be BLOCKED"
        # Run a busybox pod that tries to wget the target - should timeout
        if kubectl run test-isolation --rm -i --restart=Never --image=busybox -n "$SRC_NS" \
            --timeout=15s -- wget -qO- --timeout=3 "http://${DST_NGINX_IP}:80" &>/dev/null 2>&1; then
            # If wget succeeds, isolation is broken
            print_failure "Cross-vcluster isolation: $SRC_NS -> $DST_NS - traffic was NOT blocked"
        else
            print_success "Cross-vcluster isolation: $SRC_NS -> $DST_NS - traffic blocked"
        fi
    fi

    # Test reverse direction
    local REV_NGINX_IP
    REV_NGINX_IP=$(kubectl get pod -n "$SRC_NS" -l app=nginx -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

    if [ -z "$REV_NGINX_IP" ]; then
        print_info "No nginx pod found in $SRC_NS - skipping reverse isolation test"
    else
        print_test "Cross-vcluster isolation: $DST_NS -> $SRC_NS nginx ($REV_NGINX_IP) should be BLOCKED"
        if kubectl run test-isolation --rm -i --restart=Never --image=busybox -n "$DST_NS" \
            --timeout=15s -- wget -qO- --timeout=3 "http://${REV_NGINX_IP}:80" &>/dev/null 2>&1; then
            print_failure "Cross-vcluster isolation: $DST_NS -> $SRC_NS - traffic was NOT blocked"
        else
            print_success "Cross-vcluster isolation: $DST_NS -> $SRC_NS - traffic blocked"
        fi
    fi

    # Test: Same-namespace communication (should work)
    local SAME_NS_NGINX_IP
    SAME_NS_NGINX_IP=$(kubectl get pod -n "$SRC_NS" -l app=nginx -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

    if [ -z "$SAME_NS_NGINX_IP" ]; then
        print_info "No nginx pod found in $SRC_NS - skipping same-namespace test"
    else
        print_test "Same-namespace communication: $SRC_NS pod -> $SRC_NS nginx should be ALLOWED"
        if kubectl run test-same-ns --rm -i --restart=Never --image=busybox -n "$SRC_NS" \
            --timeout=15s -- wget -qO- --timeout=5 "http://${SAME_NS_NGINX_IP}:80" &>/dev/null 2>&1; then
            print_success "Same-namespace communication: $SRC_NS - traffic allowed"
        else
            print_failure "Same-namespace communication: $SRC_NS - traffic was blocked (should be allowed)"
        fi
    fi

    # Test: External vcluster API access (should work)
    for ns in $VCLUSTER_NAMESPACES; do
        local VC_IP
        VC_IP=$(kubectl get svc -n "$ns" "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$VC_IP" ]; then
            run_test "External vcluster API access: $ns ($VC_IP:443)" \
                "curl -sk --max-time 5 https://${VC_IP}:443/healthz 2>/dev/null | grep -q 'ok'" \
                "vcluster API is accessible"
        fi
    done

    print_info "\nNetworkPolicies per namespace:"
    for ns in $VCLUSTER_NAMESPACES; do
        echo "--- $ns ---"
        kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null
    done
}

# Test 8: Resource Status Summary
test_resource_summary() {
    print_header "Resource Status Summary"

    print_info "All namespaces:"
    kubectl get namespaces

    print_info "\nAll HelmReleases:"
    kubectl get helmreleases -A

    print_info "\nAll Kustomizations:"
    kubectl get kustomizations -A

    print_info "\nAll HTTPRoutes:"
    kubectl get httproutes -A

    print_info "\nAll Gateways:"
    kubectl get gateways -A
}

# Main execution
main() {
    print_header "Starting End-to-End Tests for kind-vcluster-flux-poc"

    # Switch to host cluster context
    kubectl config use-context kind-$CLUSTER_NAME &>/dev/null || {
        echo -e "${RED}ERROR: Cannot switch to kind-$CLUSTER_NAME context${NC}"
        exit 1
    }

    # Run all tests
    test_host_cluster
    test_flux
    test_infrastructure
    test_vclusters
    test_tenant_workloads
    test_http_routes
    test_network_isolation
    test_resource_summary

    # Print summary
    print_header "Test Summary"
    echo -e "Total Tests:  ${BLUE}$TOTAL_TESTS${NC}"
    echo -e "Passed:       ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed:       ${RED}$FAILED_TESTS${NC}"

    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "\n${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}✗ Some tests failed!${NC}"
        exit 1
    fi
}

# Run main function
main
