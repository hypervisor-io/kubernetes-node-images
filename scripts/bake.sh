#!/usr/bin/env bash
#
# bake.sh
#
# Bake an HKS K8s node image. Supported base OSes:
#   - Debian 12, Debian 13
#   - Ubuntu 22.04 LTS+
#   - RHEL 9+, CentOS Stream 9+, Rocky Linux 9+, AlmaLinux 9+, Fedora 39+
#
# Run inside a fresh VM. After completion, shut down + snapshot the disk.
#
# Usage:
#   ./bake.sh --version <K8S_VERSION> --role <cp|worker|combined> [--cni cilium|calico|flannel]
#
# Examples:
#   ./bake.sh --version 1.34.2 --role worker --cni cilium
#   ./bake.sh --version 1.35.0 --role cp     --cni cilium
#   ./bake.sh --version 1.36.0 --role combined
#
# Requires: root, internet (for package install + image pull), ~6 GB free disk.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

K8S_VERSION=""
ROLE="combined"
CNI="cilium"
CCM_REGISTRY="${CCM_REGISTRY:-ghcr.io/hypervisor-io}"        # override via env
CCM_IMAGE_NAME="${CCM_IMAGE_NAME:-cloud-controller-manager}" # override via env (for forks)
CCM_VERSION="${CCM_VERSION:-latest}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  K8S_VERSION="$2"; shift 2;;
    --role)     ROLE="$2"; shift 2;;
    --cni)      CNI="$2"; shift 2;;
    -h|--help)  grep -E '^# ' "$0" | sed 's/^# //'; exit 0;;
    *)          echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

[[ -z "$K8S_VERSION" ]] && { echo "ERROR: --version required (e.g. 1.34.2)" >&2; exit 1; }
[[ ! "$ROLE" =~ ^(cp|worker|combined)$ ]] && { echo "ERROR: --role must be cp|worker|combined" >&2; exit 1; }
[[ ! "$CNI" =~ ^(cilium|calico|flannel)$ ]] && { echo "ERROR: --cni must be cilium|calico|flannel" >&2; exit 1; }

K8S_MINOR="$(echo "$K8S_VERSION" | awk -F. '{print $1"."$2}')"   # e.g. 1.34.2 -> 1.34

# ---------------------------------------------------------------------------
# Pinned companion versions (update per K8s minor as needed)
# ---------------------------------------------------------------------------

# These three are CNI-independent. Verify with: kubeadm config images list --kubernetes-version vX.Y.Z
declare -A ETCD_FOR; ETCD_FOR[1.34]="3.5.15-0"; ETCD_FOR[1.35]="3.6.6-0"; ETCD_FOR[1.36]="3.6.6-0"
declare -A COREDNS_FOR; COREDNS_FOR[1.34]="v1.11.3"; COREDNS_FOR[1.35]="v1.13.1"; COREDNS_FOR[1.36]="v1.13.1"
declare -A PAUSE_FOR; PAUSE_FOR[1.34]="3.10"; PAUSE_FOR[1.35]="3.10.1"; PAUSE_FOR[1.36]="3.10.1"
PAUSE_VERSION="${PAUSE_FOR[$K8S_MINOR]:-3.10}"

# CNI-side
CILIUM_VERSION="v1.16.5"
CALICO_VERSION="v3.28.2"
FLANNEL_VERSION="v0.26.1"

# Add-ons
METRICS_SERVER_VERSION="v0.7.2"

ETCD_VERSION="${ETCD_FOR[$K8S_MINOR]:-}"
COREDNS_VERSION="${COREDNS_FOR[$K8S_MINOR]:-}"
[[ -z "$ETCD_VERSION" ]] && { echo "ERROR: no etcd pin for K8s $K8S_MINOR — update ETCD_FOR" >&2; exit 1; }
[[ -z "$COREDNS_VERSION" ]] && { echo "ERROR: no coredns pin for K8s $K8S_MINOR — update COREDNS_FOR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# OS detection + cross-distro package wrappers
# ---------------------------------------------------------------------------

. /etc/os-release
case "$ID" in
  debian)
    PKG_MANAGER="apt"
    OS_FAMILY="debian"
    echo "==> OS: Debian $VERSION_ID ($VERSION_CODENAME)"
    ;;
  ubuntu)
    PKG_MANAGER="apt"
    OS_FAMILY="debian"
    echo "==> OS: Ubuntu $VERSION_ID ($VERSION_CODENAME)"
    ;;
  rhel|centos)
    PKG_MANAGER="dnf"
    OS_FAMILY="rhel"
    command -v dnf >/dev/null 2>&1 || PKG_MANAGER="yum"
    echo "==> OS: $PRETTY_NAME"
    ;;
  rocky|almalinux)
    PKG_MANAGER="dnf"
    OS_FAMILY="rhel"
    command -v dnf >/dev/null 2>&1 || PKG_MANAGER="yum"
    echo "==> OS: $PRETTY_NAME (RHEL-compatible)"
    ;;
  fedora)
    PKG_MANAGER="dnf"
    OS_FAMILY="rhel"
    echo "==> OS: Fedora $VERSION_ID"
    ;;
  *)
    echo "ERROR: unsupported OS '$ID'. Use Debian 12+/Ubuntu 22.04+/RHEL 9+/CentOS 9+/Fedora 39+." >&2
    exit 1
    ;;
esac

# Cross-distro package wrappers.
# pkg_install <pkg...>     : install packages, non-interactive, no recommends on Debian.
# pkg_update               : refresh package metadata.
# pkg_clean                : autoremove + clean cache (call before snapshot).
pkg_install() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends "$@"
  else
    $PKG_MANAGER install -y "$@"
  fi
}

pkg_update() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
  else
    $PKG_MANAGER makecache -y
  fi
}

pkg_clean() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get autoremove -y
    apt-get clean
  else
    $PKG_MANAGER autoremove -y
    $PKG_MANAGER clean all
  fi
}

echo "==> K8s: $K8S_VERSION (minor: $K8S_MINOR)"
echo "==> Role: $ROLE"
echo "==> CNI: $CNI"
echo "==> etcd: $ETCD_VERSION"
echo "==> coredns: $COREDNS_VERSION"

# ---------------------------------------------------------------------------
# 1. System prep
# ---------------------------------------------------------------------------

echo "==> [1/8] package metadata refresh + base utilities"
pkg_update

# Base packages — names differ between families.
if [ "$OS_FAMILY" = "debian" ]; then
  pkg_install \
    ca-certificates curl wget gnupg2 lsb-release apt-transport-https \
    jq socat conntrack ebtables ipset \
    iptables \
    qemu-guest-agent openssh-server cloud-init \
    openssl
else
  # RHEL family: gnupg2 → gnupg2; conntrack → conntrack-tools; iptables-nft is the modern shim.
  # ebtables ships in nftables on RHEL 9+. apt-transport-https / lsb-release are apt-only.
  pkg_install \
    ca-certificates curl wget gnupg2 \
    jq socat conntrack-tools ipset \
    iptables-nft nftables \
    qemu-guest-agent openssh-server cloud-init \
    openssl
fi

# RHEL family: SELinux + firewalld interfere with kube-proxy and kubelet.
# kubeadm preflight refuses to proceed with SELinux=enforcing.
if [ "$OS_FAMILY" = "rhel" ]; then
  echo "==> Disabling SELinux (kubeadm requirement)"
  setenforce 0 2>/dev/null || true
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  fi

  echo "==> Disabling firewalld (K8s manages its own iptables/nftables rules)"
  systemctl disable --now firewalld 2>/dev/null || true
fi

# yq from binary (distro packages lag upstream).
if ! command -v yq >/dev/null 2>&1; then
  YQ_VER="v4.44.3"
  if [ "$OS_FAMILY" = "debian" ]; then
    ARCH="$(dpkg --print-architecture)"
  else
    case "$(uname -m)" in
      x86_64)  ARCH="amd64";;
      aarch64) ARCH="arm64";;
      *)       ARCH="$(uname -m)";;
    esac
  fi
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_${ARCH}" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
fi

# Helm — used by control-plane-init.sh to install Cilium.
# Use the official get-helm-3 installer script (distro-neutral) instead of per-family repos.
if ! command -v helm >/dev/null 2>&1; then
  if [ "$OS_FAMILY" = "debian" ]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /etc/apt/keyrings/helm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
      > /etc/apt/sources.list.d/helm-stable-debian.list
    pkg_update
    pkg_install helm
  else
    # RHEL family: install from upstream tarball (Baltimore CDN apt repo is Debian-only).
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
fi

# ---------------------------------------------------------------------------
# 2. Disable swap, load kernel modules, set sysctls
# ---------------------------------------------------------------------------

echo "==> [2/8] disable swap + kernel modules + sysctl"

swapoff -a
sed -ri 's/^([^#].*\sswap\s)/#\1/' /etc/fstab
systemctl mask "$(systemctl list-units --type=swap --no-legend --all | awk '{print $1}' | head -n1)" 2>/dev/null || true

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
# modprobe + sysctl --system fail inside virt-customize chroot (host kernel mismatch).
# modules-load.d + sysctl.d apply at first boot regardless — runtime load is best-effort.
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
sysctl --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. containerd
# ---------------------------------------------------------------------------

echo "==> [3/8] containerd"

if [ "$OS_FAMILY" = "debian" ]; then
  pkg_install containerd
else
  # RHEL family: containerd is in the Docker CE repo, packaged as containerd.io.
  # Fedora also has containerd in main repos but containerd.io from Docker is the
  # canonical upstream package and matches what kubeadm docs reference.
  if ! command -v containerd >/dev/null 2>&1; then
    # dnf-plugins-core provides 'dnf config-manager' on RHEL/CentOS/Rocky/Alma.
    pkg_install dnf-plugins-core || true
    if [ "$ID" = "fedora" ]; then
      $PKG_MANAGER config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
        || $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
      $PKG_MANAGER config-manager addrepo --from-repofile=https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
        || $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    pkg_install containerd.io
  fi
fi

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -ri 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:'"$PAUSE_VERSION"'"|' /etc/containerd/config.toml

systemctl daemon-reload 2>/dev/null || true
systemctl enable containerd
systemctl start containerd 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. kubeadm + kubelet + kubectl
# ---------------------------------------------------------------------------

echo "==> [4/8] kubeadm/kubelet/kubectl ($K8S_VERSION)"

if [ "$OS_FAMILY" = "debian" ]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  pkg_update

  # Pin to exact patch version (Debian-family epoch suffix).
  APT_K8S_VER="${K8S_VERSION}-1.1"
  pkg_install \
    kubeadm="$APT_K8S_VER" \
    kubelet="$APT_K8S_VER" \
    kubectl="$APT_K8S_VER"
  apt-mark hold kubeadm kubelet kubectl
else
  # RHEL family: pkgs.k8s.io rpm repo. exclude= prevents accidental upgrades via
  # `dnf update`; we override with --disableexcludes=kubernetes for installs.
  cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  pkg_update

  # Pin to exact patch version (RHEL-family release suffix).
  RPM_K8S_VER="${K8S_VERSION}-150500.1.1"
  # Fall back to plain version if the suffixed package isn't available — pkgs.k8s.io
  # release numbering has shifted across K8s minors. dnf will pick the latest matching.
  $PKG_MANAGER install -y --disableexcludes=kubernetes \
    "kubeadm-${K8S_VERSION}" \
    "kubelet-${K8S_VERSION}" \
    "kubectl-${K8S_VERSION}" \
    || $PKG_MANAGER install -y --disableexcludes=kubernetes \
      "kubeadm-${RPM_K8S_VER}" \
      "kubelet-${RPM_K8S_VER}" \
      "kubectl-${RPM_K8S_VER}"

  # dnf has no direct equivalent of apt-mark hold; the exclude= line in the repo
  # file prevents `dnf update` from bumping these. versionlock plugin can pin
  # further but is optional.
fi

# Disable kubelet — cloud-init re-enables after kubeadm runs
systemctl disable kubelet

# ---------------------------------------------------------------------------
# 5. Pre-pull container images (offline-safe deploy)
# ---------------------------------------------------------------------------

echo "==> [5/8] pre-pull containerd images"

# Core K8s control-plane images (CP image only; workers don't need apiserver/etcd)
PULL_CP=(
  "registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
  "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
  "registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
  "registry.k8s.io/etcd:${ETCD_VERSION}"
  "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
)

# Worker-side
PULL_WORKER=(
  "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
  "registry.k8s.io/pause:${PAUSE_VERSION}"
)

# CNI
PULL_CNI=()
case "$CNI" in
  cilium)
    PULL_CNI=(
      "quay.io/cilium/cilium:${CILIUM_VERSION}"
      "quay.io/cilium/operator-generic:${CILIUM_VERSION}"
    )
    ;;
  calico)
    PULL_CNI=(
      "docker.io/calico/cni:${CALICO_VERSION}"
      "docker.io/calico/node:${CALICO_VERSION}"
      "docker.io/calico/kube-controllers:${CALICO_VERSION}"
    )
    ;;
  flannel)
    PULL_CNI=(
      "docker.io/flannel/flannel:${FLANNEL_VERSION}"
      "docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel2"
    )
    ;;
esac

# Add-ons
PULL_ADDONS=(
  "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"
)

# Hypervisor.io CCM (built externally; pushed to your registry).
# CCM runs on every cluster, so baking it in saves first-boot pull time.
PULL_CCM=(
  "${CCM_REGISTRY}/${CCM_IMAGE_NAME}:${CCM_VERSION}"
)

# Cluster autoscaler is NOT baked. Image varies per K8s minor and is
# only deployed when worker autoscaling is enabled on a cluster. The
# panel records the image string in kubernetes_supported_versions.
# cluster_autoscaler_image; kubelet pulls on demand when the autoscaler
# manifest is applied.

PULL_LIST=()
case "$ROLE" in
  cp)        PULL_LIST=("${PULL_CP[@]}" "${PULL_WORKER[@]}" "${PULL_CNI[@]}" "${PULL_ADDONS[@]}" "${PULL_CCM[@]}");;
  worker)    PULL_LIST=("${PULL_WORKER[@]}" "${PULL_CNI[@]}");;
  combined)  PULL_LIST=("${PULL_CP[@]}" "${PULL_WORKER[@]}" "${PULL_CNI[@]}" "${PULL_ADDONS[@]}" "${PULL_CCM[@]}");;
esac

for img in "${PULL_LIST[@]}"; do
  echo "    pulling $img"
  ctr -n=k8s.io images pull "$img" || {
    echo "    WARN: failed to pull $img — skipping (verify connectivity / registry credentials)" >&2
  }
done

# ---------------------------------------------------------------------------
# 6. Hypervisor.io CCM marker dir
# ---------------------------------------------------------------------------
# CCM runs as a Pod (Deployment / static manifest) using the image pulled in
# step 5. There is no host-side CCM binary to install. We only ensure the
# marker dir exists for cluster-bootstrap config drops on first boot.

echo "==> [6/8] CCM marker dir"
mkdir -p /etc/hypervisor.io

# ---------------------------------------------------------------------------
# 7. Cloud-init datasources
# ---------------------------------------------------------------------------

echo "==> [7/8] cloud-init datasource config"

cat > /etc/cloud/cloud.cfg.d/99-hypervisor-io.cfg <<'EOF'
# HKS-specific cloud-init configuration
datasource_list: [ NoCloud, ConfigDrive, None ]
ssh_pwauth: false
disable_root: false
preserve_hostname: false
manage_etc_hosts: true
EOF

# ---------------------------------------------------------------------------
# 8. Cleanup before snapshot
# ---------------------------------------------------------------------------

echo "==> [8/8] cleanup"

pkg_clean
if [ "$OS_FAMILY" = "debian" ]; then
  rm -rf /var/lib/apt/lists/*
else
  rm -rf /var/cache/dnf/* /var/cache/yum/* 2>/dev/null || true
fi
rm -rf /tmp/* /var/tmp/* /root/.bash_history /root/.viminfo 2>/dev/null || true

# Reset machine-id so cloned VMs get unique IDs (cloud-init regenerates on first boot)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Clean cloud-init state so it runs fresh on first boot of clone
cloud-init clean --logs --seed 2>/dev/null || cloud-init clean --logs

# SSH host keys removed; cloud-init regenerates per-instance
rm -f /etc/ssh/ssh_host_*

# Tag image with bake metadata
cat > /etc/hypervisor.io/image-info <<EOF
k8s_version=$K8S_VERSION
k8s_minor=$K8S_MINOR
role=$ROLE
cni=$CNI
ccm_version=$CCM_VERSION
ccm_image=$CCM_REGISTRY/$CCM_IMAGE_NAME:$CCM_VERSION
etcd_version=$ETCD_VERSION
coredns_version=$COREDNS_VERSION
baked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
baked_on=$ID-$VERSION_ID
EOF

echo
echo "==> Build complete."
echo "==> Image tag: hks-${ROLE}-${K8S_VERSION}"
echo
echo "Next steps:"
echo "  1. Verify (see IMAGE_PREP.md verification section)"
echo "  2. shutdown -h now"
echo "  3. Snapshot the VM disk"
echo "  4. Register snapshot in admin: KubernetesSupportedVersion + image_id"
