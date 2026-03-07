#!/usr/bin/env bash
# scripts/install-panel.sh — Installs Node.js backend + React frontend + Nginx
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
source /etc/openvpn-panel/install.conf

PANEL_DIR=/opt/openvpn-panel
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log()  { echo -e "\033[0;32m[✔]\033[0m $*"; }
info() { echo -e "\033[0;34m[→]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
error(){ echo -e "\033[0;31m[✘]\033[0m $*"; exit 1; }

# ── Node.js 20 ────────────────────────────────────────────────────────────────
if ! node --version 2>/dev/null | grep -q "v20"; then
  info "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -3
  apt-get install -y nodejs 2>&1 | grep -E "^(Setting up|nodejs)" || true
fi
log "Node $(node --version)  npm $(npm --version)"

# ── Nginx ─────────────────────────────────────────────────────────────────────
apt-get install -y nginx 2>&1 | grep -E "^(Setting up|nginx)" || true
log "Nginx ready"

# ── Copy project files ────────────────────────────────────────────────────────
info "Setting up $PANEL_DIR..."
mkdir -p "$PANEL_DIR/data"
cp "$REPO_DIR/backend/server.js"    "$PANEL_DIR/server.js"
cp "$REPO_DIR/backend/package.json" "$PANEL_DIR/package.json"
mkdir -p "$PANEL_DIR/frontend"
cp -r "$REPO_DIR/frontend/." "$PANEL_DIR/frontend/"
log "Files copied"

# ── Backend dependencies ──────────────────────────────────────────────────────
info "Installing backend npm packages..."
cd "$PANEL_DIR"
npm install 2>&1 | tail -3
[[ -d "$PANEL_DIR/node_modules/express" ]] || error "npm install failed"
log "Backend packages installed"

# ── Frontend build ────────────────────────────────────────────────────────────
info "Building React frontend..."
cd "$PANEL_DIR/frontend"
npm install 2>&1 | tail -3
npm run build 2>&1 | tail -5
[[ -d "$PANEL_DIR/frontend/dist" ]] || error "Frontend build failed — dist missing"
log "Frontend built: $PANEL_DIR/frontend/dist"

# ── Runtime env ───────────────────────────────────────────────────────────────
info "Writing /etc/openvpn-panel/env..."
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)
VPN_CONTAINER_IP="${VPN_CONTAINER_IP:-10.10.0.1}"

mkdir -p /etc/openvpn-panel
cat > /etc/openvpn-panel/env << ENV
NODE_ENV=production
PORT=3001
JWT_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}
VPN_HOST=${VPN_CONTAINER_IP}
VPN_SSH_USER=root
VPN_SSH_KEY=/root/.ssh/vpn_key
VPN_STATUS_LOG=/var/log/openvpn/status.log
VPN_LOG=/var/log/openvpn/openvpn.log
VPN_EASY_RSA=/etc/openvpn/easy-rsa
VPN_PUBLIC_IP=${SERVER_ADDR}
SERVER_ADDR=${SERVER_ADDR}
VPN_PORT=${VPN_PORT}
VPN_SUBNET=${VPN_SUBNET}
DEFAULT_CIPHER=${DEFAULT_CIPHER}
ENV
chmod 600 /etc/openvpn-panel/env
log "Runtime env written"

# ── Seed admin user (uses passwordHash to match server.js) ───────────────────
info "Seeding admin user..."
cd "$PANEL_DIR"
node -e "
const bcrypt = require('bcryptjs');
const {v4:uuidv4} = require('uuid');
const fs = require('fs');
const user = {
  id: uuidv4(),
  username: '${ADMIN_USER}',
  passwordHash: bcrypt.hashSync('${ADMIN_PASS}', 10),
  name: 'Administrator',
  role: 'admin',
  status: 'active',
  createdAt: new Date().toISOString()
};
fs.writeFileSync('${PANEL_DIR}/data/users.json', JSON.stringify([user],null,2));
console.log('Seeded:', user.username);
"
chmod 600 "$PANEL_DIR/data/users.json"
log "Admin user seeded: ${ADMIN_USER}"

# ── SSL cert ──────────────────────────────────────────────────────────────────
SSL_CERT="/etc/ssl/openvpn-panel/cert.pem"
SSL_KEY="/etc/ssl/openvpn-panel/key.pem"

if [[ ! -f "$SSL_CERT" ]]; then
  mkdir -p /etc/ssl/openvpn-panel
  # Try Let's Encrypt if SERVER_ADDR looks like a domain
  if [[ "$SERVER_ADDR" =~ ^[a-zA-Z][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    info "Trying Let's Encrypt for $SERVER_ADDR..."
    apt-get install -y certbot 2>/dev/null | grep "Setting up" || true
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone --non-interactive --agree-tos \
      --email "admin@${SERVER_ADDR}" -d "$SERVER_ADDR" 2>/dev/null \
      && SSL_CERT="/etc/letsencrypt/live/${SERVER_ADDR}/fullchain.pem" \
      && SSL_KEY="/etc/letsencrypt/live/${SERVER_ADDR}/privkey.pem" \
      && log "Let's Encrypt cert obtained" \
      || warn "Let's Encrypt failed — using self-signed"
    systemctl start nginx 2>/dev/null || true
  fi
  # Self-signed fallback
  if [[ ! -f "$SSL_CERT" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$SSL_KEY" -out "$SSL_CERT" \
      -subj "/CN=${SERVER_ADDR}/O=${ORG_NAME}/C=US" 2>/dev/null
    log "Self-signed cert generated"
  fi
fi

# ── Nginx config ──────────────────────────────────────────────────────────────
info "Writing nginx config..."
cat > /etc/nginx/sites-available/openvpn-panel << NGINX
server {
    listen 80;
    return 301 https://\$host\$request_uri;
}

server {
    listen ${PANEL_PORT} ssl http2;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Serve React SPA
    root /opt/openvpn-panel/frontend/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # API
    location /api/ {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 120s;
    }

    # WebSocket
    location /ws/ {
        proxy_pass             http://127.0.0.1:3001;
        proxy_http_version     1.1;
        proxy_set_header       Upgrade \$http_upgrade;
        proxy_set_header       Connection "upgrade";
        proxy_set_header       Host \$host;
        proxy_read_timeout     3600s;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/openvpn-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t || error "Nginx config test failed"
systemctl enable nginx
systemctl restart nginx
log "Nginx configured and running"

# ── Systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/openvpn-panel.service << SERVICE
[Unit]
Description=OpenVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openvpn-panel
EnvironmentFile=/etc/openvpn-panel/env
ExecStart=/usr/bin/node /opt/openvpn-panel/server.js
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
sleep 3
systemctl is-active openvpn-panel \
  && log "Panel service running on :3001" \
  || { journalctl -u openvpn-panel -n 20 --no-pager; error "Panel service failed to start"; }
