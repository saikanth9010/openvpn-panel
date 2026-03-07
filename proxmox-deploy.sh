#!/usr/bin/env bash
# =============================================================================
#  OpenVPN Panel — Proxmox Host Deployer
#
#  USAGE — always download first, then run:
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openvpn-panel/main/proxmox-deploy.sh \
#         -o proxmox-deploy.sh && bash proxmox-deploy.sh
#
#  Never pipe curl directly into bash — the pipe steals stdin from your prompts.
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

# ── All reads go to /dev/tty so curl|bash pipes never break prompts ───────────
ask() {
  # ask "prompt text" VAR_NAME [default]
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local display_default=""
  local answer

  [[ -n "$default" ]] && display_default=" [${default}]"

  while true; do
    printf "  %b%s%b%s: " "${BOLD}" "$prompt" "${NC}" "$display_default" > /dev/tty
    read -r answer < /dev/tty
    answer="${answer:-$default}"
    if [[ -z "$answer" && -z "$default" ]]; then
      echo -e "  ${RED}Required — cannot be empty${NC}" > /dev/tty
    else
      printf -v "$varname" '%s' "$answer"
      break
    fi
  done
}

askpass() {
  # askpass "prompt text" VAR_NAME
  local prompt="$1"
  local varname="$2"
  local answer answer2

  while true; do
    printf "  %b%s%b: " "${BOLD}" "$prompt" "${NC}" > /dev/tty
    read -rs answer < /dev/tty; echo "" > /dev/tty
    if [[ -z "$answer" ]]; then
      echo -e "  ${RED}Required — cannot be empty${NC}" > /dev/tty
      continue
    fi
    printf "  %bConfirm %s%b: " "${BOLD}" "$prompt" "${NC}" > /dev/tty
    read -rs answer2 < /dev/tty; echo "" > /dev/tty
    if [[ "$answer" != "$answer2" ]]; then
      echo -e "  ${RED}Passwords do not match — try again${NC}" > /dev/tty
    else
      printf -v "$varname" '%s' "$answer"
      break
    fi
  done
}

askchoice() {
  # askchoice "prompt" VAR_NAME option1 option2 ...
  local prompt="$1" varname="$2"; shift 2
  local opts=("$@") answer
  while true; do
    printf "  %b%s%b [%s]: " "${BOLD}" "$prompt" "${NC}" "${opts[0]}" > /dev/tty
    read -r answer < /dev/tty
    answer="${answer:-${opts[0]}}"
    for o in "${opts[@]}"; do
      if [[ "$answer" == "$o" ]]; then
        printf -v "$varname" '%s' "$answer"; return
      fi
    done
    echo -e "  ${RED}Enter one of: ${opts[*]}${NC}" > /dev/tty
  done
}

# ── Guard: must run on Proxmox host ──────────────────────────────────────────
[[ $(id -u) -ne 0 ]]         && error "Run as root on the Proxmox host"
command -v pct  &>/dev/null  || error "pct not found — this must run on a Proxmox host"
command -v pveam &>/dev/null || error "pveam not found — this must run on a Proxmox host"

# ── Detect if we were piped (stdin is not a tty) ─────────────────────────────
if [[ ! -t 0 ]]; then
  echo ""
  echo -e "${RED}${BOLD}  ✘  Do not pipe this script into bash.${NC}"
  echo -e "${YELLOW}  The pipe steals your keyboard — prompts cannot be answered.${NC}"
  echo ""
  echo -e "  Run it like this instead:\n"
  echo -e "  ${CYAN}  curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openvpn-panel/main/proxmox-deploy.sh \\"
  echo -e "       -o /root/proxmox-deploy.sh${NC}"
  echo -e "  ${CYAN}  bash /root/proxmox-deploy.sh${NC}\n"
  exit 1
fi

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
echo -e "  Runs on your ${BOLD}Proxmox host shell${NC} — creates container(s) and deploys"
echo -e "  OpenVPN + Web Panel inside them. Nothing is installed on the host.\n"
echo -e "  ${YELLOW}Press ENTER to accept the default shown in [brackets].${NC}\n"
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — DEPLOYMENT MODE
# ─────────────────────────────────────────────────────────────────────────────
section "Deployment Mode"

echo -e "  ${BOLD}How do you want to deploy?${NC}\n"
echo -e "    ${CYAN}1)${NC} ${BOLD}Single container${NC}  — OpenVPN + Web Panel in one LXC  (simpler)"
echo -e "    ${CYAN}2)${NC} ${BOLD}Two containers${NC}    — VPN in CT-A, Panel in CT-B        (recommended)\n"

askchoice "Choice" DEPLOY_MODE "1" "2"

if [[ "$DEPLOY_MODE" == "2" ]]; then
  log "Two-container deployment selected"
else
  log "Single-container deployment selected"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — PROXMOX STORAGE & TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────
section "Proxmox Storage"

info "Available storages on this host:"
pvesm status 2>/dev/null | awk 'NR>1{printf "    · %-20s %s\n", $1, $2}' \
  || echo "    (could not list — check pvesm status manually)"
echo ""

ask "Storage for container rootfs" CT_STORAGE "local-lvm"
ask "Storage for CT templates"     TMPL_STORAGE "local"

log "Rootfs storage : $CT_STORAGE"
log "Template storage: $TMPL_STORAGE"

# ── next_free_ctid helper ─────────────────────────────────────────────────────
next_free_ctid() {
  local id=${1:-100}
  while pct status "$id" &>/dev/null 2>&1; do id=$((id+1)); done
  echo "$id"
}

# ── Find or download Ubuntu 24.04 template ───────────────────────────────────
section "Ubuntu 24.04 LXC Template"
TMPL_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# grep exits 1 when nothing matches — that would kill the script under set -e
# so we use grep || true to safely get an empty string instead
EXISTING_TMPL=$(pveam list "$TMPL_STORAGE" 2>/dev/null \
  | grep "ubuntu-24.04" || true)
EXISTING_TMPL=$(echo "$EXISTING_TMPL" | awk '{print $1}' | head -1)

if [[ -n "$EXISTING_TMPL" ]]; then
  TMPL_PATH="$EXISTING_TMPL"
  log "Template already present: $TMPL_PATH"
else
  info "Template not found — updating catalogue and downloading..."
  info "(This can take 1-2 minutes depending on your connection)"
  pveam update
  pveam download "$TMPL_STORAGE" "$TMPL_NAME" \
    || error "Download failed. Check '$TMPL_STORAGE' has space and is writable."
  TMPL_PATH="${TMPL_STORAGE}:vztmpl/${TMPL_NAME}"
  log "Template ready: $TMPL_PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — CONTAINER CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
section "Container Configuration"

if [[ "$DEPLOY_MODE" == "1" ]]; then

  DEF_CT=$(next_free_ctid 100)
  ask "Container ID"       CT_ID       "$DEF_CT"
  if pct status "$CT_ID" &>/dev/null 2>&1; then
    error "Container $CT_ID already exists — choose another ID"
  fi

  ask "Container hostname" CT_HOSTNAME "openvpn-panel"
  ask "Disk size (GB)"     CT_DISK     "8"
  ask "RAM (MB)"           CT_RAM      "1024"
  ask "CPU cores"          CT_CORES    "2"

  echo ""
  info "Network — leave IP blank for DHCP, or enter e.g. 192.168.1.50/24"
  ask "Container IP" CT_IP "dhcp"
  CT_GW=""
  if [[ "$CT_IP" != "dhcp" ]]; then
    ask "Gateway IP" CT_GW ""
  fi
  ask "Bridge" CT_BRIDGE "vmbr0"

  echo ""
  askpass "Container root password" CT_ROOT_PASS

else

  echo -e "\n  ${BOLD}Container A — OpenVPN Server${NC}"
  DEF_CTA=$(next_free_ctid 100)
  ask "Container ID"       CT_VPN_ID   "$DEF_CTA"
  if pct status "$CT_VPN_ID" &>/dev/null 2>&1; then
    error "Container $CT_VPN_ID already exists"
  fi
  ask "Hostname"           CT_VPN_HOST "openvpn-server"
  ask "Disk size (GB)"     CT_VPN_DISK "6"
  ask "RAM (MB)"           CT_VPN_RAM  "512"
  askpass "Root password"  CT_VPN_PASS

  echo ""
  echo -e "  ${BOLD}Container B — Web Panel${NC}"
  DEF_CTB=$(next_free_ctid $((CT_VPN_ID+1)))
  ask "Container ID"       CT_PANEL_ID   "$DEF_CTB"
  if pct status "$CT_PANEL_ID" &>/dev/null 2>&1; then
    error "Container $CT_PANEL_ID already exists"
  fi
  ask "Hostname"           CT_PANEL_HOST "openvpn-panel"
  ask "Disk size (GB)"     CT_PANEL_DISK "8"
  ask "RAM (MB)"           CT_PANEL_RAM  "1024"
  askpass "Root password"  CT_PANEL_PASS

  echo ""
  info "Network — leave IP blank for DHCP, or enter e.g. 192.168.1.50/24"
  ask "Bridge" CT_BRIDGE "vmbr0"

  ask "VPN container IP"   CT_VPN_IP   "dhcp"
  CT_VPN_GW=""
  if [[ "$CT_VPN_IP" != "dhcp" ]]; then
    ask "VPN container gateway" CT_VPN_GW ""
  fi

  ask "Panel container IP" CT_PANEL_IP "dhcp"
  CT_PANEL_GW=""
  if [[ "$CT_PANEL_IP" != "dhcp" ]]; then
    ask "Panel container gateway" CT_PANEL_GW ""
  fi

  echo ""
  info "An internal bridge will be created for container-to-container traffic."
  ask "Internal bridge name" INT_BRIDGE "vmbr1"
  CT_VPN_INT_IP="10.10.0.1"
  CT_PANEL_INT_IP="10.10.0.2"
  info "VPN container internal IP  : $CT_VPN_INT_IP/24"
  info "Panel container internal IP: $CT_PANEL_INT_IP/24"

fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — VPN & PANEL CONFIG
# ─────────────────────────────────────────────────────────────────────────────
section "OpenVPN & Panel Configuration"

# Auto-detect public IP, let user override
AUTO_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
          || ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
          || echo "")
[[ -n "$AUTO_IP" ]] && info "Auto-detected public IP: $AUTO_IP"

ask "Public IP or domain (used in .ovpn files)" SERVER_ADDR "${AUTO_IP:-}"
ask "OpenVPN port"         VPN_PORT    "1194"
ask "VPN tunnel subnet"    VPN_SUBNET  "10.8.0.0"
ask "Web panel HTTPS port" PANEL_PORT  "443"

echo ""
echo -e "  ${BOLD}TP-Link Compatible Ciphers:${NC}"
echo -e "    ${CYAN}1)${NC} AES-256-CBC  — Recommended, full TP-Link support"
echo -e "    ${CYAN}2)${NC} AES-128-CBC  — Faster, full TP-Link support"
echo -e "    ${CYAN}3)${NC} AES-256-GCM  — Modern, OpenVPN 2.4+ routers"
echo -e "    ${CYAN}4)${NC} AES-128-GCM  — Modern + fast"
askchoice "Cipher" CIPHER_CHOICE "1" "2" "3" "4"
case "$CIPHER_CHOICE" in
  2) DEFAULT_CIPHER="AES-128-CBC" ;;
  3) DEFAULT_CIPHER="AES-256-GCM" ;;
  4) DEFAULT_CIPHER="AES-128-GCM" ;;
  *) DEFAULT_CIPHER="AES-256-CBC" ;;
esac
log "Selected cipher: $DEFAULT_CIPHER"

echo ""
ask "Organisation name" ORG_NAME "MyOrg"

echo ""
echo -e "  ${BOLD}Web Panel Admin Account${NC}"
ask     "Admin username"  ADMIN_USER "admin"
askpass "Admin password"  ADMIN_PASS

echo ""
ask "GitHub repo URL" REPO_URL "https://github.com/YOUR_USER/openvpn-panel"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────
section "Confirm Installation"

echo -e "  ${BOLD}Deployment summary:${NC}\n"
if [[ "$DEPLOY_MODE" == "1" ]]; then
  echo -e "  ${CYAN}Mode          :${NC} Single container"
  echo -e "  ${CYAN}Container     :${NC} CT-${CT_ID} (${CT_HOSTNAME}) — ${CT_IP}"
  echo -e "  ${CYAN}Resources     :${NC} ${CT_CORES} CPU · ${CT_RAM}MB RAM · ${CT_DISK}GB disk"
else
  echo -e "  ${CYAN}Mode          :${NC} Two containers"
  echo -e "  ${CYAN}VPN container :${NC} CT-${CT_VPN_ID} (${CT_VPN_HOST}) — ${CT_VPN_IP}"
  echo -e "  ${CYAN}Panel container:${NC}CT-${CT_PANEL_ID} (${CT_PANEL_HOST}) — ${CT_PANEL_IP}"
  echo -e "  ${CYAN}Internal bridge:${NC}${INT_BRIDGE} (10.10.0.0/24)"
fi
echo ""
echo -e "  ${CYAN}Public addr   :${NC} $SERVER_ADDR"
echo -e "  ${CYAN}VPN port      :${NC} ${VPN_PORT}/UDP"
echo -e "  ${CYAN}VPN subnet    :${NC} ${VPN_SUBNET}/24"
echo -e "  ${CYAN}Cipher        :${NC} $DEFAULT_CIPHER"
echo -e "  ${CYAN}Panel port    :${NC} ${PANEL_PORT}/TCP"
echo -e "  ${CYAN}Admin user    :${NC} $ADMIN_USER"
echo -e "  ${CYAN}Repo          :${NC} $REPO_URL"
echo ""

askchoice "Proceed with installation?" CONFIRM "y" "n"
[[ "$CONFIRM" != "y" ]] && { info "Aborted."; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — INTERNAL BRIDGE (two-container only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DEPLOY_MODE" == "2" ]]; then
  section "Creating Internal Network Bridge"
  NET_IFACES=/etc/network/interfaces
  if grep -q "^auto ${INT_BRIDGE}" "$NET_IFACES" 2>/dev/null; then
    warn "Bridge $INT_BRIDGE already in $NET_IFACES — skipping"
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
    ifup "$INT_BRIDGE" 2>/dev/null || ip link add name "$INT_BRIDGE" type bridge 2>/dev/null || true
    log "Bridge $INT_BRIDGE ready (10.10.0.254/24)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────────────────────
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

ct_exec() {
  local ctid="$1"; shift
  pct exec "$ctid" -- bash -c "$*"
}

wait_for_ct() {
  local ctid="$1"
  info "Waiting for CT-${ctid} to boot..."
  for i in $(seq 1 30); do
    pct exec "$ctid" -- true 2>/dev/null && log "CT-${ctid} is ready" && return 0
    sleep 2
  done
  error "CT-${ctid} did not become ready in 60s — check: pct status $ctid"
}

write_conf() {
  local ctid="$1"
  ct_exec "$ctid" "mkdir -p /etc/openvpn-panel && cat > /etc/openvpn-panel/install.conf << 'CONF'
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
chmod 600 /etc/openvpn-panel/install.conf"
}

clone_repo() {
  local ctid="$1"
  info "Installing git and cloning repo into CT-${ctid}..."
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

run_install() {
  local ctid="$1" mode="$2"
  info "Running installer (mode=$mode) in CT-${ctid} — this takes a few minutes..."
  ct_exec "$ctid" "
    export DEBIAN_FRONTEND=noninteractive
    cd /opt/openvpn-panel
    bash install.sh --${mode}
  "
  log "Installer finished in CT-${ctid}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — CREATE CONTAINER(S)
# ─────────────────────────────────────────────────────────────────────────────
section "Creating LXC Container(s)"

if [[ "$DEPLOY_MODE" == "1" ]]; then

  info "Creating CT-${CT_ID} (${CT_HOSTNAME})..."
  NET0=$(net_arg "$CT_IP" "${CT_GW:-}")
  pct create "${CT_ID}" "${TMPL_PATH}" \
    --hostname  "${CT_HOSTNAME}" \
    --memory    "${CT_RAM}" \
    --cores     "${CT_CORES}" \
    --rootfs    "${CT_STORAGE}:${CT_DISK}" \
    --net0      "${NET0}" \
    --password  "${CT_ROOT_PASS}" \
    --unprivileged 0 \
    --features  nesting=1 \
    --onboot    1
  # Enable TUN device for OpenVPN — write directly to container config
  echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> /etc/pve/lxc/${CT_ID}.conf
  echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> /etc/pve/lxc/${CT_ID}.conf
  log "TUN device configured for CT-${CT_ID}"
  pct start "${CT_ID}"
  log "CT-${CT_ID} created and started"
  wait_for_ct "${CT_ID}"

  ct_exec "${CT_ID}" "sysctl -w net.ipv4.ip_forward=1; \
    grep -q ip_forward /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"

  write_conf "${CT_ID}"
  clone_repo "${CT_ID}"
  run_install "${CT_ID}" "full"

  PANEL_IP=$(pct exec "${CT_ID}" -- hostname -I | awk '{print $1}')
  VPN_IP="$PANEL_IP"

else

  # CT-A — VPN
  info "Creating CT-${CT_VPN_ID} (${CT_VPN_HOST}) — VPN server..."
  NET0_VPN=$(net_arg "${CT_VPN_IP}" "${CT_VPN_GW:-}")

  pct create "${CT_VPN_ID}" "${TMPL_PATH}" \
    --hostname    "${CT_VPN_HOST}" \
    --memory      "${CT_VPN_RAM}" \
    --cores       1 \
    --rootfs      "${CT_STORAGE}:${CT_VPN_DISK}" \
    --net0        "${NET0_VPN}" \
    --net1        "name=eth1,bridge=${INT_BRIDGE}" \
    --password    "${CT_VPN_PASS}" \
    --unprivileged 0 \
    --features    nesting=1 \
    --onboot      1
  # Enable TUN device for OpenVPN — write directly to container config
  echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> /etc/pve/lxc/${CT_VPN_ID}.conf
  echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> /etc/pve/lxc/${CT_VPN_ID}.conf
  log "TUN device configured for CT-${CT_VPN_ID}"
  pct start "${CT_VPN_ID}"
  log "CT-${CT_VPN_ID} created and started"
  wait_for_ct "${CT_VPN_ID}"
  # Configure internal bridge IP inside container
  ct_exec "${CT_VPN_ID}" "ip addr add ${CT_VPN_INT_IP}/24 dev eth1 2>/dev/null || true; ip link set eth1 up || true"
  ct_exec "${CT_VPN_ID}" "echo 'auto eth1\niface eth1 inet static\n  address ${CT_VPN_INT_IP}/24' >> /etc/network/interfaces"
  ct_exec "${CT_VPN_ID}" "sysctl -w net.ipv4.ip_forward=1; \
    grep -q ip_forward /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"

  # CT-B — Panel
  info "Creating CT-${CT_PANEL_ID} (${CT_PANEL_HOST}) — Web panel..."
  NET0_PANEL=$(net_arg "${CT_PANEL_IP}" "${CT_PANEL_GW:-}")

  pct create "${CT_PANEL_ID}" "${TMPL_PATH}" \
    --hostname    "${CT_PANEL_HOST}" \
    --memory      "${CT_PANEL_RAM}" \
    --cores       2 \
    --rootfs      "${CT_STORAGE}:${CT_PANEL_DISK}" \
    --net0        "${NET0_PANEL}" \
    --net1        "name=eth1,bridge=${INT_BRIDGE}" \
    --password    "${CT_PANEL_PASS}" \
    --unprivileged 1 \
    --features    nesting=1 \
    --onboot      1
  pct start "${CT_PANEL_ID}"
  log "CT-${CT_PANEL_ID} created and started"
  wait_for_ct "${CT_PANEL_ID}"

  # SSH key from panel → VPN
  info "Setting up SSH key auth: CT-${CT_PANEL_ID} → CT-${CT_VPN_ID}..."
  ct_exec "${CT_PANEL_ID}" "mkdir -p /root/.ssh && \
    ssh-keygen -t ed25519 -f /root/.ssh/vpn_key -N '' -q 2>/dev/null || true"
  PANEL_PUBKEY=$(pct exec "${CT_PANEL_ID}" -- cat /root/.ssh/vpn_key.pub)
  ct_exec "${CT_VPN_ID}" "mkdir -p /root/.ssh && \
    echo '${PANEL_PUBKEY}' >> /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
  log "SSH key auth configured"

  section "Installing OpenVPN in CT-${CT_VPN_ID}"
  write_conf "${CT_VPN_ID}"
  clone_repo "${CT_VPN_ID}"
  run_install "${CT_VPN_ID}" "vpn"

  section "Installing Web Panel in CT-${CT_PANEL_ID}"
  write_conf "${CT_PANEL_ID}"
  clone_repo "${CT_PANEL_ID}"
  run_install "${CT_PANEL_ID}" "panel"

  VPN_IP=$(pct exec "${CT_VPN_ID}"   -- hostname -I | awk '{print $1}')
  PANEL_IP=$(pct exec "${CT_PANEL_ID}" -- hostname -I | awk '{print $1}')

fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 8 — DONE
# ─────────────────────────────────────────────────────────────────────────────
section "Deployment Complete"

echo -e "${GREEN}${BOLD}"
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║   OpenVPN Panel deployed successfully! 🎉      ║"
echo "  ╠════════════════════════════════════════════════╣"
printf "  ║  Panel URL  : https://%-24s║\n" "${PANEL_IP}"
printf "  ║  Admin user : %-30s║\n" "${ADMIN_USER}"
printf "  ║  VPN server : %-30s║\n" "${VPN_IP}:${VPN_PORT}/UDP"
printf "  ║  Cipher     : %-30s║\n" "${DEFAULT_CIPHER}"
if [[ "$DEPLOY_MODE" == "2" ]]; then
printf "  ║  VPN CT     : CT-%-28s║\n" "${CT_VPN_ID}"
printf "  ║  Panel CT   : CT-%-28s║\n" "${CT_PANEL_ID}"
else
printf "  ║  Container  : CT-%-28s║\n" "${CT_ID}"
fi
echo "  ╠════════════════════════════════════════════════╣"
if [[ "$DEPLOY_MODE" == "1" ]]; then
printf "  ║  Enter CT   : pct enter %-21s║\n" "${CT_ID}"
else
printf "  ║  Enter VPN  : pct enter %-21s║\n" "${CT_VPN_ID}"
printf "  ║  Enter panel: pct enter %-21s║\n" "${CT_PANEL_ID}"
fi
echo "  ║  VPN logs   : /var/log/openvpn/openvpn.log    ║"
echo "  ║  Panel logs : journalctl -u openvpn-panel -f  ║"
echo "  ╚════════════════════════════════════════════════╝"
echo -e "${NC}"
warn "If your browser shows a certificate warning, click Advanced → Proceed."
echo ""