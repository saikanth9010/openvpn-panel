#!/usr/bin/env bash
# scripts/setup-firewall.sh
set -euo pipefail
source /etc/openvpn-panel/install.conf

log()  { echo -e "\033[0;32m[✔]\033[0m $*"; }
info() { echo -e "\033[0;34m[→]\033[0m $*"; }

info "Configuring UFW firewall..."

# Reset to defaults
ufw --force reset 2>/dev/null

ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# OpenVPN
ufw allow "${VPN_PORT}/udp" comment 'OpenVPN'

# Web panel
ufw allow "${PANEL_PORT}/tcp" comment 'OVPN Panel HTTPS'
ufw allow 80/tcp comment 'HTTP redirect to HTTPS'

# Allow forwarding for VPN clients
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' \
  /etc/default/ufw 2>/dev/null || true

# NAT rules in UFW
EXT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
BEFORE_RULES=/etc/ufw/before.rules
if ! grep -q "openvpn-panel NAT" "$BEFORE_RULES" 2>/dev/null; then
  cat > /tmp/ufw-nat.txt << NAT
# openvpn-panel NAT
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${VPN_SUBNET}/24 -o ${EXT_IF} -j MASQUERADE
COMMIT

NAT
  # Prepend to before.rules
  cat /tmp/ufw-nat.txt "$BEFORE_RULES" > /tmp/before.rules.new
  mv /tmp/before.rules.new "$BEFORE_RULES"
fi

ufw --force enable
ufw status verbose
log "Firewall active"
