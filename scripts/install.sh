#!/usr/bin/env bash
# ============================================================
#  OpenVPN Web Panel — One-Command Installer
#  Usage: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/openvpn-panel/main/scripts/install.sh | bash
#  Or:    git clone ... && bash scripts/install.sh
# ============================================================
set -euo pipefail

REPO="https://github.com/YOUR_USERNAME/openvpn-panel"
INSTALL_DIR="/opt/openvpn-panel"
NODE_VERSION="20"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}"
cat << 'BANNER'
  ___                 __   _____  _   _   ____                  _
 / _ \ _ __   ___ _ _\ \ / / _ \| \ | | |  _ \ __ _ _ __   ___| |
| | | | '_ \ / _ \ '_ \ V /| |_) |  \| | | |_) / _` | '_ \ / _ \ |
| |_| | |_) |  __/ | | | | |  __/| |\  | |  __/ (_| | | | |  __/ |
 \___/| .__/ \___|_| |_|_| |_|   |_| \_| |_|   \__,_|_| |_|\___|_|
      |_|         Proxmox LXC  •  TP-Link Compatible  •  RBAC
BANNER
echo -e "${NC}"

# ── Preflight checks ─────────────────────────────────────────
step "Preflight Checks"

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"

OS=$(. /etc/os-release && echo "$ID")
VER=$(. /etc/os-release && echo "$VERSION_ID")
info "Detected OS: $OS $VER"
[[ "$OS" != "ubuntu" && "$OS" != "debian" ]] && warn "Tested on Ubuntu/Debian. Proceeding anyway."

# Check if running inside LXC
if systemd-detect-virt --container > /dev/null 2>&1; then
    success "Running inside LXC container"
else
    warn "Not detected as LXC. This installer is designed for Proxmox LXC."
fi

# ── System update ─────────────────────────────────────────────
step "System Update"
apt-get update -qq
apt-get install -y -qq curl git wget gnupg2 lsb-release ca-certificates \
    nginx openssl ufw fail2ban tcpdump net-tools
success "System packages installed"

# ── Node.js ──────────────────────────────────────────────────
step "Node.js $NODE_VERSION"
if command -v node &>/dev/null && node --version | grep -q "^v${NODE_VERSION}"; then
    success "Node.js $(node --version) already installed"
else
    info "Installing Node.js $NODE_VERSION..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs
    success "Node.js $(node --version) installed"
fi

# ── Clone / update repo ───────────────────────────────────────
step "Installing OpenVPN Panel"
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Existing install found — pulling latest..."
    cd "$INSTALL_DIR" && git pull
else
    # If running from a pipe (curl | bash), clone from GitHub
    if [[ ! -d "$(dirname "$0")/../frontend" ]]; then
        info "Cloning from $REPO..."
        git clone "$REPO" "$INSTALL_DIR"
    else
        # Running from a local clone
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        LOCAL_REPO="$(dirname "$SCRIPT_DIR")"
        info "Copying from local repo: $LOCAL_REPO"
        cp -r "$LOCAL_REPO" "$INSTALL_DIR"
    fi
fi
cd "$INSTALL_DIR"
success "Files ready at $INSTALL_DIR"

# ── Backend dependencies ──────────────────────────────────────
step "Backend Dependencies"
cd "$INSTALL_DIR/backend"
npm install --production --silent
success "Backend packages installed"

# ── Frontend build ────────────────────────────────────────────
step "Frontend Build"
cd "$INSTALL_DIR/frontend"
npm install --silent
npm run build
success "React app built to frontend/dist/"

# ── Environment config ────────────────────────────────────────
step "Environment Configuration"
ENV_FILE="$INSTALL_DIR/backend/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    cp "$INSTALL_DIR/backend/.env.example" "$ENV_FILE"
    # Generate a secure JWT secret automatically
    JWT_SECRET=$(openssl rand -hex 32)
    sed -i "s/CHANGE_THIS_TO_A_RANDOM_64_CHAR_STRING/$JWT_SECRET/" "$ENV_FILE"
    success "Generated .env with secure JWT secret"
else
    warn ".env already exists — skipping (not overwriting your config)"
fi

# Prompt for VPN host
echo ""
echo -e "${BOLD}Configure VPN Container Connection${NC}"
read -p "  OpenVPN container IP [10.10.0.1]: " VPN_IP
VPN_IP="${VPN_IP:-10.10.0.1}"
sed -i "s/VPN_HOST=.*/VPN_HOST=$VPN_IP/" "$ENV_FILE"

read -p "  Your server's public IP or domain (for OVPN files) [auto-detect]: " PUB_IP
if [[ -z "$PUB_IP" ]]; then
    PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")
fi
echo "VPN_PUBLIC_IP=$PUB_IP" >> "$ENV_FILE"
success "Environment configured (VPN host: $VPN_IP, Public IP: $PUB_IP)"

# ── TLS certificate ───────────────────────────────────────────
step "TLS Certificate"
SSL_DIR="/etc/ssl/openvpn-panel"
mkdir -p "$SSL_DIR"

if [[ ! -f "$SSL_DIR/cert.pem" ]]; then
    info "Generating self-signed TLS certificate..."
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -nodes -days 825 \
        -newkey rsa:4096 \
        -keyout "$SSL_DIR/key.pem" \
        -out "$SSL_DIR/cert.pem" \
        -subj "/CN=openvpn-panel/O=Internal/C=US" \
        -addext "subjectAltName=IP:${LOCAL_IP},IP:127.0.0.1" \
        2>/dev/null
    chmod 600 "$SSL_DIR/key.pem"
    success "Self-signed certificate created (IP: $LOCAL_IP)"
    warn "For production, replace with a real cert from Let's Encrypt"
else
    success "TLS certificate already exists"
fi

# ── Nginx ─────────────────────────────────────────────────────
step "Nginx Configuration"
cp "$INSTALL_DIR/nginx/openvpn-panel.conf" /etc/nginx/sites-available/openvpn-panel
ln -sf /etc/nginx/sites-available/openvpn-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t 2>/dev/null && success "Nginx config valid" || error "Nginx config test failed"
systemctl enable nginx --quiet
systemctl restart nginx
success "Nginx running"

# ── systemd service ───────────────────────────────────────────
step "Systemd Service"
cp "$INSTALL_DIR/systemd/openvpn-panel.service" /etc/systemd/system/
# Fix paths in service file
sed -i "s|/opt/openvpn-panel|$INSTALL_DIR|g" /etc/systemd/system/openvpn-panel.service
systemctl daemon-reload
systemctl enable openvpn-panel --quiet
systemctl restart openvpn-panel
sleep 2
if systemctl is-active --quiet openvpn-panel; then
    success "OpenVPN Panel service running"
else
    warn "Service may have issues. Check: journalctl -u openvpn-panel -n 30"
fi

# ── Fail2Ban ──────────────────────────────────────────────────
step "Fail2Ban Setup"
cat > /etc/fail2ban/jail.d/openvpn-panel.conf << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime  = 86400
findtime = 600
EOF
systemctl enable fail2ban --quiet
systemctl restart fail2ban
success "Fail2Ban configured"

# ── SSH key for VPN container ────────────────────────────────
step "SSH Key for VPN Container"
SSH_KEY="/root/.ssh/vpn_key"
if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    success "SSH key generated: $SSH_KEY"
else
    success "SSH key already exists: $SSH_KEY"
fi

# ── Firewall ──────────────────────────────────────────────────
step "Firewall (UFW)"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow 22/tcp   > /dev/null 2>&1
ufw allow 443/tcp  > /dev/null 2>&1
ufw allow 80/tcp   > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
success "Firewall enabled (22, 80, 443 open)"

# ── Done ─────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║         ✓  Installation Complete!                  ║"
echo "  ╚════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Web Panel:${NC}  https://${LOCAL_IP}"
echo -e "  ${BOLD}API:${NC}        https://${LOCAL_IP}/api"
echo ""
echo -e "  ${BOLD}Default login:${NC}"
echo -e "    admin  / admin123   (${RED}change immediately!${NC})"
echo -e "    ops    / ops123"
echo -e "    viewer / view123"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Copy SSH key to VPN container (CT-100):"
echo -e "     ${YELLOW}ssh-copy-id -i $SSH_KEY root@${VPN_IP}${NC}"
echo ""
echo -e "  2. Change default passwords in the Admin panel"
echo ""
echo -e "  3. Check service status:"
echo -e "     ${YELLOW}systemctl status openvpn-panel${NC}"
echo -e "     ${YELLOW}journalctl -u openvpn-panel -f${NC}"
echo ""
echo -e "  ${BOLD}Logs:${NC} journalctl -u openvpn-panel"
echo ""
