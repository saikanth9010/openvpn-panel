#!/usr/bin/env bash
# ============================================================
#  Run this on CT-100 (the OpenVPN container) AFTER the panel install
#  Sets up OpenVPN + Easy-RSA PKI + management socket
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

step "Installing OpenVPN + Easy-RSA"
apt-get update -qq
apt-get install -y -qq openvpn easy-rsa iptables-persistent tcpdump net-tools
success "Packages installed"

step "Building PKI (Certificate Authority)"
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

cat > vars << 'VARS'
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "CA"
set_var EASYRSA_REQ_CITY       "San Francisco"
set_var EASYRSA_REQ_ORG        "OpenVPN Panel"
set_var EASYRSA_REQ_EMAIL      "admin@vpn.local"
set_var EASYRSA_KEY_SIZE       4096
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    825
VARS

./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-req server nopass
echo yes | ./easyrsa sign-req server server
./easyrsa gen-dh
openvpn --genkey secret /etc/openvpn/ta.key
success "PKI built"

step "Writing server.conf"
EXTERNAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)
info "Detected external interface: $EXTERNAL_IF"

cat > /etc/openvpn/server.conf << CONF
port 1194
proto udp
dev tun

ca   /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key  /etc/openvpn/easy-rsa/pki/private/server.key
dh   /etc/openvpn/easy-rsa/pki/dh.pem
tls-auth /etc/openvpn/ta.key 0

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

cipher AES-256-CBC
auth SHA256
tls-version-min 1.2

keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup

status /var/log/openvpn/status.log 10
log-append /var/log/openvpn/openvpn.log
verb 3

# Management socket (for web panel disconnect feature)
management /etc/openvpn/management.sock unix
CONF

mkdir -p /var/log/openvpn

step "Enabling IP Forwarding + NAT"
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p > /dev/null

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$EXTERNAL_IF" -j MASQUERADE
netfilter-persistent save > /dev/null 2>&1
success "NAT configured on $EXTERNAL_IF"

step "Starting OpenVPN"
systemctl enable openvpn@server
systemctl start  openvpn@server
sleep 2
if systemctl is-active --quiet openvpn@server; then
    success "OpenVPN is running"
    ip addr show tun0 | grep inet && success "tun0 interface is up"
else
    warn "OpenVPN may have issues — check: journalctl -u openvpn@server -n 30"
fi

LOCAL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}  ✓ VPN Container Setup Complete!${NC}"
echo ""
echo -e "  Now go to CT-101 (web panel) and run:"
echo -e "  ${YELLOW}ssh-copy-id -i /root/.ssh/vpn_key root@${LOCAL_IP}${NC}"
echo ""
