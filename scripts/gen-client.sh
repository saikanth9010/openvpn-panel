#!/usr/bin/env bash
# scripts/gen-client.sh — Generate a .ovpn client profile
# Usage: bash gen-client.sh <name> [--pass] [--cipher AES-256-CBC]
set -euo pipefail
source /etc/openvpn-panel/install.conf

CLIENT="${1:?Usage: gen-client.sh <name> [--pass] [--cipher CIPHER]}"
USE_PASS=false
CIPHER="${DEFAULT_CIPHER}"

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --pass)   USE_PASS=true ;;
    --cipher) CIPHER="$2"; shift ;;
  esac
  shift
done

PKI_DIR=/etc/openvpn/easy-rsa
OUTPUT_DIR=/etc/openvpn/clients
mkdir -p "$OUTPUT_DIR"

# ── Generate cert ─────────────────────────────────────────────────────────────
cd "$PKI_DIR"
if [ "$USE_PASS" = true ]; then
  ./easyrsa gen-req "$CLIENT" < /dev/null
else
  ./easyrsa gen-req "$CLIENT" nopass < /dev/null
fi
echo "yes" | ./easyrsa sign-req client "$CLIENT"

# ── Assemble .ovpn ────────────────────────────────────────────────────────────
CA_CERT=$(cat "$PKI_DIR/pki/ca.crt")
CLIENT_CERT=$(openssl x509 -in "$PKI_DIR/pki/issued/${CLIENT}.crt")
CLIENT_KEY=$(cat "$PKI_DIR/pki/private/${CLIENT}.key")
TLS_AUTH=$(cat /etc/openvpn/ta.key)

OVPN_FILE="$OUTPUT_DIR/${CLIENT}.ovpn"
cat > "$OVPN_FILE" << OVPN
# OpenVPN Client Config — ${CLIENT}
# Generated: $(date -Iseconds)
# Cipher: ${CIPHER}
# Server: ${SERVER_ADDR}:${VPN_PORT}/UDP

client
dev tun
proto udp
remote ${SERVER_ADDR} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${CIPHER}
auth SHA256
tls-version-min 1.2
key-direction 1
verb 3
$([ "$USE_PASS" = true ] && echo "askpass" || echo "# No passphrase")

<ca>
${CA_CERT}
</ca>

<cert>
${CLIENT_CERT}
</cert>

<key>
${CLIENT_KEY}
</key>

<tls-auth>
${TLS_AUTH}
</tls-auth>
OVPN

chmod 600 "$OVPN_FILE"
echo "$OVPN_FILE"
