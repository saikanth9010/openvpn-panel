# OpenVPN Panel

A production-ready OpenVPN management web UI for Proxmox LXC containers,
TP-Link compatible, with RBAC, live TCPDump, and OVPN profile generation.

---

## Run on your Proxmox host — one command

```bash
# On the Proxmox HOST shell (not inside a container):
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openvpn-panel/main/proxmox-deploy.sh | bash
```

Or clone first (recommended):

```bash
git clone https://github.com/YOUR_USER/openvpn-panel.git
cd openvpn-panel && chmod +x proxmox-deploy.sh install.sh scripts/*.sh
bash proxmox-deploy.sh
```

The script runs **on the Proxmox host** and handles everything:
- Creates the LXC container(s) with the right flags
- Sets up networking and bridges
- Clones the repo into the container(s)
- Installs OpenVPN, builds the React frontend, configures Nginx and systemd
- Prints the final access URL

---

## What it asks you

| Prompt | Default | Notes |
|--------|---------|-------|
| Deployment mode | Single container | Choose 1 (single) or 2 (two containers) |
| Container ID(s) | Next free ID | Auto-detected |
| Container hostname(s) | openvpn-panel | |
| Disk / RAM / CPU | 8GB / 1024MB / 2 | |
| Container root password | — | Required |
| Network IP | DHCP | Or set a static IP e.g. 192.168.1.50/24 |
| Gateway | — | Required if using static IP |
| Bridge | vmbr0 | |
| Public IP or domain | Auto-detect | Used in .ovpn files |
| OpenVPN port | 1194 | |
| VPN subnet | 10.8.0.0 | |
| Panel port | 443 | |
| Cipher | AES-256-CBC | Chosen from a menu |
| Admin username | admin | Web panel login |
| Admin password | — | Required |
| GitHub repo URL | — | Your fork of this repo |

---

## Two-container setup

When you pick mode 2, the script creates:

```
Proxmox Host
├── vmbr0  — public network
├── vmbr1  — internal bridge (10.10.0.0/24, created automatically)
│
├── CT-A  openvpn-server   vmbr0 + vmbr1 (10.10.0.1)   [tun=1, unprivileged=0]
│    └── OpenVPN + Easy-RSA
│
└── CT-B  openvpn-panel    vmbr0 + vmbr1 (10.10.0.2)   [unprivileged=1]
     └── Node.js API + React UI + Nginx
```

SSH key auth is set up automatically between the two containers.

---

## Project Structure

```
openvpn-panel/
├── proxmox-deploy.sh        ← Run this on the Proxmox HOST
├── install.sh               ← Runs inside the container(s)
├── scripts/
│   ├── install-vpn.sh
│   ├── install-panel.sh
│   ├── setup-firewall.sh
│   ├── setup-fail2ban.sh
│   └── gen-client.sh
├── backend/
│   ├── server.js
│   └── package.json
└── frontend/
    ├── src/App.jsx
    ├── src/api.js
    ├── vite.config.js
    └── package.json
```

---

## Updating after deployment

```bash
# Enter the panel container
pct enter <CT_ID>

cd /opt/openvpn-panel
git pull
cd frontend && npm install && npm run build
systemctl restart openvpn-panel
```

## License

MIT
