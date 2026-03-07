#!/usr/bin/env bash
# =============================================================================
#  OpenVPN Panel — Proxmox Host Deployer
#  Run this script ONCE on the Proxmox HOST shell.
#  It will create LXC container(s), install OpenVPN + web panel inside them,
#  and print the final access URL.
#
#  Usage:
#    bash proxmox-deploy.sh
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
ask()     { echo -e "${BOLD}${BLUE}  ?  ${NC}${BOLD}$*${NC}"; }

# ── Guard: must run on Proxmox host ──────────────────────────────────────────
[[ $(id -u) -ne 0 ]]          && error "Run as root on the Proxmox host"
command -v pct  &>/dev/null   || error "pct not found — run this on a Proxmox host, not inside a container"
command -v pvesh &>/dev/null  || error "pvesh not found — run this on a Proxmox host"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${BLUE}"
cat << 'BANNER'
  ___  ___  ___ _  ___   ___ _  _   ___  _   _  _ ___ _
 / _ \| _ \| __| \| \ \ / / | \| | | _ \/_\ | \| | __| |
| (_) |  _/ _|| .` |\ V /| | .` | |  _/ _ \| .` | _|| |__
 \___/|_| |___|_|\_| \_/ |_|_|\_| |_|/_/ \_\_|\_|___|____|

  Proxmox Host Deployer  ·  TP-Link Compatible  ·  RBAC Web UI
BANNER
echo -e "${NC}"
echo -e "  This script runs on your ${BOLD}Proxmox host shell${NC}."
echo -e "  It will create LXC container(s) and deploy everything inside them."
echo -e "  Nothing is installed on the host itself.\n"
echo -e "  ${YELLOW}Press ENTER to accept a default shown in [brackets].${NC}\n"
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — DEPLOYMENT MODE
# ─────────────────────────────────────────────────────────────────────────────
section "Deployment Mode"

echo -e "  ${BOLD}How do you want to deploy?${NC}\n"
echo -e "    ${CYAN}1)${NC} ${BOLD}Single container${NC}   — OpenVPN + Web Panel in one LXC  (simpler)"
echo -e "    ${CYAN}2)${NC} ${BOLD}Two containers${NC}     — VPN in CT-A, Panel in CT-B        (more secure)\n"

while true; do
  read -rp "  Choice [1]: " DEPLOY_MODE
  DEPLOY_MODE=${DEPLOY_MODE:-1}
  [[ "$DEPLOY_MODE" == "1" || "$DEPLOY_MODE" == "2" ]] && break
  warn "Enter 1 or 2"
done

if [[ "$DEPLOY_MODE" == "2" ]]; then
  log "Two-container deployment selected"
else
  log "Single-container deployment selected"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — PROXMOX STORAGE & TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────
section "Proxmox Storage"

# List available storages — try pvesm first (more reliable than pvesh)
info "Available storages:"
pvesm status 2>/dev/null | awk 'NR>1{printf "    · %-20s %s\n", $1, $2}' \
  || echo "    (could not list storages)"

echo ""
read -rp "  Storage for container rootfs [local-lvm]: " CT_STORAGE
CT_STORAGE=${CT_STORAGE:-local-lvm}

read -rp "  Storage for CT template      [local]: " TMPL_STORAGE
TMPL_STORAGE=${TMPL_STORAGE:-local}

log "Rootfs storage: $CT_STORAGE"
log "Template storage: $TMPL_STORAGE"

# ── next_free_ctid must be defined before first use ──────────────────────────
next_free_ctid() {
  local id=${1:-100}
  while pct status "$id" &>/dev/null 2>&1; do id=$((id+1)); done
  echo "$id"
}

# Find or download Ubuntu 24.04 template
section "Ubuntu 24.04 LXC Template"
TMPL_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# Check if template is already present on the storage
EXISTING_TMPL=$(pveam list "$TMPL_STORAGE" 2>/dev/null | grep "ubuntu-24.04" | awk '{print $1}' | head -1)

if [[ -n "$EXISTING_TMPL" ]]; then
  TMPL_PATH="$EXISTING_TMPL"
  log "Template already present: $TMPL_PATH"
else
  info "Template not found — downloading..."
  pveam update 2>&1 | tail -1
  pveam download "$TMPL_STORAGE" "$TMPL_NAME" \
    || error "Template download failed. Check storage '$TMPL_STORAGE' has enough space and is writable."
  TMPL_PATH="${TMPL_STORAGE}:vztmpl/${TMPL_NAME}"
  log "Template downloaded: $TMPL_PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — CONTAINER IDs & NETWORKING
# ─────────────────────────────────────────────────────────────────────────────
section "Container Configuration"

if [[ "$DEPLOY_MODE" == "1" ]]; then
  # ── Single container ────────────────────────────────────────────────────────
  DEF_CT=$(next_free_ctid 100)
  read -rp "  Container ID [${DEF_CT}]: " CT_ID
  CT_ID=${CT_ID:-$DEF_CT}
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists. Choose another."

  read -rp "  Container hostname [openvpn-panel]: " CT_HOSTNAME
  CT_HOSTNAME=${CT_HOSTNAME:-openvpn-panel}

  read -rp "  Disk size in GB [8]: " CT_DISK
  CT_DISK=${CT_DISK:-8}

  read -rp "  RAM in MB [1024]: " CT_RAM
  CT_RAM=${CT_RAM:-1024}

  read -rp "  CPU cores [2]: " CT_CORES
  CT_CORES=${CT_CORES:-2}

  echo ""
  info "Network configuration for the container:"
  echo -e "    ${YELLOW}Leave IP blank to use DHCP${NC}"
  read -rp "  Container IP (e.g. 192.168.1.50/24) [dhcp]: " CT_IP
  CT_IP=${CT_IP:-dhcp}

  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "  Gateway IP (e.g. 192.168.1.1): " CT_GW
  fi

  read -rp "  Bridge [vmbr0]: " CT_BRIDGE
  CT_BRIDGE=${CT_BRIDGE:-vmbr0}

  echo ""
  read -rsp "  Root password for the container: " CT_ROOT_PASS
  echo ""
  [[ -z "$CT_ROOT_PASS" ]] && error "Container root password cannot be empty"
  read -rsp "  Confirm root password: " CT_ROOT_PASS2
  echo ""
  [[ "$CT_ROOT_PASS" != "$CT_ROOT_PASS2" ]] && error "Passwords do not match"

else
  # ── Two containers ──────────────────────────────────────────────────────────
  echo -e "\n  ${BOLD}Container A — OpenVPN Server${NC}"
  DEF_CTA=$(next_free_ctid 100)
  read -rp "  Container ID [${DEF_CTA}]: " CT_VPN_ID
  CT_VPN_ID=${CT_VPN_ID:-$DEF_CTA}
  pct status "$CT_VPN_ID" &>/dev/null && error "Container $CT_VPN_ID already exists"

  read -rp "  Hostname [openvpn-server]: " CT_VPN_HOST
  CT_VPN_HOST=${CT_VPN_HOST:-openvpn-server}

  read -rp "  Disk GB [6]: " CT_VPN_DISK
  CT_VPN_DISK=${CT_VPN_DISK:-6}

  read -rp "  RAM MB [512]: " CT_VPN_RAM
  CT_VPN_RAM=${CT_VPN_RAM:-512}

  read -rsp "  Root password: " CT_VPN_PASS; echo ""
  [[ -z "$CT_VPN_PASS" ]] && error "Password cannot be empty"
  read -rsp "  Confirm: " CT_VPN_PASS2; echo ""
  [[ "$CT_VPN_PASS" != "$CT_VPN_PASS2" ]] && error "Passwords do not match"

  echo ""
  echo -e "  ${BOLD}Container B — Web Panel${NC}"
  DEF_CTB=$(next_free_ctid $((CT_VPN_ID+1)))
  read -rp "  Container ID [${DEF_CTB}]: " CT_PANEL_ID
  CT_PANEL_ID=${CT_PANEL_ID:-$DEF_CTB}
  pct status "$CT_PANEL_ID" &>/dev/null && error "Container $CT_PANEL_ID already exists"

  read -rp "  Hostname [openvpn-panel]: " CT_PANEL_HOST
  CT_PANEL_HOST=${CT_PANEL_HOST:-openvpn-panel}

  read -rp "  Disk GB [8]: " CT_PANEL_DISK
  CT_PANEL_DISK=${CT_PANEL_DISK:-8}

  read -rp "  RAM MB [1024]: " CT_PANEL_RAM
  CT_PANEL_RAM=${CT_PANEL_RAM:-1024}

  read -rsp "  Root password: " CT_PANEL_PASS; echo ""
  [[ -z "$CT_PANEL_PASS" ]] && error "Password cannot be empty"
  read -rsp "  Confirm: " CT_PANEL_PASS2; echo ""
  [[ "$CT_PANEL_PASS" != "$CT_PANEL_PASS2" ]] && error "Passwords do not match"

  echo ""
  info "Network configuration:"
  echo -e "    ${YELLOW}Leave IP blank to use DHCP${NC}"

  read -rp "  Bridge [vmbr0]: " CT_BRIDGE
  CT_BRIDGE=${CT_BRIDGE:-vmbr0}

  read -rp "  VPN container IP (e.g. 192.168.1.50/24) [dhcp]: " CT_VPN_IP
  CT_VPN_IP=${CT_VPN_IP:-dhcp}
  if [[ "$CT_VPN_IP" != "dhcp" ]]; then
    read -rp "  VPN container gateway: " CT_VPN_GW
  fi

  read -rp "  Panel container IP (e.g. 192.168.1.51/24) [dhcp]: " CT_PANEL_IP
  CT_PANEL_IP=${CT_PANEL_IP:-dhcp}
  if [[ "$CT_PANEL_IP" != "dhcp" ]]; then
    read -rp "  Panel container gateway: " CT_PANEL_GW
  fi

  # Internal bridge for container-to-container comms
  echo ""
  info "An internal bridge (vmbr1) will be created for container-to-container traffic."
  read -rp "  Internal bridge name [vmbr1]: " INT_BRIDGE
  INT_BRIDGE=${INT_BRIDGE:-vmbr1}

  CT_VPN_INT_IP="10.10.0.1"
  CT_PANEL_INT_IP="10.10.0.2"
  info "VPN container internal IP:   $CT_VPN_INT_IP/24"
  info "Panel container internal IP: $CT_PANEL_INT_IP/24"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — VPN & PANEL CONFIG
# ─────────────────────────────────────────────────────────────────────────────
section "OpenVPN & Panel Configuration"

read -rp "  Public IP or domain for VPN clients [auto-detect]: " SERVER_ADDR
if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
                || ip route get 8.8.8.8 | awk '{print $7}' | head -1)
  info "Auto-detected public IP: $SERVER_ADDR"
fi

read -rp "  OpenVPN port [1194]: " VPN_PORT
VPN_PORT=${VPN_PORT:-1194}

read -rp "  VPN tunnel subnet [10.8.0.0]: " VPN_SUBNET
VPN_SUBNET=${VPN_SUBNET:-10.8.0.0}

read -rp "  Web panel HTTPS port [443]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-443}

echo ""
echo -e "  ${BOLD}TP-Link Compatible Ciphers:${NC}"
echo -e "    ${CYAN}1)${NC} AES-256-CBC  — Recommended, full TP-Link support"
echo -e "    ${CYAN}2)${NC} AES-128-CBC  — Faster, full TP-Link support"
echo -e "    ${CYAN}3)${NC} AES-256-GCM  — Modern, OpenVPN 2.4+ routers"
echo -e "    ${CYAN}4)${NC} AES-128-GCM  — Modern + fast"
read -rp "  Cipher choice [1]: " CIPHER_CHOICE
case ${CIPHER_CHOICE:-1} in
  2) DEFAULT_CIPHER="AES-128-CBC" ;;
  3) DEFAULT_CIPHER="AES-256-GCM" ;;
  4) DEFAULT_CIPHER="AES-128-GCM" ;;
  *) DEFAULT_CIPHER="AES-256-CBC" ;;
esac
info "Selected cipher: $DEFAULT_CIPHER"

echo ""
read -rp "  Organisation name [MyOrg]: " ORG_NAME
ORG_NAME=${ORG_NAME:-MyOrg}

echo ""
echo -e "  ${BOLD}Web Panel Admin Account${NC}"
read -rp "  Admin username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -rsp "  Admin password: " ADMIN_PASS; echo ""
[[ -z "$ADMIN_PASS" ]] && error "Admin password cannot be empty"
read -rsp "  Confirm admin password: " ADMIN_PASS2; echo ""
[[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]] && error "Passwords do not match"

# ── GitHub repo URL ───────────────────────────────────────────────────────────
echo ""
read -rp "  GitHub repo URL [https://github.com/YOUR_USER/openvpn-panel]: " REPO_URL
REPO_URL=${REPO_URL:-https://github.com/YOUR_USER/openvpn-panel}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────
section "Confirm Installation"

echo -e "  ${BOLD}Deployment summary:${NC}\n"

if [[ "$DEPLOY_MODE" == "1" ]]; then
  echo -e "  ${CYAN}Mode:${NC}          Single container"
  echo -e "  ${CYAN}Container ID:${NC}  CT-${CT_ID}  (${CT_HOSTNAME})"
  echo -e "  ${CYAN}IP:${NC}            ${CT_IP}"
  echo -e "  ${CYAN}Resources:${NC}     ${CT_CORES} CPU · ${CT_RAM}MB RAM · ${CT_DISK}GB disk"
else
  echo -e "  ${CYAN}Mode:${NC}          Two containers"
  echo -e "  ${CYAN}VPN Container:${NC} CT-${CT_VPN_ID} (${CT_VPN_HOST}) — ${CT_VPN_IP:-dhcp}"
  echo -e "  ${CYAN}Panel Container:${NC}CT-${CT_PANEL_ID} (${CT_PANEL_HOST}) — ${CT_PANEL_IP:-dhcp}"
  echo -e "  ${CYAN}Internal bridge:${NC}${INT_BRIDGE} (10.10.0.0/24)"
fi

echo ""
echo -e "  ${CYAN}Public IP/Domain:${NC} $SERVER_ADDR"
echo -e "  ${CYAN}VPN Port:${NC}         ${VPN_PORT}/UDP"
echo -e "  ${CYAN}VPN Subnet:${NC}       ${VPN_SUBNET}/24"
echo -e "  ${CYAN}Cipher:${NC}           $DEFAULT_CIPHER"
echo -e "  ${CYAN}Panel Port:${NC}       ${PANEL_PORT}/TCP"
echo -e "  ${CYAN}Admin User:${NC}       $ADMIN_USER"
echo -e "  ${CYAN}Repo:${NC}             $REPO_URL"
echo ""

read -rp "  Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { info "Aborted."; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — CREATE INTERNAL BRIDGE (two-container only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DEPLOY_MODE" == "2" ]]; then
  section "Creating Internal Network Bridge"

  NET_IFACES=/etc/network/interfaces
  if grep -q "$INT_BRIDGE" "$NET_IFACES" 2>/dev/null; then
    warn "Bridge $INT_BRIDGE already exists — skipping"
  else
    cat >> "$NET_IFACES" << BRIDGE

# OpenVPN Panel internal bridge — added by proxmox-deploy.sh
auto ${INT_BRIDGE}
iface ${INT_BRIDGE} inet static
    address 10.10.0.254/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE
    ifup "$INT_BRIDGE" 2>/dev/null || true
    log "Bridge $INT_BRIDGE created (10.10.0.254/24)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Build the net0 argument string
net_arg() {
  local ip="$1" gw="${2:-}"
  if [[ "$ip" == "dhcp" ]]; then
    echo "name=eth0,bridge=${CT_BRIDGE},ip=dhcp,ip6=dhcp"
  elif [[ -n "$gw" ]]; then
    echo "name=eth0,bridge=${CT_BRIDGE},ip=${ip},gw=${gw}"
  else
    echo "name=eth0,bridge=${CT_BRIDGE},ip=${ip}"
  fi
}

# Run a command inside a container and stream output
ct_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -c "$*"
}

# Run a script file inside a container
ct_run_script() {
  local ctid="$1"
  local script="$2"
  # Push script into container
  pct push "$ctid" "$script" /tmp/deploy-script.sh
  pct exec "$ctid" -- bash /tmp/deploy-script.sh
  pct exec "$ctid" -- rm -f /tmp/deploy-script.sh
}

# Wait for a container to be reachable
wait_for_ct() {
  local ctid="$1"
  info "Waiting for CT-${ctid} to be ready..."
  for i in $(seq 1 30); do
    pct exec "$ctid" -- true 2>/dev/null && return 0
    sleep 2
  done
  error "CT-${ctid} did not become ready in time"
}

# Write the shared install.conf into a container
write_conf() {
  local ctid="$1"
  pct exec "$ctid" -- mkdir -p /etc/openvpn-panel
  pct exec "$ctid" -- bash -c "cat > /etc/openvpn-panel/install.conf" << CONF
SERVER_ADDR="${SERVER_ADDR}"
VPN_PORT="${VPN_PORT}"
VPN_SUBNET="${VPN_SUBNET}"
PANEL_PORT="${PANEL_PORT}"
ADMIN_USER="${ADMIN_USER}"
ADMIN_PASS="${ADMIN_PASS}"
ORG_NAME="${ORG_NAME}"
DEFAULT_CIPHER="${DEFAULT_CIPHER}"
INSTALL_DATE="$(date -Iseconds)"
CONF
  pct exec "$ctid" -- chmod 600 /etc/openvpn-panel/install.conf
}

# Clone repo into a container
clone_repo() {
  local ctid="$1"
  info "Cloning $REPO_URL into CT-${ctid}..."
  ct_exec "$ctid" "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl
    rm -rf /opt/openvpn-panel
    git clone --depth 1 '${REPO_URL}' /opt/openvpn-panel
    chmod +x /opt/openvpn-panel/install.sh /opt/openvpn-panel/scripts/*.sh
  "
  log "Repo cloned into CT-${ctid}"
}

# Run an install script inside container
run_install() {
  local ctid="$1"
  local mode="$2"   # full | vpn | panel
  info "Running installer (mode=$mode) in CT-${ctid}..."
  ct_exec "$ctid" "
    export DEBIAN_FRONTEND=noninteractive
    cd /opt/openvpn-panel
    bash install.sh --${mode}
  "
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — CREATE CONTAINER(S)
# ─────────────────────────────────────────────────────────────────────────────
section "Creating LXC Container(s)"

if [[ "$DEPLOY_MODE" == "1" ]]; then
  # ── Single container ─────────────────────────────────────────────────────
  info "Creating CT-${CT_ID} (${CT_HOSTNAME})..."

  NET0=$(net_arg "${CT_IP}" "${CT_GW:-}")

  pct create "${CT_ID}" "${TMPL_PATH}" \
    --hostname  "${CT_HOSTNAME}" \
    --memory    "${CT_RAM}" \
    --cores     "${CT_CORES}" \
    --rootfs    "${CT_STORAGE}:${CT_DISK}" \
    --net0      "${NET0}" \
    --password  "${CT_ROOT_PASS}" \
    --unprivileged 0 \
    --features  nesting=1,tun=1 \
    --onboot    1 \
    --start     1

  log "CT-${CT_ID} created"
  wait_for_ct "${CT_ID}"

  # Enable IP forwarding
  pct exec "${CT_ID}" -- sysctl -w net.ipv4.ip_forward=1
  pct exec "${CT_ID}" -- bash -c \
    "grep -q 'ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"

  write_conf "${CT_ID}"
  clone_repo "${CT_ID}"
  run_install "${CT_ID}" "full"

  # Get final IP
  PANEL_IP=$(pct exec "${CT_ID}" -- hostname -I | awk '{print $1}')
  VPN_IP="$PANEL_IP"

else
  # ── Two containers ───────────────────────────────────────────────────────

  # CT-A: VPN
  info "Creating CT-${CT_VPN_ID} (${CT_VPN_HOST}) — VPN server..."

  NET0_VPN=$(net_arg "${CT_VPN_IP:-dhcp}" "${CT_VPN_GW:-}")
  NET1_VPN="name=eth1,bridge=${INT_BRIDGE},ip=${CT_VPN_INT_IP}/24"

  pct create "${CT_VPN_ID}" "${TMPL_PATH}" \
    --hostname  "${CT_VPN_HOST}" \
    --memory    "${CT_VPN_RAM}" \
    --cores     1 \
    --rootfs    "${CT_STORAGE}:${CT_VPN_DISK}" \
    --net0      "${NET0_VPN}" \
    --net1      "${NET1_VPN}" \
    --password  "${CT_VPN_PASS}" \
    --unprivileged 0 \
    --features  nesting=1,tun=1 \
    --onboot    1 \
    --start     1

  log "CT-${CT_VPN_ID} created"
  wait_for_ct "${CT_VPN_ID}"

  pct exec "${CT_VPN_ID}" -- sysctl -w net.ipv4.ip_forward=1
  pct exec "${CT_VPN_ID}" -- bash -c \
    "grep -q 'ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"

  # CT-B: Panel
  info "Creating CT-${CT_PANEL_ID} (${CT_PANEL_HOST}) — Web panel..."

  NET0_PANEL=$(net_arg "${CT_PANEL_IP:-dhcp}" "${CT_PANEL_GW:-}")
  NET1_PANEL="name=eth1,bridge=${INT_BRIDGE},ip=${CT_PANEL_INT_IP}/24"

  pct create "${CT_PANEL_ID}" "${TMPL_PATH}" \
    --hostname  "${CT_PANEL_HOST}" \
    --memory    "${CT_PANEL_RAM}" \
    --cores     2 \
    --rootfs    "${CT_STORAGE}:${CT_PANEL_DISK}" \
    --net0      "${NET0_PANEL}" \
    --net1      "${NET1_PANEL}" \
    --password  "${CT_PANEL_PASS}" \
    --unprivileged 1 \
    --features  nesting=1 \
    --onboot    1 \
    --start     1

  log "CT-${CT_PANEL_ID} created"
  wait_for_ct "${CT_PANEL_ID}"

  # Set up SSH key auth from panel → VPN (for API calls)
  info "Setting up SSH key from panel → VPN container..."
  pct exec "${CT_PANEL_ID}" -- bash -c \
    "ssh-keygen -t ed25519 -f /root/.ssh/vpn_key -N '' -q 2>/dev/null || true"
  PANEL_PUBKEY=$(pct exec "${CT_PANEL_ID}" -- cat /root/.ssh/vpn_key.pub)
  pct exec "${CT_VPN_ID}" -- bash -c \
    "mkdir -p /root/.ssh && echo '${PANEL_PUBKEY}' >> /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
  log "SSH key auth configured"

  # Install VPN on CT-A
  section "Installing OpenVPN in CT-${CT_VPN_ID}"
  write_conf "${CT_VPN_ID}"
  clone_repo "${CT_VPN_ID}"
  run_install "${CT_VPN_ID}" "vpn"
  log "VPN installed in CT-${CT_VPN_ID}"

  # Add VPN internal IP to panel conf so the panel knows where to SSH
  pct exec "${CT_PANEL_ID}" -- bash -c \
    "echo 'VPN_CONTAINER_IP=${CT_VPN_INT_IP}' >> /etc/openvpn-panel/install.conf 2>/dev/null || true"

  # Install Panel on CT-B
  section "Installing Web Panel in CT-${CT_PANEL_ID}"
  write_conf "${CT_PANEL_ID}"
  clone_repo "${CT_PANEL_ID}"
  run_install "${CT_PANEL_ID}" "panel"
  log "Panel installed in CT-${CT_PANEL_ID}"

  # Get IPs for summary
  VPN_IP=$(pct exec "${CT_VPN_ID}" -- hostname -I | awk '{print $1}')
  PANEL_IP=$(pct exec "${CT_PANEL_ID}" -- hostname -I | awk '{print $1}')
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 8 — DONE
# ─────────────────────────────────────────────────────────────────────────────
section "Deployment Complete"

PAD=46

pad_line() {
  local content="$1"
  local visible_len
  # Strip ANSI codes for length calculation
  visible_len=$(echo -e "$content" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
  visible_len=$((visible_len - 1))
  local pad_count=$((PAD - visible_len))
  [[ $pad_count -lt 0 ]] && pad_count=0
  printf '%s%*s' "$content" "$pad_count" ""
}

echo -e "${GREEN}${BOLD}"
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║      OpenVPN Panel deployed successfully! 🎉   ║"
echo "  ╠════════════════════════════════════════════════╣"
printf "  ║  Panel URL  : https://%-24s║\n" "${PANEL_IP}"
printf "  ║  Admin user : %-30s║\n" "${ADMIN_USER}"
printf "  ║  VPN server : %-30s║\n" "${VPN_IP}:${VPN_PORT}/UDP"
printf "  ║  Cipher     : %-30s║\n" "${DEFAULT_CIPHER}"
if [[ "$DEPLOY_MODE" == "2" ]]; then
printf "  ║  VPN CT     : CT-%-28s║\n" "${CT_VPN_ID}"
printf "  ║  Panel CT   : CT-%-28s║\n" "${CT_PANEL_ID}"
fi
echo "  ╠════════════════════════════════════════════════╣"
if [[ "$DEPLOY_MODE" == "1" ]]; then
printf "  ║  Enter CT   : pct enter %-21s║\n" "${CT_ID}"
else
printf "  ║  Enter VPN  : pct enter %-21s║\n" "${CT_VPN_ID}"
printf "  ║  Enter Panel: pct enter %-21s║\n" "${CT_PANEL_ID}"
fi
echo "  ║  VPN logs   : /var/log/openvpn/openvpn.log    ║"
echo "  ║  Panel logs : journalctl -u openvpn-panel -f  ║"
echo "  ╚════════════════════════════════════════════════╝"
echo -e "${NC}"

warn "If using a self-signed certificate, your browser will show a security"
warn "warning — click 'Advanced' → 'Proceed' to access the panel."
echo ""