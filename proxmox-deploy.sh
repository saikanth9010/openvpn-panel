#!/usr/bin/env bash
# =============================================================================
#  OpenVPN Panel — Proxmox Host Deployer
#  Download and run — do NOT pipe through bash:
#    curl -fsSL https://raw.githubusercontent.com/saikanth9010/openvpn-panel/main/proxmox-deploy.sh \
#         -o /root/proxmox-deploy.sh && bash /root/proxmox-deploy.sh
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# All input goes through /dev/tty so curl|bash pipes never break prompts
ask() {
  local prompt="$1" varname="$2" default="${3:-}" answer
  local hint=""; [[ -n "$default" ]] && hint=" [${default}]"
  while true; do
    printf "  %b%s%b%s: " "${BOLD}" "$prompt" "${NC}" "$hint" >/dev/tty
    read -r answer </dev/tty
    answer="${answer:-$default}"
    if [[ -z "$answer" ]]; then
      printf "  %bRequired%b\n" "${RED}" "${NC}" >/dev/tty
    else
      printf -v "$varname" '%s' "$answer"; break
    fi
  done
}

askpass() {
  local prompt="$1" varname="$2" a b
  while true; do
    printf "  %b%s%b: " "${BOLD}" "$prompt" "${NC}" >/dev/tty
    read -rs a </dev/tty; echo >/dev/tty
    [[ -z "$a" ]] && { printf "  %bRequired%b\n" "${RED}" "${NC}" >/dev/tty; continue; }
    printf "  %bConfirm %s%b: " "${BOLD}" "$prompt" "${NC}" >/dev/tty
    read -rs b </dev/tty; echo >/dev/tty
    [[ "$a" != "$b" ]] && { printf "  %bMismatch — try again%b\n" "${RED}" "${NC}" >/dev/tty; continue; }
    printf -v "$varname" '%s' "$a"; break
  done
}

askchoice() {
  local prompt="$1" varname="$2"; shift 2
  local opts=("$@") answer
  while true; do
    printf "  %b%s%b [%s]: " "${BOLD}" "$prompt" "${NC}" "${opts[0]}" >/dev/tty
    read -r answer </dev/tty
    answer="${answer:-${opts[0]}}"
    for o in "${opts[@]}"; do [[ "$answer" == "$o" ]] && { printf -v "$varname" '%s' "$answer"; return; }; done
    printf "  %bEnter one of: %s%b\n" "${RED}" "${opts[*]}" "${NC}" >/dev/tty
  done
}

# Guards
[[ $(id -u) -ne 0 ]]          && error "Run as root"
command -v pct   &>/dev/null  || error "pct not found — run on Proxmox host"
command -v pveam &>/dev/null  || error "pveam not found — run on Proxmox host"
[[ ! -t 0 ]] && {
  echo -e "\n${RED}${BOLD}Do not pipe this script into bash — it breaks prompts.${NC}"
  echo -e "Run:\n  curl -fsSL <url> -o /root/proxmox-deploy.sh && bash /root/proxmox-deploy.sh\n"
  exit 1
}

# ── Banner ─────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${BLUE}"
cat <<'BANNER'
  ___  ___  ___ _  ___   ___ _  _   ___  _   _  _ ___ _
 / _ \| _ \| __| \| \ \ / / | \| | | _ \/_\ | \| | __| |
| (_) |  _/ _|| .` |\ V /| | .` | |  _/ _ \| .` | _|| |__
 \___/|_| |___|_|\_| \_/ |_|_|\_| |_|/_/ \_\_|\_|___|____|

  Proxmox Host Deployer  ·  TP-Link Compatible  ·  RBAC Web UI
BANNER
echo -e "${NC}"
echo -e "  Creates LXC container(s) on this Proxmox host and deploys"
echo -e "  OpenVPN + Web Panel inside them automatically.\n"
echo -e "  ${YELLOW}Press ENTER to accept defaults shown in [brackets].${NC}\n"
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# ── Section 1: Mode ────────────────────────────────────────────────────────
section "Deployment Mode"
echo -e "    ${CYAN}1)${NC} ${BOLD}Single container${NC}  — OpenVPN + Panel in one LXC  (simpler)"
echo -e "    ${CYAN}2)${NC} ${BOLD}Two containers${NC}    — VPN in CT-A, Panel in CT-B   (recommended)\n"
askchoice "Choice" DEPLOY_MODE "1" "2"
[[ "$DEPLOY_MODE" == "2" ]] && log "Two-container mode" || log "Single-container mode"

# ── Section 2: Storage ─────────────────────────────────────────────────────
section "Proxmox Storage"
info "Available storages:"
pvesm status 2>/dev/null | awk 'NR>1{printf "    · %-20s %s\n",$1,$2}' || true
echo ""
ask "Rootfs storage"   CT_STORAGE   "local-lvm"
ask "Template storage" TMPL_STORAGE "local"
log "Rootfs: $CT_STORAGE  |  Templates: $TMPL_STORAGE"

# ── Section 3: Template ────────────────────────────────────────────────────
section "Ubuntu 24.04 LXC Template"
TMPL_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
EXISTING=$(pveam list "$TMPL_STORAGE" 2>/dev/null | awk '/ubuntu-24\.04/{print $1;exit}') || EXISTING=""
if [[ -n "$EXISTING" ]]; then
  TMPL_PATH="$EXISTING"
  log "Template present: $TMPL_PATH"
else
  info "Downloading Ubuntu 24.04 template..."
  pveam update
  pveam download "$TMPL_STORAGE" "$TMPL_NAME" || error "Download failed"
  TMPL_PATH="${TMPL_STORAGE}:vztmpl/${TMPL_NAME}"
  log "Template ready: $TMPL_PATH"
fi

# ── Helper ─────────────────────────────────────────────────────────────────
next_free_ctid() {
  local id=${1:-100}
  while pct status "$id" &>/dev/null 2>&1; do id=$((id+1)); done
  echo "$id"
}

# ── Section 4: Container config ────────────────────────────────────────────
section "Container Configuration"

if [[ "$DEPLOY_MODE" == "1" ]]; then
  DEF=$(next_free_ctid 100)
  ask "Container ID"       CT_ID       "$DEF"
  pct status "$CT_ID" &>/dev/null 2>&1 && error "CT-$CT_ID already exists"
  ask "Hostname"           CT_HOSTNAME "openvpn-panel"
  ask "Disk (GB)"          CT_DISK     "8"
  ask "RAM (MB)"           CT_RAM      "1024"
  ask "CPU cores"          CT_CORES    "2"
  echo ""
  info "Leave IP blank for DHCP, or enter e.g. 192.168.1.50/24"
  ask "Container IP"       CT_IP       "dhcp"
  CT_GW=""
  [[ "$CT_IP" != "dhcp" ]] && ask "Gateway" CT_GW ""
  ask "Bridge"             CT_BRIDGE   "vmbr0"
  echo ""
  askpass "Root password"  CT_ROOT_PASS
else
  echo -e "\n  ${BOLD}Container A — OpenVPN Server${NC}"
  DEF_A=$(next_free_ctid 100)
  ask "Container ID"    CT_VPN_ID    "$DEF_A"
  pct status "$CT_VPN_ID" &>/dev/null 2>&1 && error "CT-$CT_VPN_ID already exists"
  ask "Hostname"        CT_VPN_HOST  "openvpn-server"
  ask "Disk (GB)"       CT_VPN_DISK  "6"
  ask "RAM (MB)"        CT_VPN_RAM   "512"
  askpass "Root password" CT_VPN_PASS

  echo -e "\n  ${BOLD}Container B — Web Panel${NC}"
  DEF_B=$(next_free_ctid $((CT_VPN_ID+1)))
  ask "Container ID"    CT_PANEL_ID   "$DEF_B"
  pct status "$CT_PANEL_ID" &>/dev/null 2>&1 && error "CT-$CT_PANEL_ID already exists"
  ask "Hostname"        CT_PANEL_HOST "openvpn-panel"
  ask "Disk (GB)"       CT_PANEL_DISK "8"
  ask "RAM (MB)"        CT_PANEL_RAM  "1024"
  askpass "Root password" CT_PANEL_PASS

  echo ""
  info "Leave IP blank for DHCP, or enter e.g. 192.168.1.50/24"
  ask "Bridge"              CT_BRIDGE    "vmbr0"
  ask "VPN container IP"    CT_VPN_IP    "dhcp"
  CT_VPN_GW=""
  [[ "$CT_VPN_IP" != "dhcp" ]] && ask "VPN gateway" CT_VPN_GW ""
  ask "Panel container IP"  CT_PANEL_IP  "dhcp"
  CT_PANEL_GW=""
  [[ "$CT_PANEL_IP" != "dhcp" ]] && ask "Panel gateway" CT_PANEL_GW ""
  echo ""
  ask "Internal bridge"     INT_BRIDGE   "vmbr1"
  CT_VPN_INT_IP="10.10.0.1"
  CT_PANEL_INT_IP="10.10.0.2"
  info "VPN internal IP  : ${CT_VPN_INT_IP}/24"
  info "Panel internal IP: ${CT_PANEL_INT_IP}/24"
fi

# ── Section 5: VPN & Panel config ──────────────────────────────────────────
section "OpenVPN & Panel Configuration"
AUTO_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
          ip route get 8.8.8.8 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo "")
[[ -n "$AUTO_IP" ]] && info "Auto-detected public IP: $AUTO_IP"
ask "Public IP or domain"  SERVER_ADDR  "${AUTO_IP:-}"
ask "OpenVPN port"         VPN_PORT     "1194"
ask "VPN tunnel subnet"    VPN_SUBNET   "10.8.0.0"
ask "Panel HTTPS port"     PANEL_PORT   "443"
echo ""
echo -e "  ${BOLD}TP-Link Ciphers:${NC}"
echo -e "    ${CYAN}1)${NC} AES-256-CBC  ${CYAN}2)${NC} AES-128-CBC  ${CYAN}3)${NC} AES-256-GCM  ${CYAN}4)${NC} AES-128-GCM"
askchoice "Cipher" CIPHER_CHOICE "1" "2" "3" "4"
case "$CIPHER_CHOICE" in
  2) DEFAULT_CIPHER="AES-128-CBC" ;; 3) DEFAULT_CIPHER="AES-256-GCM" ;;
  4) DEFAULT_CIPHER="AES-128-GCM" ;; *) DEFAULT_CIPHER="AES-256-CBC" ;;
esac
log "Cipher: $DEFAULT_CIPHER"
echo ""
ask "Organisation name" ORG_NAME   "MyOrg"
ask "Admin username"    ADMIN_USER "admin"
askpass "Admin password" ADMIN_PASS
echo ""
ask "GitHub repo URL" REPO_URL "https://github.com/saikanth9010/openvpn-panel"

# ── Section 6: Confirm ─────────────────────────────────────────────────────
section "Confirm Installation"
echo -e "  ${BOLD}Summary:${NC}\n"
if [[ "$DEPLOY_MODE" == "1" ]]; then
  echo -e "  ${CYAN}Mode     :${NC} Single container CT-${CT_ID} (${CT_HOSTNAME})"
else
  echo -e "  ${CYAN}Mode     :${NC} Two containers"
  echo -e "  ${CYAN}VPN CT   :${NC} CT-${CT_VPN_ID} (${CT_VPN_HOST}) — ${CT_VPN_IP}"
  echo -e "  ${CYAN}Panel CT :${NC} CT-${CT_PANEL_ID} (${CT_PANEL_HOST}) — ${CT_PANEL_IP}"
fi
echo -e "  ${CYAN}Domain   :${NC} $SERVER_ADDR"
echo -e "  ${CYAN}VPN port :${NC} ${VPN_PORT}/UDP   Cipher: ${DEFAULT_CIPHER}"
echo -e "  ${CYAN}Panel    :${NC} https://...  port ${PANEL_PORT}"
echo -e "  ${CYAN}Admin    :${NC} $ADMIN_USER"
echo -e "  ${CYAN}Repo     :${NC} $REPO_URL"
echo ""
askchoice "Proceed?" CONFIRM "y" "n"
[[ "$CONFIRM" != "y" ]] && { info "Aborted."; exit 0; }

# ── Section 7: Internal bridge ─────────────────────────────────────────────
if [[ "$DEPLOY_MODE" == "2" ]]; then
  section "Internal Network Bridge"
  if grep -q "^auto ${INT_BRIDGE}" /etc/network/interfaces 2>/dev/null; then
    warn "Bridge ${INT_BRIDGE} already configured — skipping"
  else
    cat >> /etc/network/interfaces <<BRIDGE

auto ${INT_BRIDGE}
iface ${INT_BRIDGE} inet static
    address 10.10.0.254/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE
    ifup "${INT_BRIDGE}" 2>/dev/null || true
    log "Bridge ${INT_BRIDGE} ready"
  fi
fi

# ── Helpers ────────────────────────────────────────────────────────────────
ct_exec() { local id="$1"; shift; pct exec "$id" -- bash -c "$*"; }

wait_for_ct() {
  local id="$1"; info "Waiting for CT-${id}..."
  for i in $(seq 30); do pct exec "$id" -- true &>/dev/null && log "CT-${id} ready" && return; sleep 2; done
  error "CT-${id} not responding after 60s"
}

write_conf() {
  local id="$1"
  pct exec "$id" -- bash -c "mkdir -p /etc/openvpn-panel"
  pct exec "$id" -- bash -c "cat > /etc/openvpn-panel/install.conf" <<CONF
SERVER_ADDR=${SERVER_ADDR}
VPN_PORT=${VPN_PORT}
VPN_SUBNET=${VPN_SUBNET}
PANEL_PORT=${PANEL_PORT}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
ORG_NAME=${ORG_NAME}
DEFAULT_CIPHER=${DEFAULT_CIPHER}
INSTALL_DATE=$(date -Iseconds)
CONF
  pct exec "$id" -- chmod 600 /etc/openvpn-panel/install.conf
  log "Config written to CT-${id}"
}

clone_and_install() {
  local id="$1" mode="$2"
  info "Cloning repo into CT-${id}..."
  ct_exec "$id" "
    export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
    apt-get update -qq
    apt-get install -y -qq git curl
    rm -rf /opt/openvpn-panel
    git clone --depth 1 '${REPO_URL}' /opt/openvpn-panel
    chmod +x /opt/openvpn-panel/install.sh /opt/openvpn-panel/scripts/*.sh
  "
  info "Running installer (mode=${mode}) in CT-${id}..."
  ct_exec "$id" "
    export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
    cd /opt/openvpn-panel && bash install.sh --${mode}
  "
  log "Install done in CT-${id}"
}

enable_tun() {
  local id="$1"
  # Write TUN passthrough directly into Proxmox LXC config
  echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> "/etc/pve/lxc/${id}.conf"
  echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> "/etc/pve/lxc/${id}.conf"
  log "TUN device configured for CT-${id}"
}

# Build a net0 string safely — no spaces, no ambiguous args
make_net() {
  local bridge="$1" ip="$2" gw="${3:-}"
  local result="name=eth0,bridge=${bridge}"
  if [[ "$ip" == "dhcp" ]]; then
    result="${result},ip=dhcp"
  else
    result="${result},ip=${ip}"
    [[ -n "$gw" ]] && result="${result},gw=${gw}"
  fi
  echo "$result"
}

# ── Section 8: Create containers ───────────────────────────────────────────
section "Creating LXC Container(s)"

if [[ "$DEPLOY_MODE" == "1" ]]; then
  info "Creating CT-${CT_ID} (${CT_HOSTNAME})..."
  NET0=$(make_net "$CT_BRIDGE" "$CT_IP" "${CT_GW:-}")

  pct create "${CT_ID}" "${TMPL_PATH}" \
    --hostname "${CT_HOSTNAME}" \
    --memory "${CT_RAM}" \
    --cores "${CT_CORES}" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "${NET0}" \
    --password "${CT_ROOT_PASS}" \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1 || error "pct create failed for CT-${CT_ID}"

  enable_tun "${CT_ID}"
  pct start "${CT_ID}"
  log "CT-${CT_ID} started"
  wait_for_ct "${CT_ID}"
  ct_exec "${CT_ID}" "echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf && sysctl -p"
  write_conf "${CT_ID}"
  clone_and_install "${CT_ID}" "full"
  PANEL_IP=$(pct exec "${CT_ID}" -- hostname -I | awk '{print $1}')
  VPN_IP="$PANEL_IP"

else
  # ── CT-A: VPN ──────────────────────────────────────────────────────────
  info "Creating CT-${CT_VPN_ID} (${CT_VPN_HOST})..."
  NET0_VPN=$(make_net "$CT_BRIDGE" "$CT_VPN_IP" "${CT_VPN_GW:-}")

  pct create "${CT_VPN_ID}" "${TMPL_PATH}" \
    --hostname "${CT_VPN_HOST}" \
    --memory "${CT_VPN_RAM}" \
    --cores 1 \
    --rootfs "${CT_STORAGE}:${CT_VPN_DISK}" \
    --net0 "${NET0_VPN}" \
    --net1 "name=eth1,bridge=${INT_BRIDGE}" \
    --password "${CT_VPN_PASS}" \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1 || error "pct create failed for CT-${CT_VPN_ID}"

  enable_tun "${CT_VPN_ID}"
  pct start "${CT_VPN_ID}"
  log "CT-${CT_VPN_ID} started"
  wait_for_ct "${CT_VPN_ID}"
  ct_exec "${CT_VPN_ID}" "
    ip addr add ${CT_VPN_INT_IP}/24 dev eth1 2>/dev/null || true
    ip link set eth1 up
    echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf && sysctl -p
  "

  # ── CT-B: Panel ────────────────────────────────────────────────────────
  info "Creating CT-${CT_PANEL_ID} (${CT_PANEL_HOST})..."
  NET0_PANEL=$(make_net "$CT_BRIDGE" "$CT_PANEL_IP" "${CT_PANEL_GW:-}")

  pct create "${CT_PANEL_ID}" "${TMPL_PATH}" \
    --hostname "${CT_PANEL_HOST}" \
    --memory "${CT_PANEL_RAM}" \
    --cores 2 \
    --rootfs "${CT_STORAGE}:${CT_PANEL_DISK}" \
    --net0 "${NET0_PANEL}" \
    --net1 "name=eth1,bridge=${INT_BRIDGE}" \
    --password "${CT_PANEL_PASS}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 || error "pct create failed for CT-${CT_PANEL_ID}"

  pct start "${CT_PANEL_ID}"
  log "CT-${CT_PANEL_ID} started"
  wait_for_ct "${CT_PANEL_ID}"
  ct_exec "${CT_PANEL_ID}" "
    ip addr add ${CT_PANEL_INT_IP}/24 dev eth1 2>/dev/null || true
    ip link set eth1 up
  "

  # ── SSH key: panel → vpn ───────────────────────────────────────────────
  info "Setting up SSH key auth (panel → vpn)..."
  ct_exec "${CT_PANEL_ID}" "mkdir -p /root/.ssh && ssh-keygen -t ed25519 -f /root/.ssh/vpn_key -N '' -q"
  PUBKEY=$(pct exec "${CT_PANEL_ID}" -- cat /root/.ssh/vpn_key.pub)
  ct_exec "${CT_VPN_ID}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
  pct exec "${CT_VPN_ID}" -- bash -c "echo '${PUBKEY}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
  log "SSH key configured"

  # ── Install VPN ────────────────────────────────────────────────────────
  section "Installing OpenVPN in CT-${CT_VPN_ID}"
  write_conf "${CT_VPN_ID}"
  clone_and_install "${CT_VPN_ID}" "vpn"

  # ── Install Panel ──────────────────────────────────────────────────────
  section "Installing Web Panel in CT-${CT_PANEL_ID}"
  write_conf "${CT_PANEL_ID}"
  # Tell panel where to find VPN container
  pct exec "${CT_PANEL_ID}" -- bash -c "echo VPN_CONTAINER_IP=${CT_VPN_INT_IP} >> /etc/openvpn-panel/install.conf"
  clone_and_install "${CT_PANEL_ID}" "panel"

  VPN_IP=$(pct exec "${CT_VPN_ID}" -- hostname -I | awk '{print $1}')
  PANEL_IP=$(pct exec "${CT_PANEL_ID}" -- hostname -I | awk '{print $1}')
fi

# ── Done ───────────────────────────────────────────────────────────────────
section "Deployment Complete"
echo -e "${GREEN}${BOLD}"
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║   OpenVPN Panel deployed successfully! 🎉      ║"
echo "  ╠════════════════════════════════════════════════╣"
printf "  ║  Panel URL  : https://%-24s║\n" "${PANEL_IP}"
printf "  ║  Admin user : %-30s║\n" "${ADMIN_USER}"
printf "  ║  VPN        : %-30s║\n" "${VPN_IP}:${VPN_PORT}/UDP"
printf "  ║  Cipher     : %-30s║\n" "${DEFAULT_CIPHER}"
if [[ "$DEPLOY_MODE" == "2" ]]; then
printf "  ║  VPN CT     : pct enter %-21s║\n" "${CT_VPN_ID}"
printf "  ║  Panel CT   : pct enter %-21s║\n" "${CT_PANEL_ID}"
else
printf "  ║  Container  : pct enter %-21s║\n" "${CT_ID}"
fi
echo "  ╠════════════════════════════════════════════════╣"
echo "  ║  VPN logs   : /var/log/openvpn/openvpn.log    ║"
echo "  ║  Panel logs : journalctl -u openvpn-panel -f  ║"
echo "  ╚════════════════════════════════════════════════╝"
echo -e "${NC}"
warn "First browser visit: click Advanced → Proceed (self-signed cert)"
