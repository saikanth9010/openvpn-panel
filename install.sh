#!/usr/bin/env bash
# =============================================================================
#  install.sh — runs INSIDE the LXC container (called by proxmox-deploy.sh)
#  Usage: bash install.sh [--full|--vpn|--panel]
# =============================================================================
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# Parse mode
MODE="full"
for arg in "$@"; do
  case "$arg" in
    --full)  MODE="full"  ;;
    --vpn)   MODE="vpn"   ;;
    --panel) MODE="panel" ;;
  esac
done

[[ $(id -u) -ne 0 ]] && error "Must run as root"
[[ -f /etc/openvpn-panel/install.conf ]] || error "/etc/openvpn-panel/install.conf not found"
source /etc/openvpn-panel/install.conf

info "Mode: $MODE  |  Server: $SERVER_ADDR  |  Org: $ORG_NAME"

# ── System prep ──────────────────────────────────────────────────────────────
section "System Update"

# Fix any dpkg interruptions silently
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y -qq 2>/dev/null || true
apt-get update -qq

# dist-upgrade handles held packages that regular upgrade refuses
apt-get dist-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -o APT::Get::Fix-Broken=true \
  -q 2>&1 | grep -E "^(Inst|Remov|Get)" || true

apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  curl wget git jq openssl \
  iptables iptables-persistent \
  net-tools iproute2 \
  tcpdump fail2ban ufw \
  -q 2>&1 | grep -E "^(Inst|Setting)" || true

log "System packages ready"

# ── OpenVPN ───────────────────────────────────────────────────────────────────
if [[ "$MODE" == "full" || "$MODE" == "vpn" ]]; then
  section "Installing OpenVPN"
  bash "$(dirname "$0")/scripts/install-vpn.sh"
  log "OpenVPN ready"
fi

# ── Web Panel ─────────────────────────────────────────────────────────────────
if [[ "$MODE" == "full" || "$MODE" == "panel" ]]; then
  section "Installing Web Panel"
  bash "$(dirname "$0")/scripts/install-panel.sh"
  log "Web panel ready"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
section "Firewall"
bash "$(dirname "$0")/scripts/setup-firewall.sh"
log "Firewall configured"

# ── Fail2Ban ──────────────────────────────────────────────────────────────────
section "Fail2Ban"
bash "$(dirname "$0")/scripts/setup-fail2ban.sh"
log "Fail2Ban configured"

section "Install Complete"
log "Mode: $MODE finished successfully"
