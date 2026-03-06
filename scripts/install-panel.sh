#!/usr/bin/env bash
# scripts/install-panel.sh — Installs Node.js backend + React frontend + Nginx
set -euo pipefail
source /etc/openvpn-panel/install.conf

DEV="${1:-false}"
PANEL_DIR=/opt/openvpn-panel
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log()  { echo -e "\033[0;32m[✔]\033[0m $*"; }
info() { echo -e "\033[0;34m[→]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }

# ── Node.js ───────────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  info "Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - -qq
  apt-get install -y -qq nodejs
fi
NODE_VER=$(node --version)
log "Node.js $NODE_VER ready"

# ── Nginx ─────────────────────────────────────────────────────────────────────
apt-get install -y -qq nginx
log "Nginx installed"

# ── Copy project files ────────────────────────────────────────────────────────
info "Copying project to $PANEL_DIR..."
mkdir -p "$PANEL_DIR"
cp -r "$REPO_DIR/backend/."  "$PANEL_DIR/"
cp -r "$REPO_DIR/frontend/." "$PANEL_DIR/frontend/"
log "Files copied"

# ── Backend dependencies ──────────────────────────────────────────────────────
info "Installing backend dependencies..."
cd "$PANEL_DIR"
npm install --omit=dev --silent
log "Backend deps installed"

# ── Frontend build ────────────────────────────────────────────────────────────
info "Building React frontend..."
cd "$PANEL_DIR/frontend"
npm install --silent
npm run build
log "Frontend built → $PANEL_DIR/frontend/dist"

# ── Write runtime config ──────────────────────────────────────────────────────
info "Writing runtime environment..."
HASHED_PASS=$(node -e "const b=require('bcryptjs');console.log(b.hashSync('${ADMIN_PASS}',10))")

JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

mkdir -p /etc/openvpn-panel
cat > /etc/openvpn-panel/env << ENV
NODE_ENV=production
PORT=3001
JWT_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}
VPN_STATUS_LOG=/var/log/openvpn/status.log
VPN_LOG=/var/log/openvpn/openvpn.log
EASYRSA_DIR=/etc/openvpn/easy-rsa
TA_KEY=/etc/openvpn/ta.key
CA_CRT_PATH=/etc/openvpn/easy-rsa/pki/ca.crt
SERVER_ADDR=${SERVER_ADDR}
VPN_PORT=${VPN_PORT}
VPN_SUBNET=${VPN_SUBNET}
DEFAULT_CIPHER=${DEFAULT_CIPHER}
ENV
chmod 600 /etc/openvpn-panel/env
log "Runtime env written"

# ── Seed admin user ───────────────────────────────────────────────────────────
cat > /etc/openvpn-panel/users.json << USERS
[
  {
    "id": 1,
    "username": "${ADMIN_USER}",
    "password": "${HASHED_PASS}",
    "name": "Administrator",
    "role": "admin",
    "status": "active",
    "created": "$(date -Iseconds)"
  }
]
USERS
chmod 600 /etc/openvpn-panel/users.json
log "Admin user created: ${ADMIN_USER}"

# ── SSL Certificate ───────────────────────────────────────────────────────────
if [ "$DEV" != "true" ]; then
  mkdir -p /etc/ssl/openvpn-panel
  if command -v certbot &>/dev/null 2>&1; then
    # Try Let's Encrypt if domain (not IP)
    if [[ "$SERVER_ADDR" =~ ^[a-zA-Z] ]]; then
      info "Attempting Let's Encrypt for $SERVER_ADDR..."
      certbot certonly --standalone --non-interactive --agree-tos \
        --email "admin@${SERVER_ADDR}" -d "$SERVER_ADDR" \
        --pre-hook "systemctl stop nginx" \
        --post-hook "systemctl start nginx" 2>/dev/null \
        && SSL_CERT="/etc/letsencrypt/live/${SERVER_ADDR}/fullchain.pem" \
        && SSL_KEY="/etc/letsencrypt/live/${SERVER_ADDR}/privkey.pem" \
        || warn "Let's Encrypt failed — falling back to self-signed"
    fi
  fi
  # Self-signed fallback
  if [ ! -f "/etc/ssl/openvpn-panel/cert.pem" ] && [ -z "${SSL_CERT:-}" ]; then
    info "Generating self-signed certificate..."
    openssl req -x509 -nodes -days 825 \
      -newkey rsa:4096 \
      -keyout /etc/ssl/openvpn-panel/key.pem \
      -out    /etc/ssl/openvpn-panel/cert.pem \
      -subj "/CN=${SERVER_ADDR}/O=${ORG_NAME}/C=US" 2>/dev/null
    SSL_CERT="/etc/ssl/openvpn-panel/cert.pem"
    SSL_KEY="/etc/ssl/openvpn-panel/key.pem"
    log "Self-signed cert generated"
  fi

  # ── Nginx HTTPS config ────────────────────────────────────────────────────
  cat > /etc/nginx/sites-available/openvpn-panel << NGINX
server {
    listen 80;
    server_name ${SERVER_ADDR};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${PANEL_PORT} ssl http2;
    server_name ${SERVER_ADDR};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    # React SPA
    location / {
        root ${PANEL_DIR}/frontend/dist;
        try_files \$uri /index.html;
        expires 1h;
    }

    # API proxy
    location /api/ {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }

    # WebSocket (tcpdump stream)
    location /ws/ {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_read_timeout 3600s;
    }
}
NGINX
else
  # Dev: plain HTTP proxy
  cat > /etc/nginx/sites-available/openvpn-panel << NGINX
server {
    listen 3000;
    location / { root ${PANEL_DIR}/frontend/dist; try_files \$uri /index.html; }
    location /api/ { proxy_pass http://127.0.0.1:3001; proxy_http_version 1.1; }
    location /ws/  { proxy_pass http://127.0.0.1:3001; proxy_http_version 1.1;
                     proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
}
NGINX
fi

ln -sf /etc/nginx/sites-available/openvpn-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx
log "Nginx configured"

# ── Systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/openvpn-panel.service << SERVICE
[Unit]
Description=OpenVPN Web Panel
Documentation=https://github.com/YOUR_USER/openvpn-panel
After=network.target openvpn@server.service
Wants=openvpn@server.service

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
EnvironmentFile=/etc/openvpn-panel/env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openvpn-panel

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable openvpn-panel
systemctl restart openvpn-panel
sleep 2
systemctl is-active openvpn-panel \
  && log "Web panel service is running on :3001" \
  || (journalctl -u openvpn-panel -n 30 --no-pager; exit 1)
