#!/usr/bin/env bash
# scripts/setup-fail2ban.sh
set -euo pipefail

log()  { echo -e "\033[0;32m[✔]\033[0m $*"; }
info() { echo -e "\033[0;34m[→]\033[0m $*"; }

info "Configuring Fail2Ban..."

# Custom filter for panel login attempts
cat > /etc/fail2ban/filter.d/openvpn-panel.conf << 'FILTER'
[Definition]
failregex = ^.*\[AUTH_FAIL\].*ip=<HOST>.*$
ignoreregex =
FILTER

# Jail config
cat > /etc/fail2ban/jail.d/openvpn-panel.conf << 'JAIL'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400

[openvpn-panel]
enabled  = true
port     = 443,80,3000
filter   = openvpn-panel
logpath  = /opt/openvpn-panel/logs/app.log
maxretry = 5
bantime  = 3600
JAIL

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2Ban active"
