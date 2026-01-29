#!/bin/bash
#
# Prerequisites and Setup Check for kind-vcluster-flux-poc
# This script checks if all prerequisites are met and the cluster is set up
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_failure() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    local all_good=true

    # Check Docker
    if command -v docker &>/dev/null; then
        if docker ps &>/dev/null; then
            print_success "Docker is installed and running"
            docker version | head -3
        else
            print_failure "Docker is installed but not running or not accessible"
            print_info "Try: sudo systemctl start docker"
            all_good=false
        fi
    else
        print_failure "Docker is not installed"
        print_info "Install Docker: https://docs.docker.com/engine/install/"
        all_good=false
    fi

    # Check kubectl
    if command -v kubectl &>/dev/null; then
        print_success "kubectl is installed ($(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4))"
    else
        print_failure "kubectl is not installed"
        print_info "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        all_good=false
    fi

    # Check Go
    if command -v go &>/dev/null; then
        print_success "Go is installed ($(go version | awk '{print $3}'))"
    else
        print_warning "Go is not installed (required for building some tools)"
        print_info "Install Go: https://go.dev/doc/install"
    fi

    # Check curl
    if command -v curl &>/dev/null; then
        print_success "curl is installed"
    else
        print_failure "curl is not installed"
        all_good=false
    fi

    echo ""
    if [ "$all_good" = true ]; then
        return 0
    else
        return 1
    fi
}

# Check if cluster is running
check_cluster() {
    print_header "Checking Cluster Status"

    # Check for kind containers
    local kind_containers=$(docker ps --filter "name=host-cluster" --format "{{.Names}}" 2>/dev/null | wc -l)

    if [ "$kind_containers" -eq 0 ]; then
        print_failure "No kind cluster containers are running"
        print_info "The cluster has not been created yet"
        echo ""
        print_info "To create and deploy the cluster, run:"
        echo -e "  ${GREEN}make install${NC}"
        echo ""
        print_info "This will:"
        echo "  1. Configure /etc/hosts entries"
        echo "  2. Create the kind cluster"
        echo "  3. Bootstrap Flux GitOps"
        echo "  4. Deploy all infrastructure and tenant workloads"
        return 1
    else
        print_success "Kind cluster containers are running"
        docker ps --filter "name=host-cluster" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi

    # Check kubectl context
    if kubectl config get-contexts -o name | grep -q "kind-host-cluster"; then
        print_success "kubectl context 'kind-host-cluster' exists"
    else
        print_failure "kubectl context 'kind-host-cluster' does not exist"
        return 1
    fi

    # Check cluster connectivity
    if kubectl cluster-info --context kind-host-cluster &>/dev/null; then
        print_success "Cluster is accessible via kubectl"
        echo ""
        kubectl cluster-info --context kind-host-cluster
    else
        print_failure "Cannot connect to cluster"
        return 1
    fi

    return 0
}

# Check tools in bin directory
check_tools() {
    print_header "Checking Local Tools"

    local bin_dir="./bin"

    if [ -d "$bin_dir" ]; then
        print_success "bin directory exists"

        if [ -f "$bin_dir/kind" ]; then
            print_success "kind is available ($($bin_dir/kind version | head -1))"
        else
            print_warning "kind is not in bin directory"
        fi

        if [ -f "$bin_dir/flux" ]; then
            print_success "flux is available ($($bin_dir/flux version --client | head -1))"
        else
            print_warning "flux is not in bin directory"
        fi

        if [ -f "$bin_dir/vcluster" ]; then
            print_success "vcluster is available ($($bin_dir/vcluster --version))"
        else
            print_warning "vcluster is not in bin directory"
        fi
    else
        print_warning "bin directory does not exist"
        print_info "Tools will be downloaded when running 'make install'"
    fi
}

# Check /etc/hosts
check_hosts_file() {
    print_header "Checking /etc/hosts Configuration"

    local hosts_ok=true

    if grep -q "traefik.local" /etc/hosts; then
        print_success "traefik.local entry exists in /etc/hosts"
        grep "traefik.local" /etc/hosts
    else
        print_warning "traefik.local entry missing from /etc/hosts"
        print_info "Will be added during 'make install'"
        hosts_ok=false
    fi

    if grep -q "tenant-a.traefik.local" /etc/hosts; then
        print_success "tenant-a.traefik.local entry exists in /etc/hosts"
    else
        print_warning "tenant-a.traefik.local entry missing from /etc/hosts"
        hosts_ok=false
    fi

    if grep -q "tenant-b.traefik.local" /etc/hosts; then
        print_success "tenant-b.traefik.local entry exists in /etc/hosts"
    else
        print_warning "tenant-b.traefik.local entry missing from /etc/hosts"
        hosts_ok=false
    fi

    if grep -q "tenant-c.traefik.local" /etc/hosts; then
        print_success "tenant-c.traefik.local entry exists in /etc/hosts"
    else
        print_warning "tenant-c.traefik.local entry missing from /etc/hosts"
        hosts_ok=false
    fi

    if [ "$hosts_ok" = false ]; then
        echo ""
        print_info "To manually add /etc/hosts entries, run:"
        echo "  sudo ./hack/add_host.sh 172.18.0.200 traefik.local"
        echo "  sudo ./hack/add_host.sh 172.18.0.200 tenant-a.traefik.local"
        echo "  sudo ./hack/add_host.sh 172.18.0.200 tenant-b.traefik.local"
        echo "  sudo ./hack/add_host.sh 172.18.0.200 tenant-c.traefik.local"
    fi
}

# Quick status of deployed resources (if cluster is running)
check_deployment_status() {
    print_header "Checking Deployment Status"

    if ! kubectl config get-contexts -o name | grep -q "kind-host-cluster"; then
        print_info "Cluster not running, skipping deployment status check"
        return 0
    fi

    kubectl config use-context kind-host-cluster &>/dev/null

    # Check namespaces
    print_info "Namespaces:"
    kubectl get namespaces 2>/dev/null | grep -E "(flux-system|metallb|cert-manager|traefik|kube-prometheus-stack|vcluster-a|vcluster-b|vcluster-c|tenant-a|tenant-b|tenant-c)" || echo "  No expected namespaces found"

    # Check Flux
    if kubectl get namespace flux-system &>/dev/null; then
        print_info "\nFlux controllers:"
        kubectl get pods -n flux-system 2>/dev/null | tail -n +2 | awk '{print "  "$1" - "$3}'
    fi

    # Check VClusters
    if kubectl get namespace vcluster-a &>/dev/null; then
        print_info "\nVCluster status:"
        kubectl get statefulsets -n vcluster-a vcluster-a -o jsonpath='{.metadata.name}: {.status.readyReplicas}/{.status.replicas} ready' 2>/dev/null && echo ""
        kubectl get statefulsets -n vcluster-b vcluster-b -o jsonpath='{.metadata.name}: {.status.readyReplicas}/{.status.replicas} ready' 2>/dev/null && echo ""
        kubectl get statefulsets -n vcluster-c vcluster-c -o jsonpath='{.metadata.name}: {.status.readyReplicas}/{.status.replicas} ready' 2>/dev/null && echo ""
    fi

    # Check Tenants - workloads run inside vclusters, HTTPRoutes on host
    if kubectl get namespace tenant-a &>/dev/null; then
        print_info "\nTenant HTTPRoutes:"
        kubectl get httproutes -n tenant-a 2>/dev/null | tail -n +2 | awk '{print "  tenant-a/"$1" -> "$2}' || echo "  No HTTPRoutes in tenant-a"
        kubectl get httproutes -n tenant-b 2>/dev/null | tail -n +2 | awk '{print "  tenant-b/"$1" -> "$2}' || echo "  No HTTPRoutes in tenant-b"
        kubectl get httproutes -n tenant-c 2>/dev/null | tail -n +2 | awk '{print "  tenant-c/"$1" -> "$2}' || echo "  No HTTPRoutes in tenant-c"

        print_info "\nSynced services from vclusters:"
        kubectl get svc -n vcluster-a nginx-x-default-x-vcluster-a -o jsonpath='  vcluster-a/nginx: {.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null && echo "" || echo "  No nginx service synced from vcluster-a"
        kubectl get svc -n vcluster-b nginx-x-default-x-vcluster-b -o jsonpath='  vcluster-b/nginx: {.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null && echo "" || echo "  No nginx service synced from vcluster-b"
        kubectl get svc -n vcluster-c nginx-x-default-x-vcluster-c -o jsonpath='  vcluster-c/nginx: {.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null && echo "" || echo "  No nginx service synced from vcluster-c"

        print_info "\nWorkloads inside vclusters:"
        for vc in vcluster-a vcluster-b vcluster-c; do
            local vc_secret="vc-${vc}"
            if kubectl get secret -n "$vc" "$vc_secret" &>/dev/null; then
                local vc_ip
                vc_ip=$(kubectl get svc -n "$vc" "$vc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
                local vc_kubeconfig
                vc_kubeconfig=$(kubectl get secret -n "$vc" "$vc_secret" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d)
                if [ -n "$vc_kubeconfig" ] && [ -n "$vc_ip" ]; then
                    # Replace localhost with LoadBalancer IP
                    vc_kubeconfig=$(echo "$vc_kubeconfig" | sed "s|https://localhost:8443|https://${vc_ip}:443|g")
                    echo "$vc_kubeconfig" > /tmp/${vc}-kubeconfig.tmp
                    kubectl --kubeconfig /tmp/${vc}-kubeconfig.tmp --insecure-skip-tls-verify get deployments -n default nginx \
                        -o jsonpath="  ${vc}/default/nginx: {.status.availableReplicas}/{.status.replicas} ready" 2>/dev/null && echo "" \
                        || echo "  nginx not found in ${vc}"
                    rm -f /tmp/${vc}-kubeconfig.tmp
                else
                    echo "  ${vc}: kubeconfig or LoadBalancer IP not available"
                fi
            else
                echo "  ${vc} kubeconfig secret not found"
            fi
        done
    fi
}

# Main
main() {
    print_header "kind-vcluster-flux-poc Setup Check"

    cd "$(dirname "$0")/.." || exit 1

    local status=0

    check_prerequisites || status=1
    check_tools
    check_hosts_file

    if check_cluster; then
        check_deployment_status
    fi

    echo ""
    print_header "Summary"

    if [ $status -eq 0 ]; then
        local kind_running
        kind_running=$(docker ps --filter "name=host-cluster" --format "{{.Names}}" 2>/dev/null | grep -c "host-cluster")
        if [ "$kind_running" -gt 0 ]; then
            print_success "Cluster is running and ready for testing"
            echo ""
            print_info "Run end-to-end tests with:"
            echo -e "  ${GREEN}./tests/e2e-test.sh${NC}"
        else
            print_info "Prerequisites are met, but cluster is not deployed"
            echo ""
            print_info "Deploy the cluster with:"
            echo -e "  ${GREEN}export GITHUB_TOKEN=<your-token>${NC}"
            echo -e "  ${GREEN}make install${NC}"
        fi
    else
        print_warning "Some prerequisites are missing"
        print_info "Fix the issues above before proceeding"
    fi

    exit $status
}

main
