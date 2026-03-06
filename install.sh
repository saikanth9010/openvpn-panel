#!/usr/bin/env bash
# =============================================================================
#  OpenVPN Panel — One-Command Installer
#  Usage: curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openvpn-panel/main/install.sh | bash
#  Or:    bash install.sh [--vpn-only] [--panel-only] [--dev]
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
cat << 'BANNER'
  ___  ___  ___ _  ___   ___ _  _   ___  _   _  _ ___ _
 / _ \| _ \| __| \| \ \ / / | \| | | _ \/_\ | \| | __| |
| (_) |  _/ _|| .` |\ V /| | .` | |  _/ _ \| .` | _|| |__
 \___/|_| |___|_|\_| \_/ |_|_|\_| |_|/_/ \_\_|\_|___|____|

  Proxmox LXC · TP-Link Compatible · RBAC Web UI
BANNER
echo -e "${NC}"

# ── Parse args ────────────────────────────────────────────────────────────────
MODE="full"
DEV=false
for arg in "$@"; do
  case $arg in
    --vpn-only)   MODE="vpn" ;;
    --panel-only) MODE="panel" ;;
    --dev)        DEV=true ;;
    --help|-h)
      echo "Usage: $0 [--vpn-only] [--panel-only] [--dev]"
      echo "  --vpn-only    Install OpenVPN server only (CT-100)"
      echo "  --panel-only  Install web panel only     (CT-101)"
      echo "  --dev         Skip SSL, use HTTP on port 3000"
      exit 0 ;;
  esac
done

# ── Detect environment ────────────────────────────────────────────────────────
section "Environment Detection"

OS=$(. /etc/os-release && echo "$ID")
VER=$(. /etc/os-release && echo "$VERSION_ID")
ARCH=$(uname -m)
IS_LXC=false
[ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ 2>/dev/null && IS_LXC=true

info "OS: ${OS} ${VER} (${ARCH})"
info "Mode: ${MODE}"
info "LXC container: ${IS_LXC}"
info "Dev mode: ${DEV}"

[[ "$OS" != "ubuntu" && "$OS" != "debian" ]] && error "Unsupported OS. Ubuntu/Debian required."
[[ $(id -u) -ne 0 ]] && error "Run as root: sudo bash install.sh"

# ── Load / create config ──────────────────────────────────────────────────────
section "Configuration"

CONFIG_FILE="/etc/openvpn-panel/install.conf"
mkdir -p /etc/openvpn-panel

if [ -f "$CONFIG_FILE" ]; then
  info "Loading existing config from $CONFIG_FILE"
  source "$CONFIG_FILE"
else
  info "No config found — running interactive setup"
  echo ""

  read -rp "  Server public IP or domain [auto-detect]: " SERVER_ADDR
  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR=$(curl -sf https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    info "Auto-detected: $SERVER_ADDR"
  fi

  read -rp "  OpenVPN port [1194]: " VPN_PORT
  VPN_PORT=${VPN_PORT:-1194}

  read -rp "  VPN subnet [10.8.0.0]: " VPN_SUBNET
  VPN_SUBNET=${VPN_SUBNET:-10.8.0.0}

  read -rp "  Web panel port [443]: " PANEL_PORT
  PANEL_PORT=${PANEL_PORT:-443}

  read -rp "  Admin username [admin]: " ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}

  read -rsp "  Admin password: " ADMIN_PASS
  echo ""
  [ -z "$ADMIN_PASS" ] && error "Admin password cannot be empty"

  read -rp "  Organisation name [MyOrg]: " ORG_NAME
  ORG_NAME=${ORG_NAME:-MyOrg}

  read -rp "  Default cipher [AES-256-CBC]: " DEFAULT_CIPHER
  DEFAULT_CIPHER=${DEFAULT_CIPHER:-AES-256-CBC}

  # Save config
  cat > "$CONFIG_FILE" << CONF
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
  chmod 600 "$CONFIG_FILE"
  log "Config saved to $CONFIG_FILE"
fi

# ── System update ─────────────────────────────────────────────────────────────
section "System Update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git jq openssl \
  iptables iptables-persistent \
  net-tools iproute2 \
  tcpdump \
  fail2ban \
  ufw
log "System packages installed"

# ── Install OpenVPN ───────────────────────────────────────────────────────────
if [[ "$MODE" == "full" || "$MODE" == "vpn" ]]; then
  section "Installing OpenVPN"
  bash "$(dirname "$0")/scripts/install-vpn.sh"
  log "OpenVPN installed"
fi

# ── Install Web Panel ─────────────────────────────────────────────────────────
if [[ "$MODE" == "full" || "$MODE" == "panel" ]]; then
  section "Installing Web Panel"
  bash "$(dirname "$0")/scripts/install-panel.sh" "$DEV"
  log "Web panel installed"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
section "Configuring Firewall"
bash "$(dirname "$0")/scripts/setup-firewall.sh"
log "Firewall configured"

# ── Fail2Ban ──────────────────────────────────────────────────────────────────
section "Configuring Fail2Ban"
bash "$(dirname "$0")/scripts/setup-fail2ban.sh"
log "Fail2Ban configured"

# ── Done ─────────────────────────────────────────────────────────────────────
section "Installation Complete"

PANEL_URL="https://${SERVER_ADDR}"
[ "$DEV" = true ] && PANEL_URL="http://${SERVER_ADDR}:3000"

echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║        OpenVPN Panel is ready! 🎉            ║"
echo "  ╠══════════════════════════════════════════════╣"
echo "  ║  Panel URL : ${PANEL_URL}"
echo "  ║  Admin     : ${ADMIN_USER}"
echo "  ║  VPN Port  : ${VPN_PORT}/UDP"
echo "  ║  Subnet    : ${VPN_SUBNET}/24"
echo "  ╠══════════════════════════════════════════════╣"
echo "  ║  Logs      : journalctl -u openvpn-panel -f  ║"
echo "  ║  VPN logs  : /var/log/openvpn/openvpn.log    ║"
echo "  ║  Config    : /etc/openvpn-panel/install.conf ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
