#!/usr/bin/env bash
# scripts/install-vpn.sh — OpenVPN + Easy-RSA PKI setup
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
source /etc/openvpn-panel/install.conf

log()  { echo -e "\033[0;32m[✔]\033[0m $*"; }
info() { echo -e "\033[0;34m[→]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }

# ── Packages ──────────────────────────────────────────────────────────────────
info "Installing openvpn easy-rsa..."
apt-get install -y -q \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  openvpn easy-rsa 2>&1 | grep -E "^(Inst|Setting)" || true
log "Packages installed"

# ── TUN device ────────────────────────────────────────────────────────────────
if [[ ! -c /dev/net/tun ]]; then
  warn "TUN not found — creating manually"
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 666 /dev/net/tun
fi
log "TUN device: $(ls -la /dev/net/tun)"

# ── PKI ───────────────────────────────────────────────────────────────────────
PKI_DIR=/etc/openvpn/easy-rsa

if [[ ! -d "$PKI_DIR/pki/issued" ]]; then
  info "Setting up PKI..."
  make-cadir "$PKI_DIR"
  cd "$PKI_DIR"

  cat > vars << VARSEOF
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "CA"
set_var EASYRSA_REQ_CITY       "SanFrancisco"
set_var EASYRSA_REQ_ORG        "${ORG_NAME}"
set_var EASYRSA_REQ_EMAIL      "admin@${ORG_NAME,,}.local"
set_var EASYRSA_REQ_OU         "VPN"
set_var EASYRSA_KEY_SIZE       2048
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    825
set_var EASYRSA_ALGO           rsa
set_var EASYRSA_DIGEST         sha256
VARSEOF

  ./easyrsa init-pki
  echo "${ORG_NAME} CA" | ./easyrsa build-ca nopass
  ./easyrsa gen-req server nopass
  echo "yes" | ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey secret pki/ta.key
  log "PKI ready"
else
  log "PKI already exists — skipping"
fi

# ── OpenVPN server config ─────────────────────────────────────────────────────
mkdir -p /etc/openvpn /var/log/openvpn

cat > /etc/openvpn/server.conf << OVPNCONF
port ${VPN_PORT}
proto udp
dev tun

ca   ${PKI_DIR}/pki/ca.crt
cert ${PKI_DIR}/pki/issued/server.crt
key  ${PKI_DIR}/pki/private/server.key
dh   ${PKI_DIR}/pki/dh.pem
tls-auth ${PKI_DIR}/pki/ta.key 0

server ${VPN_SUBNET} 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

cipher ${DEFAULT_CIPHER}
auth SHA256
tls-version-min 1.2

keepalive 10 120
compress lzo
persist-key
persist-tun
user nobody
group nogroup

status      /var/log/openvpn/status.log
log-append  /var/log/openvpn/openvpn.log
verb 3
OVPNCONF

# ── IP forwarding ─────────────────────────────────────────────────────────────
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf 2>/dev/null || true

# ── iptables NAT ─────────────────────────────────────────────────────────────
IFACE=$(ip route | awk '/default/{print $5;exit}')
iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}/24" -o "${IFACE}" -j MASQUERADE 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# ── Start service ─────────────────────────────────────────────────────────────
systemctl enable openvpn@server
systemctl start  openvpn@server || warn "OpenVPN start failed — check: systemctl status openvpn@server"
sleep 2
systemctl is-active openvpn@server && log "OpenVPN running" || warn "OpenVPN not active yet"
