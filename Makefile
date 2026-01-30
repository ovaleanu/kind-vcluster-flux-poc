# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: help

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

TRAEFIK_IP ?= 172.18.0.200
.PHONY: network
network: ## Configure network.
	@./hack/add_host.sh $(TRAEFIK_IP) traefik.local
	@./hack/add_host.sh $(TRAEFIK_IP) tenant-a.traefik.local
	@./hack/add_host.sh $(TRAEFIK_IP) tenant-b.traefik.local
	@./hack/add_host.sh $(TRAEFIK_IP) tenant-c.traefik.local

##@ Tenant Management

TENANT_NAME ?=
TENANT_IP ?=

.PHONY: add-tenant
add-tenant: ## Add a new tenant. Usage: make add-tenant TENANT_NAME=d TENANT_IP=172.18.0.215
	@if [ -z "$(TENANT_NAME)" ] || [ -z "$(TENANT_IP)" ]; then \
		echo "Usage: make add-tenant TENANT_NAME=<name> TENANT_IP=<ip>"; \
		echo "Example: make add-tenant TENANT_NAME=d TENANT_IP=172.18.0.215"; \
		exit 1; \
	fi
	./hack/add-tenant.sh $(TENANT_NAME) $(TENANT_IP)

.PHONY: remove-tenant
remove-tenant: ## Remove a tenant. Usage: make remove-tenant TENANT_NAME=d
	@if [ -z "$(TENANT_NAME)" ]; then \
		echo "Usage: make remove-tenant TENANT_NAME=<name>"; \
		exit 1; \
	fi
	./hack/remove-tenant.sh $(TENANT_NAME)

GITHUB_USER ?= ovaleanu
GITHUB_REPO ?= kind-vcluster-flux-poc
GITHUB_BRANCH ?= main
FLUX_INSTANCE ?= clusters/host-cluster/flux-instance.yaml
.PHONY: deploy
deploy: flux cluster-ctx ## Deploy Flux Operator and FluxInstance.
	@echo "Installing Flux Operator..."
	@helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--namespace flux-system --create-namespace --wait
	@echo "Creating Git credentials secret..."
	@kubectl create secret generic flux-system \
		--namespace=flux-system \
		--from-literal=username=git \
		--from-literal=password=$(GITHUB_TOKEN) \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying FluxInstance..."
	@export GITHUB_USER=$(GITHUB_USER) GITHUB_REPO=$(GITHUB_REPO) GITHUB_BRANCH=$(GITHUB_BRANCH) && \
		envsubst '$$GITHUB_USER $$GITHUB_REPO $$GITHUB_BRANCH' < $(FLUX_INSTANCE) | kubectl apply -f -
	@echo "Waiting for Flux controllers to be ready..."
	@kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m

VCLUSTER_A ?= vcluster-a
VCLUSTER_B ?= vcluster-b
VCLUSTER_C ?= vcluster-c

.PHONY: vctx
vctx: vcluster cluster-ctx ## Configure vcluster contexts.
	$(VCLUSTER) connect $(VCLUSTER_A) -n $(VCLUSTER_A)
	$(VCLUSTER) connect $(VCLUSTER_B) -n $(VCLUSTER_B)
	$(VCLUSTER) connect $(VCLUSTER_C) -n $(VCLUSTER_C)

.PHONY: vcluster-delete
vcluster-delete: vcluster cluster-ctx ## Delete vclusters.
	-$(VCLUSTER) delete $(VCLUSTER_A) -n $(VCLUSTER_A)
	-$(VCLUSTER) delete $(VCLUSTER_B) -n $(VCLUSTER_B)
	-$(VCLUSTER) delete $(VCLUSTER_C) -n $(VCLUSTER_C)

.PHONY: install
install: network cluster cilium-install deploy ## Install cluster and PoC.

.PHONY: uninstall
uninstall: cluster-delete ## Tear down cluster.

##@ Cluster

CLUSTER ?= host-cluster
KIND_CONFIG ?= hack/config/kind.yaml

.PHONY: cluster
cluster: kind ## Provision kind cluster.
	@if $(KIND) get clusters 2>/dev/null | grep -q "^$(CLUSTER)$$"; then \
		echo "Cluster '$(CLUSTER)' already exists, skipping creation..."; \
	else \
		echo "Creating cluster '$(CLUSTER)'..."; \
		$(KIND) create cluster --name $(CLUSTER) --config $(KIND_CONFIG); \
	fi

.PHONY: cluster-delete
cluster-delete: kind ## Delete kind cluster.
	$(KIND) delete cluster --name $(CLUSTER)

.PHONY: cluster-ctx
cluster-ctx: ## Set cluster context.
	@kubectl config use-context kind-$(CLUSTER)

.PHONY: cilium-install
cilium-install: cilium-cli cluster-ctx ## Pre-install Cilium CNI (nodes need CNI before Flux can bootstrap).
	@echo "Adding Cilium Helm repository..."
	@helm repo add cilium https://helm.cilium.io/ --force-update
	@echo "Installing Cilium $(CILIUM_VERSION)..."
	@helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--version $(CILIUM_VERSION) \
		--set ipam.mode=kubernetes \
		--set kubeProxyReplacement=false \
		--set image.pullPolicy=IfNotPresent \
		--set hubble.enabled=true \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--wait --timeout 5m
	@echo "Waiting for nodes to be ready..."
	@kubectl wait --for=condition=Ready nodes --all --timeout=5m

.PHONY: cluster-status
cluster-status: kind ## Check if cluster exists.
	@if $(KIND) get clusters 2>/dev/null | grep -q "^$(CLUSTER)$$"; then \
		echo "✓ Cluster '$(CLUSTER)' is running"; \
		$(KIND) get clusters | grep "$(CLUSTER)"; \
	else \
		echo "✗ Cluster '$(CLUSTER)' does not exist"; \
		exit 1; \
	fi

##@ Tooling

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KIND ?= $(LOCALBIN)/kind
FLUX ?= $(LOCALBIN)/flux
VCLUSTER ?= $(LOCALBIN)/vcluster
CILIUM_CLI ?= $(LOCALBIN)/cilium
HUBBLE ?= $(LOCALBIN)/hubble

## Tool Versions
KIND_VERSION ?= v0.31.0
FLUX_VERSION ?= 2.7.5
VCLUSTER_VERSION ?= v0.31.0
CILIUM_VERSION ?= 1.18.6
CILIUM_CLI_VERSION ?= v0.18.9
HUBBLE_VERSION ?= v1.18.5

.PHONY: kind
kind: $(KIND) ## Download kind locally if necessary.
$(KIND): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/kind@$(KIND_VERSION)

.PHONY: flux
flux: ## Download flux locally if necessary.
ifeq (,$(wildcard $(FLUX)))
ifeq (,$(shell which flux 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(FLUX)) ;\
	curl -sSLo - https://github.com/fluxcd/flux2/releases/download/v$(FLUX_VERSION)/flux_$(FLUX_VERSION)_linux_amd64.tar.gz| \
	tar xzf - -C bin/ ;\
	}
else
FLUX = $(shell which flux)
endif
endif

.PHONY: vcluster
vcluster: ## Download vcluster locally if necessary.
ifeq (,$(wildcard $(VCLUSTER)))
ifeq (,$(shell which vcluster 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(VCLUSTER)) ;\
	curl -sSLo $(VCLUSTER) https://github.com/loft-sh/vcluster/releases/download/$(VCLUSTER_VERSION)/vcluster-linux-amd64 ;\
	chmod +x $(VCLUSTER) ;\
	}
else
VCLUSTER = $(shell which vcluster)
endif
endif

.PHONY: cilium-cli
cilium-cli: ## Download cilium CLI locally if necessary.
ifeq (,$(wildcard $(CILIUM_CLI)))
ifeq (,$(shell which cilium 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(CILIUM_CLI)) ;\
	curl -sSLo - https://github.com/cilium/cilium-cli/releases/download/$(CILIUM_CLI_VERSION)/cilium-linux-amd64.tar.gz | \
	tar xzf - -C $(LOCALBIN) ;\
	}
else
CILIUM_CLI = $(shell which cilium)
endif
endif

.PHONY: hubble
hubble: ## Download hubble CLI locally if necessary.
ifeq (,$(wildcard $(HUBBLE)))
ifeq (,$(shell which hubble 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(HUBBLE)) ;\
	curl -sSLo - https://github.com/cilium/hubble/releases/download/$(HUBBLE_VERSION)/hubble-linux-amd64.tar.gz | \
	tar xzf - -C $(LOCALBIN) ;\
	}
else
HUBBLE = $(shell which hubble)
endif
endif
