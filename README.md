# HKS Node Image Preparation

Hypervisor Kubernetes Service (HKS) nodes (control-plane + workers) boot from prebuilt VM images. This doc describes how to bake those images.

**Scope:** K8s cluster nodes only. Master + Slave + DB + VPN + LB images are different lineages (not covered here).

**Image base:** Any of the following:
- Ubuntu 22.04 LTS+ (recommended for new fleets)
- Debian 12 / Debian 13
- RHEL 9+ / CentOS Stream 9+ / Rocky Linux 9+ / AlmaLinux 9+
- Fedora 39+

All ship the same upstream `kubeadm` packages from `pkgs.k8s.io`; pick whichever your fleet already uses. The build script auto-detects family via `/etc/os-release` and branches on `apt` vs `dnf`.

**One image per K8s minor version.** Currently supported: `1.34`, `1.35`, `1.36`. Patch version (`.0`, `.1`, `.2`...) baked at build time; declare in `KubernetesSupportedVersion` admin row.

---

## What goes in the image

### Required (cluster-bootstrap)

- `containerd` (matching K8s version's compatibility window — see [k8s.io/releases/version-skew-policy](https://kubernetes.io/releases/version-skew-policy/))
- `kubeadm`, `kubelet`, `kubectl` (pinned to target patch version)
- `kubernetes-cni`
- `runc`
- Linux kernel modules pre-loaded: `overlay`, `br_netfilter`
- sysctl tweaks: `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-ip6tables=1`
- swap disabled + masked
- `cloud-init` (NoCloud + ConfigDrive datasources enabled)
- `qemu-guest-agent`
- `openssh-server` (port 22 by default; bootstrap script may rebind)

### Required (Hypervisor.io integration)

- `/etc/hypervisor.io/` empty dir (cloud-init populates `cluster-id`, `node-role`, `version` metadata files)
- CCM runs as a Pod from the image pulled in step 5 — no host-side binary needed

### Required (utilities cluster lifecycle uses)

- `jq`, `yq`
- `curl`, `wget`
- `openssl`, `ca-certificates`
- `gnupg2` (key import for package repos)
- Debian/Ubuntu only: `lsb-release`, `apt-transport-https` (kubeadm apt repo bootstrap)
- `iptables` / `iptables-nft` + `nftables` (kube-proxy iptables mode needs these)
- `socat`, `ipset` (kubeadm preflight requirements)
- `conntrack` (Debian) / `conntrack-tools` (RHEL) — same upstream binary, different package name
- `ebtables` — separate package on Debian; folded into `nftables` on RHEL 9+

### Pre-pulled containerd images (offline-safe deploy)

Populate via `ctr images pull` or `crictl pull` BEFORE first boot. Lets clusters bootstrap on hypervisors without internet:

- `registry.k8s.io/kube-apiserver:v<VERSION>`
- `registry.k8s.io/kube-controller-manager:v<VERSION>`
- `registry.k8s.io/kube-scheduler:v<VERSION>`
- `registry.k8s.io/kube-proxy:v<VERSION>`
- `registry.k8s.io/etcd:<ETCD_VERSION>` (CP image only)
- `registry.k8s.io/coredns/coredns:<COREDNS_VERSION>`
- `registry.k8s.io/pause:3.10`
- `quay.io/cilium/cilium:v<CILIUM_VERSION>` (CNI default — swap to Calico/Flannel as needed)
- `quay.io/cilium/operator-generic:v<CILIUM_VERSION>`
- `registry.k8s.io/metrics-server/metrics-server:v<METRICS_VERSION>`
- `<your-registry>/cluster-autoscaler-hypervisor:<CA_VERSION>` (built locally via cluster-autoscaler-hypervisor repo — pulled into worker image; autoscaler runs as Deployment in cluster)
- `<your-registry>/cloud-controller-manager-hypervisor:<CCM_VERSION>` (built locally via cloud-controller-manager-hypervisor repo; CP image only — CCM runs as Pod, no host binary needed)

Use `kubeadm config images list --kubernetes-version v<VERSION>` to get the exact reference list for a given K8s minor — paste into the script's `K8S_IMAGES` array.

### NOT in the image

- Cluster-specific certificates (kubeadm generates per cluster)
- kubeconfigs (master delivers via cloud-init)
- CNI manifest YAMLs (master applies post-init via kubectl apply)
- Tenant CCM credentials (per-cluster JWT; cloud-init writes secret)
- Cluster name / VPC config / pod CIDR / service CIDR (cloud-init seeds these)
- Slave agent or its certs (these belong on hypervisor host, not inside the K8s VM)

---

## Image type split: CP vs Worker

Two images per version is recommended (CKS pattern):

| Component | CP image | Worker image |
|---|---|---|
| etcd container preloaded | yes | no |
| kube-apiserver / scheduler / controller-manager preloaded | yes | no |
| cluster-autoscaler binary | no | yes (worker can self-host autoscaler if HPA fronts it) |
| Disk size | 20 GB | 40 GB (workload images expand here) |
| Tag | `hks-cp-<ver>` | `hks-worker-<ver>` |

If size matters less than image-management overhead, ship one combined `hks-node-<ver>` image — kubeadm preflights don't fail on extra binaries. Combined image trades ~200 MB extra per worker for half the build/maintain cost.

---

## OS prerequisites by family

The build script handles everything automatically once the base VM is up, but the starting cloud image needs to be in a reasonable state. Common per-family quirks:

### Debian / Ubuntu

- Stock cloud images work as-is. No preconfiguration needed.
- The script installs `apt-transport-https` and `gnupg2` early in case they're absent.

### RHEL / CentOS Stream / Rocky / AlmaLinux / Fedora

The script automatically applies the following — listed here so you know what to expect:

- **SELinux** is set to `permissive` and `setenforce 0` is run. kubeadm preflight refuses to proceed with `SELINUX=enforcing` because kubelet container processes cannot relabel host paths under enforcing policy. `/etc/selinux/config` is rewritten so this survives reboot.
- **firewalld** is disabled (`systemctl disable --now firewalld`). kube-proxy manages its own iptables/nftables ruleset; firewalld racing against it produces broken NodePort / Service routing.
- **containerd** is installed from the **Docker CE repo** (`containerd.io` package), not the distro's own `containerd` package. The Docker CE build is the canonical upstream referenced by the kubeadm docs and matches the version cadence used on Debian/Ubuntu.
- **Kubernetes packages** come from `pkgs.k8s.io` via a `yum.repos.d/kubernetes.repo` file with `exclude=` set so a stray `dnf update` cannot accidentally bump kubeadm/kubelet/kubectl. The script uses `--disableexcludes=kubernetes` when installing.

If your base image already has SELinux disabled or firewalld masked, the script will no-op those steps gracefully (`|| true` on each).

Subscription-manager / RHEL entitlements: If using stock RHEL 9 (not CentOS/Rocky/Alma), make sure the VM has the **BaseOS** and **AppStream** repos enabled before running the script. CentOS Stream / Rocky / AlmaLinux / Fedora need no entitlement setup.

---

## Build script — all supported OSes

Run **inside** a fresh VM (cloud image). The script is idempotent.

Script lives at `scripts/bake.sh`. Invoke:

```bash
# Inside the VM, as root:
chmod +x scripts/bake.sh

# Worker image, K8s 1.34
./scripts/bake.sh --version 1.34.2 --role worker --cni cilium

# Control plane image, K8s 1.35
./scripts/bake.sh --version 1.35.0 --role cp --cni cilium

# Combined image (no separate cp/worker)
./scripts/bake.sh --version 1.36.0 --role combined
```

After script completes, shut VM down (`shutdown -h now`), snapshot the disk, register snapshot in your image catalog.

See `scripts/bake.sh` for the full script.

---

## Per-version pinning matrix

The script's `--version` argument selects the K8s release. Companion versions (etcd, coredns, pause, cilium, CA, metrics-server) are auto-resolved from `kubeadm config images list`. CNI version is independent — pin in script header.

| K8s version | Recommended kernel | Min memory CP | Min memory worker |
|---|---|---|---|
| 1.34 | 5.15+ | 2 GB | 2 GB |
| 1.35 | 5.15+ | 2 GB | 2 GB |
| 1.36 | 5.15+ | 2 GB | 2 GB |

(All current releases share the same minimums — bump if upstream changes.)

---

## Cloud-init contract

The image MUST honor cloud-init NoCloud datasource. Master delivers `user-data` + `meta-data` via the seed ISO attached to each VM. The image's cloud-init runs:

1. `runcmd:` block from master containing kubeadm init / kubeadm join command + tokens + cert hashes
2. `write_files:` block dropping `/etc/hypervisor.io/cluster.json` (cluster ID, role, CCM credentials)
3. systemd-units block enabling `kubelet`, `containerd`, `qemu-guest-agent`

Image MUST NOT auto-start kubelet on first boot (it'll fail without certs). Either:

- Disable `kubelet.service` at build time (`systemctl disable kubelet`); cloud-init re-enables after kubeadm runs, OR
- Mask `kubelet.service` and let kubeadm unmask + start

The script does the first.

---

## Verification (post-build, pre-snapshot)

Inside the VM after script completes:

```bash
# kubelet binary present + correct version
kubelet --version

# kubeadm binary present + correct version
kubeadm version

# containerd running
systemctl is-active containerd

# kubelet NOT running (must wait for cloud-init seed)
systemctl is-enabled kubelet  # → should report 'disabled'

# Modules loaded
lsmod | grep -E 'overlay|br_netfilter'

# Sysctls applied
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# Pre-pulled images present
crictl images | grep -E 'kube-apiserver|pause'

# Hypervisor CCM image cached locally (runs as Pod at runtime)
crictl images | grep cloud-controller-manager-hypervisor

# Hypervisor cluster-autoscaler image cached locally (runs as Deployment at runtime)
crictl images | grep cluster-autoscaler-hypervisor

# qemu-guest-agent active (master needs it for VM control)
systemctl is-active qemu-guest-agent

# cloud-init NoCloud + ConfigDrive datasources enabled
cat /etc/cloud/cloud.cfg.d/*.cfg | grep -i datasource
```

All checks should pass. If any fail, fix in the script — don't manually patch the snapshot.

---

## Updating a version

Image is immutable per `KubernetesSupportedVersion` row. To roll out a new patch (e.g. 1.34.2 → 1.34.3):

1. Re-run script with `--version 1.34.3`
2. Snapshot under new tag `hks-cp-1.34.3` / `hks-worker-1.34.3`
3. Insert new admin row pointing to new snapshot
4. Existing clusters DO NOT auto-upgrade — admin promotes via `kubernetes:cp-rolling-upgrade` and `kubernetes:workers-rolling-upgrade` artisans (Slice 7 + 7b)
5. Old version row stays available until last cluster on it migrates; mark `state='deprecated'` then `state='retired'`

---

## Future automation

Spec calls for Packer + Ansible (spec §8.1). Next step: convert this bash script into Packer template + Ansible role pair. Out of scope for v1 — manual VM run is acceptable until image catalog grows past ~10 entries.
