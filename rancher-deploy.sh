#!/bin/bash
# ==========================================================
# Full HA Rancher Deployment (3-node control plane + HAProxy + Keepalived + Longhorn)
# Compatible with: RHEL 9, Rancher v2.12.3, RKE2 v1.31.4+rke2r1, Longhorn v1.9.2
# ==========================================================
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================

MGMT_NODES=("rancher-mgmt1" "rancher-mgmt2" "rancher-mgmt3")
WORKER_NODES=("rancher-worker1" "rancher-worker2" "rancher-worker3")
SSH_USER="rancheradmin"

VIP="10.0.0.50"
VIP_INTERFACE="eth0"
LB_FQDN="rancher-lb.example.com"

RANCHER_VERSION="v2.12.3"
RKE2_VERSION="v1.31.4+rke2r1"
LONGHORN_VERSION="v1.9.2"
CLUSTER_NAME="rancher-production"

CLUSTER_DIR="/opt/rke2-ha"
mkdir -p "${CLUSTER_DIR}"

PACKAGES="curl wget tar jq unzip socat conntrack iptables ebtables ethtool nfs-utils haproxy keepalived open-iscsi"

# ==============================
# HELPER FUNCTIONS
# ==============================

log()  { echo "[INFO] $1"; }
err()  { echo "[ERROR] $1" >&2; exit 1; }
remote_exec() { ssh -o StrictHostKeyChecking=no ${SSH_USER}@$1 "$2"; }

# ==============================
# SYSTEM PREPARATION
# ==============================

prep_node() {
  local node=$1
  log "Preparing node: $node"
  remote_exec $node "
    sudo dnf -y update &&
    sudo dnf install -y ${PACKAGES} &&
    sudo systemctl disable --now firewalld || true &&
    sudo setenforce 0 || true &&
    sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config &&
    sudo modprobe br_netfilter &&
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward &&
    echo 'net.bridge.bridge-nf-call-iptables = 1' | sudo tee /etc/sysctl.d/99-kubernetes.conf &&
    sudo sysctl --system &&
    sudo systemctl enable --now iscsid || true
  "
}

# ==============================
# LOAD BALANCER CONFIG (on all 3 mgmt nodes)
# ==============================

setup_haproxy_keepalived() {
  local node=$1 priority=$2
  log "Setting up HAProxy + Keepalived on $node"

  # Each HAProxy listens on alternate ports 6444/9346 to avoid conflict with RKE2
  local backend_cfg=""
  for host in "${MGMT_NODES[@]}"; do
    backend_cfg+="    server ${host} ${host}:6443 check\n"
  done

  remote_exec $node "sudo bash -c 'cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  maxconn 4096
  user haproxy
  group haproxy
  daemon

defaults
  log global
  mode tcp
  option tcplog
  timeout connect 10s
  timeout client 1m
  timeout server 1m

frontend k8s_api
  bind *:6444
  default_backend k8s_servers

backend k8s_servers
${backend_cfg}

frontend rke2_api
  bind *:9346
  default_backend rke2_servers

backend rke2_servers
$(echo -e "${backend_cfg//6443/9345}")
EOF'"

  remote_exec $node "sudo systemctl enable haproxy --now"

  # Keepalived config for VIP floating on eth0
  remote_exec $node "sudo bash -c 'cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_1 {
  state BACKUP
  interface ${VIP_INTERFACE}
  virtual_router_id 51
  priority ${priority}
  advert_int 1
  authentication {
    auth_type PASS
    auth_pass 42secret
  }
  virtual_ipaddress {
    ${VIP}/24
  }
}
EOF'"
  remote_exec $node "sudo systemctl enable --now keepalived"
}

# ==============================
# RKE2 INSTALLATION
# ==============================

install_rke2_server() {
  local node=$1
  remote_exec $node "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -"
  remote_exec $node "sudo systemctl enable rke2-server"
}

install_rke2_agent() {
  local node=$1
  remote_exec $node "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE='agent' INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -"
  remote_exec $node "sudo systemctl enable rke2-agent"
}

# ==============================
# CLUSTER BOOTSTRAP
# ==============================

generate_token() {
  echo "$(uuidgen).$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48)"
}

bootstrap_control_plane() {
  local node=${MGMT_NODES[0]} token=$1
  log "Bootstrapping primary control-plane on $node"
  remote_exec $node "sudo mkdir -p /etc/rancher/rke2 &&
    echo -e 'token: ${token}\nserver: https://${VIP}:9346\ntls-san:\n  - ${VIP}\n  - ${LB_FQDN}' | sudo tee /etc/rancher/rke2/config.yaml"
  remote_exec $node "sudo systemctl start rke2-server"
  sleep 120
  echo "${token}" > ${CLUSTER_DIR}/server_token
  remote_exec $node "sudo cat /etc/rancher/rke2/rke2.yaml" > ${CLUSTER_DIR}/kubeconfig
}

join_control_planes() {
  local token=$1
  for node in "${MGMT_NODES[@]:1}"; do
    log "Joining additional control-plane: $node"
    remote_exec $node "sudo mkdir -p /etc/rancher/rke2 &&
      echo -e 'server: https://${VIP}:9346\ntoken: ${token}\ntls-san:\n  - ${VIP}\n  - ${LB_FQDN}' | sudo tee /etc/rancher/rke2/config.yaml"
    remote_exec $node "sudo systemctl start rke2-server"
    sleep 60
  done
}

join_workers() {
  local token=$1
  for node in "${WORKER_NODES[@]}"; do
    log "Joining worker/storage node: $node"
    remote_exec $node "sudo mkdir -p /etc/rancher/rke2 &&
      echo -e 'server: https://${VIP}:9346\ntoken: ${token}' | sudo tee /etc/rancher/rke2/config.yaml"
    remote_exec $node "sudo systemctl start rke2-agent"
    sleep 30
  done
}

# ==============================
# RANCHER INSTALLATION
# ==============================

install_rancher() {
  local node=${MGMT_NODES[0]}
  log "Installing Helm, cert-manager, and Rancher on $node"
  remote_exec $node "
    curl -sL https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz -o helm.tgz &&
    tar -xzf helm.tgz && sudo mv linux-amd64/helm /usr/local/bin/ &&
    rm -rf helm.tgz linux-amd64 &&
    sudo mkdir -p /root/.kube &&
    sudo cp /etc/rancher/rke2/rke2.yaml /root/.kube/config &&
    sudo helm repo add rancher-stable https://releases.rancher.com/server-charts/stable &&
    sudo helm repo add jetstack https://charts.jetstack.io &&
    sudo helm repo update &&
    sudo helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true
  "
  sleep 90
  remote_exec $node "sudo helm install ${CLUSTER_NAME} rancher-stable/rancher --namespace cattle-system --create-namespace --set hostname=${LB_FQDN} --version ${RANCHER_VERSION}"
}

# ==============================
# LONGHORN INSTALLATION
# ==============================

install_longhorn() {
  local node=${MGMT_NODES[0]}
  log "Installing Longhorn v${LONGHORN_VERSION}"
  remote_exec $node "
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml &&
    sudo helm repo add longhorn https://charts.longhorn.io &&
    sudo helm repo update &&
    sudo helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version ${LONGHORN_VERSION} &&
    sudo kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n longhorn-system wait --for=condition=Ready pods --all --timeout=600s
  "
}

# ==============================
# KUBECONFIG SETUP
# ==============================

setup_kubeconfig() {
  log "Configuring kubeconfig for kubectl access"
  sed -i "s/127.0.0.1/${VIP}/g" ${CLUSTER_DIR}/kubeconfig
  sed -i "s/server: https:\/\/.*:6443/server: https:\/\/${VIP}:6443/" ${CLUSTER_DIR}/kubeconfig
  export KUBECONFIG=${CLUSTER_DIR}/kubeconfig
  if ! grep -q "KUBECONFIG=${CLUSTER_DIR}/kubeconfig" ~/.bashrc; then
    echo "export KUBECONFIG=${CLUSTER_DIR}/kubeconfig" >> ~/.bashrc
  fi
  if kubectl --kubeconfig=${CLUSTER_DIR}/kubeconfig get nodes >/dev/null 2>&1; then
    log "kubectl access verified successfully"
  else
    err "kubectl validation failed — check VIP or kubeconfig"
  fi
}

# ==============================
# MAIN EXECUTION
# ==============================

log "Step 1: Preparing all nodes"
for n in "${MGMT_NODES[@]}" "${WORKER_NODES[@]}"; do prep_node "$n"; done

log "Step 2: Configuring HAProxy + Keepalived on all mgmt nodes"
setup_haproxy_keepalived "${MGMT_NODES[0]}" 150
setup_haproxy_keepalived "${MGMT_NODES[1]}" 120
setup_haproxy_keepalived "${MGMT_NODES[2]}" 100

log "Step 3: Installing RKE2"
for n in "${MGMT_NODES[@]}"; do install_rke2_server "$n"; done
for n in "${WORKER_NODES[@]}"; do install_rke2_agent "$n"; done

log "Step 4: Bootstrapping cluster"
TOKEN=$(generate_token)
bootstrap_control_plane "$TOKEN"
join_control_planes "$TOKEN"
join_workers "$TOKEN"

log "Step 5: Installing Rancher"
install_rancher

log "Step 6: Installing Longhorn"
install_longhorn

log "Step 7: Configuring kubeconfig"
setup_kubeconfig

log "Rancher HA + Longhorn deployment completed successfully"
log "Cluster name: ${CLUSTER_NAME}"
log "Kubeconfig: ${CLUSTER_DIR}/kubeconfig"
log "Access Rancher UI: https://${LB_FQDN}"
