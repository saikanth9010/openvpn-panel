# OpenVPN Panel

A production-ready OpenVPN management web UI for Proxmox LXC, TP-Link compatible,
with RBAC, live TCPDump, and OVPN profile generation.

## One-Command Install

```bash
# Option A: pipe directly
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openvpn-panel/main/install.sh | bash

# Option B: clone first (recommended)
git clone https://github.com/YOUR_USER/openvpn-panel.git
cd openvpn-panel && chmod +x install.sh scripts/*.sh
sudo bash install.sh
```

### Flags
| Flag | Purpose |
|------|---------|
| `--vpn-only` | OpenVPN server only (CT-100) |
| `--panel-only` | Web panel only (CT-101) |
| `--dev` | HTTP on port 3000, no SSL |

## Two-Container Setup (Recommended)

```
CT-100  (--vpn-only)    10.10.0.1 on vmbr1
CT-101  (--panel-only)  10.10.0.2 on vmbr1
```

## Project Structure

```
openvpn-panel/
├── install.sh               ← Run this
├── scripts/
│   ├── install-vpn.sh
│   ├── install-panel.sh
│   ├── setup-firewall.sh
│   ├── setup-fail2ban.sh
│   └── gen-client.sh
├── backend/
│   ├── server.js            ← Express API + WebSocket
│   └── package.json
└── frontend/
    ├── src/App.jsx          ← Full React UI
    ├── src/api.js
    ├── vite.config.js
    └── package.json
```

## Updating

```bash
cd /opt/openvpn-panel && git pull
cd frontend && npm install && npm run build
systemctl restart openvpn-panel
```

## License

MIT
