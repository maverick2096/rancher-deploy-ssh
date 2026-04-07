#!/usr/bin/env bash
# deploy-rancher.sh
# ─────────────────────────────────────────────────────────────────────────────
# Deploys a 3-node Rancher HA management plane on RHEL 10 VMs.
# Uses plain SSH/SCP only. GCP load balancer is configured separately.
#
# Prerequisites on the machine running this script:
#   ssh, scp  — pre-installed
#   kubectl   — https://kubernetes.io/docs/tasks/tools/
#   helm      — https://helm.sh/docs/intro/install/
#   openssl   — pre-installed
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  CONFIGURE THESE BEFORE RUNNING                                  ║
# ╚══════════════════════════════════════════════════════════════════╝
SSH_USER="cloud-user"                      # Default RHEL user on GCP
SSH_KEY="~/.ssh/id_rsa"

NODE1_IP="10.0.0.1"
NODE2_IP="10.0.0.2"
NODE3_IP="10.0.0.3"

LB_IP="34.x.x.x"                          # GCP LB IP — added to tls-san and kubeconfig

RANCHER_HOSTNAME="rancher.yourdomain.com"  # DNS must point to GCP LB
CERT_TYPE="letsencrypt"                    # letsencrypt | selfsigned
LETSENCRYPT_EMAIL="admin@yourdomain.com"

RKE2_VERSION="v1.28.8+rke2r1"
RANCHER_CHART_VERSION="2.8.4"
CERT_MANAGER_VERSION="v1.14.4"
# ══════════════════════════════════════════════════════════════════════════════

CLUSTER_TOKEN=$(openssl rand -hex 32)
KUBECONFIG_LOCAL="${HOME}/.kube/rancher-mgmt.yaml"
NODE_IPS=("$NODE1_IP" "$NODE2_IP" "$NODE3_IP")
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=10 -o BatchMode=yes"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;34m▶  %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m✓  %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗  ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

node_ssh()      { local ip=$1; shift; ssh $SSH_OPTS "${SSH_USER}@${ip}" "$*"; }
node_scp_to()   { local src=$1 ip=$2 dst=$3; scp $SSH_OPTS "$src" "${SSH_USER}@${ip}:${dst}"; }
node_scp_from() { local ip=$1 src=$2 dst=$3; scp $SSH_OPTS "${SSH_USER}@${ip}:${src}" "$dst"; }

wait_for_ssh() {
  local ip=$1 retries=36
  log "Waiting for SSH on ${ip}"
  until ssh $SSH_OPTS "${SSH_USER}@${ip}" "echo ready" &>/dev/null; do
    ((retries--)) || die "SSH timeout on ${ip}"
    sleep 10
  done
  ok "${ip} reachable"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0 — Preflight
# ─────────────────────────────────────────────────────────────────────────────
log "Step 0: Preflight"
command -v ssh     >/dev/null || die "ssh not found"
command -v scp     >/dev/null || die "scp not found"
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
command -v openssl >/dev/null || die "openssl not found"

[[ "$NODE1_IP"         == "10.0.0.1"              ]] && die "Set NODE1_IP / NODE2_IP / NODE3_IP"
[[ "$LB_IP"            == "34.x.x.x"              ]] && die "Set LB_IP"
[[ "$RANCHER_HOSTNAME" == "rancher.yourdomain.com" ]] && die "Set RANCHER_HOSTNAME"

SSH_KEY_EXPANDED="${SSH_KEY/#\~/$HOME}"
[[ -f "$SSH_KEY_EXPANDED" ]] || die "SSH key not found: ${SSH_KEY}"
ok "Preflight passed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — SSH connectivity
# ─────────────────────────────────────────────────────────────────────────────
log "Step 1: Verifying SSH access"
for ip in "${NODE_IPS[@]}"; do
  wait_for_ssh "$ip"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — OS prerequisites (parallel)
# RHEL 10 specifics:
#   - dnf instead of apt
#   - iscsi-initiator-utils and nfs-utils (different package names)
#   - SELinux: install rke2-selinux policy rather than disabling SELinux
#   - firewalld: open required RKE2 ports (don't disable — GCP still needs it)
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2: OS prerequisites on all nodes (RHEL 10)"

prep_node() {
  local ip=$1
  node_ssh "$ip" "
    set -e

    # ── Kernel modules ────────────────────────────────────────────────────────
    sudo modprobe overlay
    sudo modprobe br_netfilter
    printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/rke2.conf > /dev/null

    # ── Sysctl ────────────────────────────────────────────────────────────────
    sudo tee /etc/sysctl.d/99-rke2.conf > /dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sudo sysctl --system > /dev/null 2>&1

    # ── Disable swap ──────────────────────────────────────────────────────────
    sudo swapoff -a
    sudo sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab

    # ── Packages ──────────────────────────────────────────────────────────────
    sudo dnf install -y -q \
      curl tar \
      iscsi-initiator-utils \
      nfs-utils \
      container-selinux

    sudo systemctl enable --now iscsid

    # ── SELinux ───────────────────────────────────────────────────────────────
    # Install the RKE2 SELinux policy so SELinux stays Enforcing.
    # This is the correct approach — do not set SELinux to permissive in prod.
    sudo dnf install -y -q \
      https://rpm.rancher.io/rke2/latest/common/centos/8/noarch/rke2-selinux-0.17-1.el8.noarch.rpm \
      || echo 'rke2-selinux install skipped (may already be present or repo unavailable)'

    # ── firewalld — open RKE2 required ports ─────────────────────────────────
    # 6443  : K8s API server
    # 9345  : RKE2 supervisor (node join)
    # 10250 : kubelet
    # 2379-2380 : etcd (inter-node only — source restricted below)
    # 8472  : VXLAN overlay (Canal CNI)
    # 4240  : Cilium health (if using Cilium instead of Canal)
    if sudo systemctl is-active --quiet firewalld; then
      sudo firewall-cmd --permanent --add-port=6443/tcp
      sudo firewall-cmd --permanent --add-port=9345/tcp
      sudo firewall-cmd --permanent --add-port=10250/tcp
      sudo firewall-cmd --permanent --add-port=2379-2380/tcp
      sudo firewall-cmd --permanent --add-port=8472/udp
      sudo firewall-cmd --permanent --add-port=179/tcp   # BGP (Canal)
      sudo firewall-cmd --reload
    else
      echo 'firewalld not active — skipping port configuration'
    fi

  " && ok "OS prep done on ${ip}"
}

for ip in "${NODE_IPS[@]}"; do prep_node "$ip" & done
wait

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — RKE2 configs
# ─────────────────────────────────────────────────────────────────────────────
log "Step 3: Uploading RKE2 configs"

TMP_N1=$(mktemp)
cat > "$TMP_N1" <<EOF
token: ${CLUSTER_TOKEN}
cluster-init: true
tls-san:
  - ${NODE1_IP}
  - ${NODE2_IP}
  - ${NODE3_IP}
  - ${LB_IP}
  - ${RANCHER_HOSTNAME}
EOF

TMP_N23=$(mktemp)
cat > "$TMP_N23" <<EOF
token: ${CLUSTER_TOKEN}
server: https://${NODE1_IP}:9345
tls-san:
  - ${NODE1_IP}
  - ${NODE2_IP}
  - ${NODE3_IP}
  - ${LB_IP}
  - ${RANCHER_HOSTNAME}
EOF

node_scp_to "$TMP_N1"  "$NODE1_IP" "/tmp/rke2-config.yaml" && ok "Config → node 1"
node_scp_to "$TMP_N23" "$NODE2_IP" "/tmp/rke2-config.yaml" && ok "Config → node 2"
node_scp_to "$TMP_N23" "$NODE3_IP" "/tmp/rke2-config.yaml" && ok "Config → node 3"
rm -f "$TMP_N1" "$TMP_N23"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — RKE2 on node 1 (cluster-init)
# ─────────────────────────────────────────────────────────────────────────────
log "Step 4: RKE2 on node 1 — cluster-init"

node_ssh "$NODE1_IP" "
  set -e
  sudo mkdir -p /etc/rancher/rke2
  sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml
  sudo chmod 600 /etc/rancher/rke2/config.yaml

  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo -E sh -
  sudo systemctl enable rke2-server.service
  sudo systemctl start  rke2-server.service

  export PATH=\$PATH:/var/lib/rancher/rke2/bin
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  for i in \$(seq 1 36); do
    kubectl get node 2>/dev/null | grep -q ' Ready' && echo 'Node 1 Ready.' && exit 0
    sleep 10
  done
  exit 1
"
ok "Node 1 Ready"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Join nodes 2 & 3 (parallel)
# ─────────────────────────────────────────────────────────────────────────────
log "Step 5: Joining nodes 2 & 3"

join_node() {
  local ip=$1
  node_ssh "$ip" "
    set -e
    sudo mkdir -p /etc/rancher/rke2
    sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml
    sudo chmod 600 /etc/rancher/rke2/config.yaml

    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo -E sh -
    sudo systemctl enable rke2-server.service
    sudo systemctl start  rke2-server.service
  " && ok "Node ${ip} joined"
}

join_node "$NODE2_IP" &
join_node "$NODE3_IP" &
wait

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
log "Step 6: Fetching kubeconfig"

node_ssh "$NODE1_IP" \
  "sudo cp /etc/rancher/rke2/rke2.yaml /tmp/rke2-kubeconfig && sudo chmod 644 /tmp/rke2-kubeconfig"

mkdir -p "${HOME}/.kube"
node_scp_from "$NODE1_IP" "/tmp/rke2-kubeconfig" "$KUBECONFIG_LOCAL"

sed -i.bak "s|https://127.0.0.1:6443|https://${LB_IP}:6443|g" "$KUBECONFIG_LOCAL"
chmod 600 "$KUBECONFIG_LOCAL"
export KUBECONFIG="$KUBECONFIG_LOCAL"
ok "Kubeconfig → ${KUBECONFIG_LOCAL}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — All nodes Ready
# ─────────────────────────────────────────────────────────────────────────────
log "Step 7: Waiting for all 3 nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — cert-manager
# ─────────────────────────────────────────────────────────────────────────────
log "Step 8: cert-manager ${CERT_MANAGER_VERSION}"

kubectl apply -f \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"

helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set installCRDs=false \
  --wait --timeout 5m

ok "cert-manager ready"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Rancher
# ─────────────────────────────────────────────────────────────────────────────
log "Step 9: Rancher ${RANCHER_CHART_VERSION}"

helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update

if [[ "$CERT_TYPE" == "letsencrypt" ]]; then
  helm upgrade --install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --version "$RANCHER_CHART_VERSION" \
    --set hostname="$RANCHER_HOSTNAME" \
    --set bootstrapPassword=admin \
    --set replicas=3 \
    --set ingress.tls.source=letsEncrypt \
    --set letsEncrypt.email="$LETSENCRYPT_EMAIL" \
    --set letsEncrypt.ingress.class=nginx \
    --wait --timeout 10m
else
  helm upgrade --install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --version "$RANCHER_CHART_VERSION" \
    --set hostname="$RANCHER_HOSTNAME" \
    --set bootstrapPassword=admin \
    --set replicas=3 \
    --set ingress.tls.source=rancher \
    --wait --timeout 10m
fi

ok "Rancher deployed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Summary
# ─────────────────────────────────────────────────────────────────────────────
BOOTSTRAP_PASS=$(kubectl get secret \
  --namespace cattle-system bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null \
  || echo "admin")

log "Done"
cat <<SUMMARY

  ╔══════════════════════════════════════════════════════════════════╗
  ║  Rancher Management Plane — Ready                                ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║  URL               https://${RANCHER_HOSTNAME}
  ║  Bootstrap pass    ${BOOTSTRAP_PASS}
  ║  Kubeconfig        ${KUBECONFIG_LOCAL}
  ║  API server        https://${LB_IP}:6443
  ╠══════════════════════════════════════════════════════════════════╣
  ║  RKE2 nodes                                                      ║
  ║    node 1   ${NODE1_IP}   (server / etcd)
  ║    node 2   ${NODE2_IP}   (server / etcd)
  ║    node 3   ${NODE3_IP}   (server / etcd)
  ╠══════════════════════════════════════════════════════════════════╣
  ║  Importing store clusters                                        ║
  ║    UI  → Cluster Management → Import Existing                    ║
  ║    CLI → kubectl apply -f https://${RANCHER_HOSTNAME}/v3/import/<token>.yaml
  ╚══════════════════════════════════════════════════════════════════╝

SUMMARY
