## kind + vcluster + flux multi-tenancy PoC
[vcluster](https://www.vcluster.com/) + [flux](https://fluxcd.io/) multi-tenancy  PoC

vcluster - Create fully functional virtual Kubernetes clusters - Each vcluster runs inside a namespace of the underlying k8s cluster. It's cheaper than creating separate full-blown clusters and it offers better multi-tenancy and isolation than regular namespaces.

### Requirenments
- Linux laptop/workstation
- Docker installed
- Go installed

Go install mini-howto
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

Example Output:

$ make install
Adding "traefik.local" to /etc/hosts
[sudo] password for ovidi: 
Adding "tenant-a.traefik.local" to /etc/hosts
Adding "tenant-b.traefik.local" to /etc/hosts
mkdir -p /home/ovidi/working/kind-vcluster-flux-poc/bin
GOBIN=/home/ovidi/working/kind-vcluster-flux-poc/bin go install sigs.k8s.io/kind@v0.31.0
go: downloading sigs.k8s.io/kind v0.31.0
go: downloading github.com/mattn/go-isatty v0.0.20
go: downloading github.com/spf13/cobra v1.8.0
go: downloading al.essio.dev/pkg/shellescape v1.5.1
go: downloading github.com/spf13/pflag v1.0.5
go: downloading github.com/BurntSushi/toml v1.4.0
go: downloading github.com/evanphx/json-patch/v5 v5.6.0
go: downloading github.com/pelletier/go-toml v1.9.5
go: downloading go.yaml.in/yaml/v3 v3.0.4
go: downloading sigs.k8s.io/yaml v1.4.0
go: downloading github.com/pkg/errors v0.9.1
go: downloading golang.org/x/sys v0.6.0
/home/ovidi/working/kind-vcluster-flux-poc/bin/kind create cluster --name host-cluster --config hack/config/kind.yaml
Creating cluster "host-cluster" ...
 ✓ Ensuring node image (kindest/node:v1.34.0) 🖼 
 ✓ Preparing nodes 📦 📦 📦  
 ✓ Writing configuration 📜 
 ✓ Starting control-plane 🕹️ 
 ✓ Installing CNI 🔌 
 ✓ Installing StorageClass 💾 
 ✓ Joining worker nodes 🚜 
Set kubectl context to "kind-host-cluster"
You can now use your cluster with:

kubectl cluster-info --context kind-host-cluster

Have a nice day! 👋
Switched to context "kind-host-cluster".
/home/ovidi/working/kind-vcluster-flux-poc/bin/flux bootstrap github \
        --owner=ovaleanu \
        --repository=kind-vcluster-flux-poc \
        --private=false \
        --personal=true \
        --path=clusters/host-cluster
► connecting to github.com
✔ repository "https://github.com/ovaleanu/kind-vcluster-flux-poc" created
► cloning branch "main" from Git repository "https://github.com/ovaleanu/kind-vcluster-flux-poc.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("059b9049037e2e6483df629772ba69cc7c0a34cc")
► pushing component manifests to "https://github.com/ovaleanu/kind-vcluster-flux-poc.git"
► installing components in "flux-system" namespace
✔ installed components
✔ reconciled components
► determining if source secret "flux-system/flux-system" exists
► generating source secret
✔ public key: ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBGc4wHuy+ZCr2u4rjfEKjdbMY7kBuFyB/ChbltcQ8iFTDZ9ZW9ka48gnBZPjZyB0qkBDyyzH2rt1gFsPF103XbdAwM6LX+xjOHxkihDmK2OPiSuLyZlfX9WC1W4k8rgsrg==
✔ configured deploy key "flux-system-main-flux-system-./clusters/host-cluster" for "https://github.com/ovaleanu/kind-vcluster-flux-poc"
► applying source secret "flux-system/flux-system"
✔ reconciled source secret
► generating sync manifests
✔ generated sync manifests
✔ committed sync manifests to "main" ("89fcf221f0beebb8029d21cc00a55aa903f73471")
► pushing sync manifests to "https://github.com/ovaleanu/kind-vcluster-flux-poc.git"
► applying sync manifests
✔ reconciled sync configuration
◎ waiting for GitRepository "flux-system/flux-system" to be reconciled
✔ GitRepository reconciled successfully
◎ waiting for Kustomization "flux-system/flux-system" to be reconciled
✔ Kustomization reconciled successfully
► confirming components are healthy
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy


REF: https://github.com/loft-sh/vcluster

[Credits](https://github.com/mmontes11/vcluster-poc) 

