import { api } from "./api.js";
import { useState, useEffect, useRef } from "react";

// ─── Mock Data ──────────────────────────────────────────────────────────────
const USERS_DB = {
  admin: { password: "admin123", role: "admin", name: "Admin", email: "admin@vpn.local" },
  ops: { password: "ops123", role: "operator", name: "Operator", email: "ops@vpn.local" },
  viewer: { password: "view123", role: "viewer", name: "Viewer", email: "viewer@vpn.local" },
};

const ROLE_PERMISSIONS = {
  admin:    ["dashboard","clients","generate","tcpdump","admin","logs"],
  operator: ["dashboard","clients","generate","logs"],
  viewer:   ["dashboard","clients"],
};

const TPLINK_CIPHERS = [
  { id: "AES-128-CBC",  label: "AES-128-CBC",  tag: "Recommended", desc: "Fast, TP-Link compatible" },
  { id: "AES-256-CBC",  label: "AES-256-CBC",  tag: "Most Secure", desc: "Max security, TP-Link supported" },
  { id: "AES-128-GCM",  label: "AES-128-GCM",  tag: "Modern",      desc: "AEAD, OpenVPN 2.4+" },
  { id: "AES-256-GCM",  label: "AES-256-GCM",  tag: "Modern+",     desc: "Strongest AEAD cipher" },
  { id: "BF-CBC",       label: "BF-CBC",       tag: "Legacy",      desc: "Blowfish – legacy devices" },
  { id: "DES-CBC",      label: "DES-CBC",       tag: "Deprecated",  desc: "Legacy only, not recommended" },
];

const MOCK_CLIENTS = [
  { id: 1, name: "iPhone-Alice",   ip: "10.8.0.2",  real: "203.0.113.10", since: "2h 14m",  rx: "142 MB", tx: "38 MB",  status: "connected" },
  { id: 2, name: "Laptop-Bob",     ip: "10.8.0.3",  real: "198.51.100.22",since: "45m",      rx: "890 MB", tx: "210 MB", status: "connected" },
  { id: 3, name: "Android-Carol",  ip: "10.8.0.4",  real: "192.0.2.55",   since: "12m",      rx: "33 MB",  tx: "9 MB",   status: "connected" },
  { id: 4, name: "MacBook-Dave",   ip: "10.8.0.5",  real: "203.0.113.99", since: "—",        rx: "—",      tx: "—",      status: "disconnected" },
];

const MOCK_OVPN_FILES = [
  { name: "alice-iphone",   cipher: "AES-256-CBC", pass: false, created: "2024-03-01" },
  { name: "bob-laptop",     cipher: "AES-128-GCM", pass: true,  created: "2024-03-03" },
  { name: "office-router",  cipher: "AES-128-CBC", pass: false, created: "2024-02-28" },
];

const MOCK_USERS = [
  { id: 1, username: "admin",  name: "Admin",    role: "admin",    status: "active" },
  { id: 2, username: "ops",    name: "Operator", role: "operator", status: "active" },
  { id: 3, username: "viewer", name: "Viewer",   role: "viewer",   status: "active" },
];

function generateOVPN(name, cipher, usePass, passphrase) {
  return `# OpenVPN Config – ${name}
# Generated: ${new Date().toISOString()}
# Cipher: ${cipher}

client
dev tun
proto udp
remote vpn.example.com 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${cipher}
verb 3
${usePass ? `# Passphrase protected\nask-pass` : "# No passphrase"}

<ca>
-----BEGIN CERTIFICATE-----
MIIBpDCCAUqgAwIBAgIUJQVxDemoCAcertificateHere...
-----END CERTIFICATE-----
</ca>

<cert>
-----BEGIN CERTIFICATE-----
MIIBpDCCAUqgAwIBAgIU${name}CertificateDataHere...
-----END CERTIFICATE-----
</cert>

<key>
-----BEGIN PRIVATE KEY-----
${usePass ? `# Encrypted with passphrase` : `# Unencrypted`}
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC...
-----END PRIVATE KEY-----
</key>

<tls-auth>
-----BEGIN OpenVPN Static key V1-----
e685bdaf659a25a200e2b9e39e51ff03...
-----END OpenVPN Static key V1-----
</tls-auth>`;
}

// ─── Icons ──────────────────────────────────────────────────────────────────
const Icon = ({ d, size = 16, className = "" }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none"
    stroke="currentColor" strokeWidth={1.8} strokeLinecap="round"
    strokeLinejoin="round" className={className}>
    <path d={d} />
  </svg>
);

const ICONS = {
  shield:   "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z",
  users:    "M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75M9 7a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
  download: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3",
  terminal: "M4 17l6-6-6-6M12 19h8",
  settings: "M12 20h9M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z",
  lock:     "M19 11H5a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2zM7 11V7a5 5 0 0 1 10 0v4",
  wifi:     "M5 12.55a11 11 0 0 1 14.08 0M1.42 9a16 16 0 0 1 21.16 0M8.53 16.11a6 6 0 0 1 6.95 0M12 20h.01",
  log:      "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M16 13H8M16 17H8M10 9H8",
  plus:     "M12 5v14M5 12h14",
  trash:    "M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
  eye:      "M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  logout:   "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9",
  stop:     "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0zM9 10h6v4H9z",
  play:     "M5 3l14 9-14 9V3z",
  grid:     "M3 3h7v7H3zM14 3h7v7h-7zM14 14h7v7h-7zM3 14h7v7H3z",
  chevron:  "M9 18l6-6-6-6",
};

// ─── Styles ─────────────────────────────────────────────────────────────────
const S = `
  @import url('https://fonts.googleapis.com/css2?family=Syne:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg0: #080c14;
    --bg1: #0d1420;
    --bg2: #111827;
    --bg3: #1a2235;
    --border: rgba(99,140,255,0.12);
    --border2: rgba(99,140,255,0.22);
    --accent: #3b82f6;
    --accent2: #60a5fa;
    --accent3: #93c5fd;
    --green: #22c55e;
    --red: #ef4444;
    --amber: #f59e0b;
    --purple: #a78bfa;
    --text0: #f1f5f9;
    --text1: #94a3b8;
    --text2: #64748b;
    --glow: 0 0 24px rgba(59,130,246,0.18);
    --glow2: 0 0 48px rgba(59,130,246,0.1);
    --radius: 10px;
    --font: 'Syne', sans-serif;
    --mono: 'JetBrains Mono', monospace;
  }

  body { background: var(--bg0); color: var(--text0); font-family: var(--font); min-height: 100vh; overflow-x: hidden; }

  .app { display: flex; min-height: 100vh; }

  /* ── Sidebar ── */
  .sidebar {
    width: 240px; min-height: 100vh; background: var(--bg1);
    border-right: 1px solid var(--border); display: flex; flex-direction: column;
    position: fixed; top: 0; left: 0; z-index: 100;
  }
  .sidebar-logo {
    padding: 24px 20px 20px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px;
  }
  .logo-icon {
    width: 36px; height: 36px; background: linear-gradient(135deg, var(--accent), var(--purple));
    border-radius: 8px; display: flex; align-items: center; justify-content: center;
    box-shadow: 0 0 16px rgba(59,130,246,0.4);
  }
  .logo-text { font-size: 17px; font-weight: 800; letter-spacing: -0.3px; }
  .logo-text span { color: var(--accent2); }

  .sidebar-nav { flex: 1; padding: 16px 12px; display: flex; flex-direction: column; gap: 2px; }
  .nav-item {
    display: flex; align-items: center; gap: 10px; padding: 10px 12px;
    border-radius: 8px; cursor: pointer; color: var(--text1); font-size: 13.5px;
    font-weight: 500; transition: all 0.15s; border: 1px solid transparent;
    text-transform: uppercase; letter-spacing: 0.5px; font-size: 12px;
  }
  .nav-item:hover { background: var(--bg3); color: var(--text0); }
  .nav-item.active { background: rgba(59,130,246,0.12); color: var(--accent2); border-color: rgba(59,130,246,0.2); }
  .nav-item.active svg { filter: drop-shadow(0 0 6px var(--accent)); }
  .nav-section { font-size: 10px; font-weight: 700; color: var(--text2); letter-spacing: 1.5px; padding: 16px 12px 6px; text-transform: uppercase; }
  .nav-badge { margin-left: auto; background: var(--accent); color: white; font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: 99px; }

  .sidebar-user {
    padding: 16px; border-top: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px;
  }
  .user-avatar {
    width: 32px; height: 32px; border-radius: 8px;
    background: linear-gradient(135deg, var(--accent), var(--purple));
    display: flex; align-items: center; justify-content: center;
    font-size: 13px; font-weight: 700; flex-shrink: 0;
  }
  .user-info { flex: 1; overflow: hidden; }
  .user-name { font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .user-role { font-size: 11px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.5px; }
  .logout-btn { color: var(--text2); cursor: pointer; padding: 4px; border-radius: 4px; transition: color 0.15s; }
  .logout-btn:hover { color: var(--red); }

  /* ── Main ── */
  .main { margin-left: 240px; flex: 1; display: flex; flex-direction: column; min-height: 100vh; }

  .topbar {
    background: var(--bg1); border-bottom: 1px solid var(--border);
    padding: 16px 28px; display: flex; align-items: center; justify-content: space-between;
    position: sticky; top: 0; z-index: 50;
  }
  .topbar-title { font-size: 20px; font-weight: 800; letter-spacing: -0.3px; }
  .topbar-title span { color: var(--text2); font-weight: 400; font-size: 14px; margin-left: 8px; }
  .topbar-right { display: flex; align-items: center; gap: 12px; }

  .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); box-shadow: 0 0 8px var(--green); animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.5} }
  .status-label { font-size: 12px; color: var(--green); font-weight: 600; display: flex; align-items: center; gap: 6px; }

  .page { padding: 28px; flex: 1; }

  /* ── Cards ── */
  .card {
    background: var(--bg2); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 20px; transition: border-color 0.2s;
  }
  .card:hover { border-color: var(--border2); }
  .card-title { font-size: 11px; font-weight: 700; color: var(--text2); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }

  .stat-grid { display: grid; grid-template-columns: repeat(4,1fr); gap: 16px; margin-bottom: 24px; }
  .stat-card {
    background: var(--bg2); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 18px 20px; position: relative; overflow: hidden;
  }
  .stat-card::before {
    content:''; position:absolute; top:0; left:0; right:0; height:2px;
    background: linear-gradient(90deg, var(--accent), var(--purple));
  }
  .stat-label { font-size: 11px; color: var(--text2); font-weight: 600; text-transform: uppercase; letter-spacing: 0.8px; }
  .stat-value { font-size: 32px; font-weight: 800; letter-spacing: -1px; margin: 6px 0 2px; }
  .stat-sub { font-size: 11px; color: var(--text1); }
  .stat-icon { position: absolute; right: 16px; top: 50%; transform: translateY(-50%); opacity: 0.08; }

  /* ── Table ── */
  .table-wrap { overflow-x: auto; border-radius: var(--radius); }
  table { width: 100%; border-collapse: collapse; }
  thead tr { border-bottom: 1px solid var(--border); }
  th { font-size: 10px; font-weight: 700; color: var(--text2); text-transform: uppercase; letter-spacing: 1px; padding: 10px 14px; text-align: left; white-space: nowrap; }
  td { padding: 12px 14px; font-size: 13px; color: var(--text0); border-bottom: 1px solid rgba(99,140,255,0.06); white-space: nowrap; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(59,130,246,0.04); }

  .badge {
    display: inline-flex; align-items: center; gap: 4px;
    padding: 3px 8px; border-radius: 99px; font-size: 11px; font-weight: 600;
    text-transform: uppercase; letter-spacing: 0.4px;
  }
  .badge-green { background: rgba(34,197,94,0.12); color: var(--green); }
  .badge-red   { background: rgba(239,68,68,0.12); color: var(--red); }
  .badge-blue  { background: rgba(59,130,246,0.12); color: var(--accent2); }
  .badge-amber { background: rgba(245,158,11,0.12); color: var(--amber); }
  .badge-purple{ background: rgba(167,139,250,0.12); color: var(--purple); }
  .badge-gray  { background: rgba(100,116,139,0.12); color: var(--text2); }

  /* ── Form ── */
  .form-group { margin-bottom: 18px; }
  label { display: block; font-size: 11px; font-weight: 700; color: var(--text2); text-transform: uppercase; letter-spacing: 0.8px; margin-bottom: 7px; }
  input[type=text], input[type=password], select {
    width: 100%; background: var(--bg3); border: 1px solid var(--border);
    border-radius: 8px; padding: 10px 14px; color: var(--text0);
    font-family: var(--font); font-size: 14px; outline: none; transition: border-color 0.15s;
  }
  input[type=text]:focus, input[type=password]:focus, select:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(59,130,246,0.1); }
  select option { background: var(--bg2); }

  .btn {
    display: inline-flex; align-items: center; gap: 7px;
    padding: 9px 18px; border-radius: 8px; font-family: var(--font);
    font-size: 13px; font-weight: 600; cursor: pointer; border: none;
    transition: all 0.15s; text-transform: uppercase; letter-spacing: 0.5px; white-space: nowrap;
  }
  .btn-primary { background: var(--accent); color: white; }
  .btn-primary:hover { background: var(--accent2); box-shadow: 0 0 16px rgba(59,130,246,0.3); }
  .btn-ghost { background: transparent; color: var(--text1); border: 1px solid var(--border); }
  .btn-ghost:hover { background: var(--bg3); color: var(--text0); border-color: var(--border2); }
  .btn-danger { background: rgba(239,68,68,0.1); color: var(--red); border: 1px solid rgba(239,68,68,0.2); }
  .btn-danger:hover { background: var(--red); color: white; }
  .btn-green { background: rgba(34,197,94,0.1); color: var(--green); border: 1px solid rgba(34,197,94,0.2); }
  .btn-green:hover { background: var(--green); color: white; }
  .btn-sm { padding: 6px 12px; font-size: 11px; }

  .toggle-wrap { display: flex; align-items: center; gap: 10px; cursor: pointer; }
  .toggle {
    width: 42px; height: 24px; border-radius: 99px; border: 1px solid var(--border);
    background: var(--bg3); position: relative; transition: all 0.2s; flex-shrink: 0;
  }
  .toggle.on { background: var(--accent); border-color: var(--accent); }
  .toggle::after {
    content:''; position:absolute; top:3px; left:3px;
    width:16px; height:16px; border-radius:50%; background:white;
    transition: transform 0.2s; box-shadow: 0 1px 4px rgba(0,0,0,0.3);
  }
  .toggle.on::after { transform: translateX(18px); }
  .toggle-label { font-size: 13px; color: var(--text1); }

  /* ── Terminal ── */
  .terminal {
    background: #060a10; border: 1px solid var(--border); border-radius: var(--radius);
    font-family: var(--mono); font-size: 12.5px; color: #7ee787;
    padding: 16px; min-height: 320px; max-height: 520px; overflow-y: auto;
    line-height: 1.7; position: relative;
  }
  .terminal::-webkit-scrollbar { width: 4px; }
  .terminal::-webkit-scrollbar-track { background: transparent; }
  .terminal::-webkit-scrollbar-thumb { background: var(--bg3); border-radius: 2px; }
  .terminal-line { display: block; animation: fadein 0.1s ease; }
  .terminal-line.warn { color: #f59e0b; }
  .terminal-line.info { color: #60a5fa; }
  .terminal-line.meta { color: #64748b; }
  @keyframes fadein { from{opacity:0;transform:translateY(2px)} to{opacity:1;transform:translateY(0)} }
  .terminal-cursor { display: inline-block; width: 8px; height: 14px; background: #7ee787; animation: blink 1s infinite; vertical-align: middle; }
  @keyframes blink { 0%,49%{opacity:1} 50%,100%{opacity:0} }

  .tcpdump-controls { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }

  /* ── Login ── */
  .login-page {
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: var(--bg0); position: relative; overflow: hidden;
  }
  .login-bg {
    position: absolute; inset: 0; background:
      radial-gradient(ellipse 80% 60% at 20% 30%, rgba(59,130,246,0.06) 0%, transparent 60%),
      radial-gradient(ellipse 60% 50% at 80% 70%, rgba(167,139,250,0.05) 0%, transparent 60%);
  }
  .login-grid {
    position: absolute; inset: 0; opacity: 0.03;
    background-image: linear-gradient(var(--border) 1px, transparent 1px),
      linear-gradient(90deg, var(--border) 1px, transparent 1px);
    background-size: 48px 48px;
  }
  .login-box {
    position: relative; width: 420px; background: var(--bg1);
    border: 1px solid var(--border); border-radius: 16px; padding: 40px;
    box-shadow: 0 0 60px rgba(59,130,246,0.08), 0 32px 64px rgba(0,0,0,0.4);
  }
  .login-logo { display: flex; align-items: center; justify-content: center; gap: 12px; margin-bottom: 32px; }
  .login-logo-icon {
    width: 48px; height: 48px; background: linear-gradient(135deg, var(--accent), var(--purple));
    border-radius: 12px; display: flex; align-items: center; justify-content: center;
    box-shadow: 0 0 24px rgba(59,130,246,0.4);
  }
  .login-title { font-size: 26px; font-weight: 800; letter-spacing: -0.5px; }
  .login-title span { color: var(--accent2); }
  .login-sub { text-align: center; color: var(--text2); font-size: 13px; margin-bottom: 28px; }
  .error-msg { background: rgba(239,68,68,0.08); border: 1px solid rgba(239,68,68,0.2); border-radius: 8px; padding: 10px 14px; color: var(--red); font-size: 13px; margin-bottom: 16px; }

  /* ── Two-col layout ── */
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  .col-span2 { grid-column: span 2; }

  /* ── Cipher grid ── */
  .cipher-grid { display: grid; grid-template-columns: repeat(3,1fr); gap: 10px; }
  .cipher-card {
    background: var(--bg3); border: 1px solid var(--border); border-radius: 8px;
    padding: 12px 14px; cursor: pointer; transition: all 0.15s; position: relative;
  }
  .cipher-card:hover { border-color: var(--border2); }
  .cipher-card.selected { border-color: var(--accent); background: rgba(59,130,246,0.08); }
  .cipher-name { font-size: 13px; font-weight: 700; margin-bottom: 2px; }
  .cipher-desc { font-size: 11px; color: var(--text2); }
  .cipher-badge { position: absolute; top: 8px; right: 8px; }

  /* ── Modals ── */
  .modal-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.7); z-index: 200;
    display: flex; align-items: center; justify-content: center; padding: 20px;
    backdrop-filter: blur(4px);
  }
  .modal {
    background: var(--bg2); border: 1px solid var(--border2); border-radius: 14px;
    padding: 28px; width: 100%; max-width: 520px; max-height: 90vh; overflow-y: auto;
    box-shadow: 0 0 60px rgba(0,0,0,0.5);
  }
  .modal-title { font-size: 18px; font-weight: 800; margin-bottom: 20px; }
  .modal-footer { display: flex; justify-content: flex-end; gap: 10px; margin-top: 24px; }

  .ovpn-preview {
    background: #060a10; border: 1px solid var(--border); border-radius: 8px;
    padding: 14px; font-family: var(--mono); font-size: 11.5px; color: #7ee787;
    max-height: 260px; overflow-y: auto; line-height: 1.6; white-space: pre; margin-top: 14px;
  }

  .divider { height: 1px; background: var(--border); margin: 20px 0; }
  .section-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
  .section-title { font-size: 16px; font-weight: 700; }

  .empty { text-align: center; padding: 40px; color: var(--text2); font-size: 13px; }

  .tag-rec   { font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; background:rgba(34,197,94,0.1); color:var(--green); }
  .tag-sec   { font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; background:rgba(59,130,246,0.1); color:var(--accent2); }
  .tag-mod   { font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; background:rgba(167,139,250,0.1); color:var(--purple); }
  .tag-leg   { font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; background:rgba(245,158,11,0.1); color:var(--amber); }
  .tag-dep   { font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; background:rgba(239,68,68,0.1); color:var(--red); }
`;

const CIPHER_TAG = { Recommended: "tag-rec", "Most Secure": "tag-sec", Modern: "tag-mod", "Modern+": "tag-mod", Legacy: "tag-leg", Deprecated: "tag-dep" };

// ─── Login ──────────────────────────────────────────────────────────────────
function Login({ onLogin }) {
  const [u, setU] = useState(""); const [p, setP] = useState(""); const [err, setErr] = useState(""); const [loading, setLoading] = useState(false);
  const submit = async () => {
    if (!u || !p) return;
    setLoading(true); setErr("");
    try {
      const data = await api.login(u, p);
      onLogin(data.user);
    } catch (e) { setErr(e.message || "Invalid credentials"); }
    finally { setLoading(false); }
  };
  return (
    <div className="login-page">
      <div className="login-bg" /><div className="login-grid" />
      <div className="login-box">
        <div className="login-logo">
          <div className="login-logo-icon"><Icon d={ICONS.shield} size={26} /></div>
          <div className="login-title">Open<span>VPN</span> Panel</div>
        </div>
        <div className="login-sub">Proxmox Container • TP-Link Compatible</div>
        {err && <div className="error-msg">{err}</div>}
        <div className="form-group">
          <label>Username</label>
          <input type="text" value={u} onChange={e => setU(e.target.value)} onKeyDown={e => e.key === "Enter" && submit()} placeholder="admin" />
        </div>
        <div className="form-group" style={{ marginBottom: 24 }}>
          <label>Password</label>
          <input type="password" value={p} onChange={e => setP(e.target.value)} onKeyDown={e => e.key === "Enter" && submit()} placeholder="••••••••" />
        </div>
        <button className="btn btn-primary" style={{ width: "100%", justifyContent: "center", padding: "12px" }} onClick={submit} disabled={loading}>
          <Icon d={ICONS.lock} size={15} /> {loading ? "Signing in..." : "Sign In"}
        </button>
        <div style={{ marginTop: 20, padding: "12px", background: "rgba(59,130,246,0.04)", borderRadius: 8, border: "1px solid var(--border)", fontSize: 12, color: "var(--text2)", lineHeight: 1.7 }}>
          <b style={{ color: "var(--text1)" }}>Demo accounts:</b><br />
          admin / admin123 — Full access<br />
          ops / ops123 — Operator<br />
          viewer / view123 — Read only
        </div>
      </div>
    </div>
  );
}

// ─── Dashboard ──────────────────────────────────────────────────────────────
function Dashboard() {
  const [clients, setClients] = useState([]);
  const [profiles, setProfiles] = useState([]);
  const [status, setStatus] = useState({ running: false });
  useEffect(() => {
    api.clients().then(setClients).catch(() => {});
    api.profiles().then(setProfiles).catch(() => {});
    api.status().then(setStatus).catch(() => {});
  }, []);
  const connected = clients.filter(c => c.status === "connected").length;
  return (
    <div>
      <div className="stat-grid">
        {[
          { label: "Connected", value: connected, sub: "active tunnels", icon: ICONS.wifi, color: "var(--green)" },
          { label: "Total Clients", value: clients.length, sub: "registered", icon: ICONS.users, color: "var(--accent2)" },
          { label: "OVPN Files", value: profiles.length, sub: "profiles saved", icon: ICONS.log, color: "var(--purple)" },
          { label: "Server", value: status.running ? "Online" : "Offline", sub: status.host || "—", icon: ICONS.shield, color: status.running ? "var(--green)" : "var(--red)" },
        ].map(s => (
          <div key={s.label} className="stat-card">
            <div className="stat-label">{s.label}</div>
            <div className="stat-value" style={{ color: s.color }}>{s.value}</div>
            <div className="stat-sub">{s.sub}</div>
            <div className="stat-icon"><Icon d={s.icon} size={64} /></div>
          </div>
        ))}
      </div>
      <div className="grid2">
        <div className="card">
          <div className="card-title">Server Status</div>
          {[
            ["Process", <span className="badge badge-green">Running</span>],
            ["Protocol", "UDP / 1194"],
            ["Cipher", "AES-256-GCM"],
            ["Auth", "SHA-256"],
            ["TLS Version", "TLSv1.3"],
            ["Subnet", "10.8.0.0/24"],
            ["DNS", "1.1.1.1, 8.8.8.8"],
            ["TP-Link Mode", <span className="badge badge-blue">Compatible</span>],
          ].map(([k, v]) => (
            <div key={k} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 0", borderBottom: "1px solid rgba(99,140,255,0.06)", fontSize: 13 }}>
              <span style={{ color: "var(--text2)" }}>{k}</span>
              <span style={{ fontWeight: 600 }}>{v}</span>
            </div>
          ))}
        </div>
        <div className="card">
          <div className="card-title">Live Connections</div>
          {clients.filter(c => c.status === "connected").map((c, i) => (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 0", borderBottom: "1px solid rgba(99,140,255,0.06)" }}>
              <div style={{ width: 8, height: 8, borderRadius: "50%", background: "var(--green)", boxShadow: "0 0 6px var(--green)", flexShrink: 0 }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 13, fontWeight: 600 }}>{c.name}</div>
                <div style={{ fontSize: 11, color: "var(--text2)" }}>{c.vpnIp} • {c.since}</div>
              </div>
              <div style={{ fontSize: 11, color: "var(--text2)", textAlign: "right" }}>
                ↓{c.rx}<br />↑{c.tx}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Clients ────────────────────────────────────────────────────────────────
function Clients() {
  const [clients, setClients] = useState([]);
  const [loading, setLoading] = useState(true);
  const refresh = () => { setLoading(true); api.clients().then(d => { setClients(d); setLoading(false); }).catch(() => setLoading(false)); };
  useEffect(() => { refresh(); }, []);
  return (
    <div>
      <div className="section-header">
        <div className="section-title">Connected Devices</div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <div className="status-label"><div className="status-dot" />Live</div>
          <button className="btn btn-ghost btn-sm"><Icon d={ICONS.grid} size={12} />Refresh</button>
        </div>
      </div>
      <div className="card" style={{ padding: 0, overflow: "hidden" }}>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Status</th><th>Client Name</th><th>VPN IP</th><th>Real IP</th>
                <th>Connected For</th><th>Downloaded</th><th>Uploaded</th><th>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? <tr><td colSpan={8} style={{ textAlign: "center", padding: 24, color: "var(--text2)" }}>Loading...</td></tr> :
              clients.map((c, i) => (
                <tr key={i}>
                  <td>
                    <span className={`badge badge-${c.status === "connected" ? "green" : "gray"}`}>
                      <span style={{ width: 6, height: 6, borderRadius: "50%", background: c.status === "connected" ? "var(--green)" : "var(--text2)", display: "inline-block" }} />
                      {c.status}
                    </span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{c.name}</td>
                  <td style={{ fontFamily: "var(--mono)", fontSize: 12 }}>{c.vpnIp}</td>
                  <td style={{ fontFamily: "var(--mono)", fontSize: 12 }}>{c.realIp}</td>
                  <td>{c.since}</td>
                  <td style={{ color: "var(--accent2)" }}>{c.rx}</td>
                  <td style={{ color: "var(--purple)" }}>{c.tx}</td>
                  <td>
                    {c.status === "connected" && (
                      <button className="btn btn-danger btn-sm" onClick={() => api.disconnect(c.name).then(refresh)}>Disconnect</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// ─── Generate ────────────────────────────────────────────────────────────────
function Generate({ onSave }) {
  const [name, setName] = useState("");
  const [cipher, setCipher] = useState("AES-256-CBC");
  const [usePass, setUsePass] = useState(false);
  const [passphrase, setPassphrase] = useState("");
  const [saved, setSaved] = useState([]);
  const [loading, setLoading] = useState(false);
  const [genError, setGenError] = useState("");

  useEffect(() => { api.profiles().then(setSaved).catch(() => {}); }, []);

  const handleGen = async () => {
    if (!name.trim()) return;
    setLoading(true); setGenError("");
    try {
      await api.generate({ name: name.trim(), cipher, usePass, passphrase });
      const updated = await api.profiles();
      setSaved(updated);
      setName(""); setPassphrase("");
    } catch (e) { setGenError(e.message); }
    finally { setLoading(false); }
  };

  return (
    <div>
      <div className="grid2">
        <div className="card">
          <div className="card-title">Generate OVPN Profile</div>
          {genError && <div style={{ background: "rgba(239,68,68,0.08)", border: "1px solid rgba(239,68,68,0.2)", borderRadius: 8, padding: "10px 14px", color: "var(--red)", fontSize: 13, marginBottom: 14 }}>{genError}</div>}
          <div className="form-group">
            <label>Profile Name</label>
            <input type="text" value={name} onChange={e => setName(e.target.value)} placeholder="e.g. john-iphone" />
          </div>
          <div className="form-group">
            <label>TP-Link Compatible Cipher</label>
            <div className="cipher-grid">
              {TPLINK_CIPHERS.map(c => (
                <div key={c.id} className={`cipher-card ${cipher === c.id ? "selected" : ""}`} onClick={() => setCipher(c.id)}>
                  <div className="cipher-badge"><span className={CIPHER_TAG[c.tag]}>{c.tag}</span></div>
                  <div className="cipher-name">{c.label}</div>
                  <div className="cipher-desc">{c.desc}</div>
                </div>
              ))}
            </div>
          </div>
          <div className="form-group">
            <label>Passphrase Protection</label>
            <div className="toggle-wrap" onClick={() => setUsePass(v => !v)}>
              <div className={`toggle ${usePass ? "on" : ""}`} />
              <span className="toggle-label">{usePass ? "Password Protected" : "No Password (nopass)"}</span>
            </div>
          </div>
          {usePass && (
            <div className="form-group">
              <label>Passphrase</label>
              <input type="password" value={passphrase} onChange={e => setPassphrase(e.target.value)} placeholder="Enter passphrase..." />
            </div>
          )}
          <button className="btn btn-primary" onClick={handleGen} disabled={!name.trim() || loading}>
            <Icon d={ICONS.shield} size={14} />{loading ? "Generating..." : "Generate & Download"}
          </button>
        </div>
        <div className="card">
          <div className="card-title">Saved Profiles</div>
          {saved.length === 0 && <div className="empty">No profiles yet</div>}
          {saved.map((f, i) => (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 0", borderBottom: "1px solid rgba(99,140,255,0.06)" }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 13, fontWeight: 600, fontFamily: "var(--mono)" }}>{f.name}.ovpn</div>
                <div style={{ fontSize: 11, color: "var(--text2)", marginTop: 2 }}>
                  {f.cipher} • {f.pass ? "🔐 Pass" : "🔓 Nopass"} • {f.created}
                </div>
              </div>
              <button className="btn btn-ghost btn-sm" onClick={() => api.generate({ name: f.name, cipher: f.cipher, usePass: f.pass, passphrase: "" })}>
                <Icon d={ICONS.download} size={12} />
              </button>
              <button className="btn btn-danger btn-sm" onClick={() => api.deleteProfile(f.name).then(() => setSaved(s => s.filter((_, j) => j !== i)))}>
                <Icon d={ICONS.trash} size={12} />
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── TCPDump ────────────────────────────────────────────────────────────────
function TCPDump() {
  const [running, setRunning] = useState(false);
  const [lines, setLines] = useState([]);
  const [iface, setIface] = useState("tun0");
  const [filter, setFilter] = useState("");
  const termRef = useRef(null);
  const wsRef = useRef(null);

  const start = () => {
    setLines([]); setRunning(true);
    const ws = api.tcpdumpWs(iface, filter);
    wsRef.current = ws;
    ws.onmessage = e => {
      const line = String(e.data);
      const cls = line.includes("WARNING") || line.includes("error") ? "warn"
                : line.includes("tcpdump:") ? "meta" : "";
      setLines(prev => [...prev, [cls, line]]);
      setTimeout(() => { if (termRef.current) termRef.current.scrollTop = termRef.current.scrollHeight; }, 10);
    };
    ws.onclose = () => setRunning(false);
    ws.onerror = () => { setRunning(false); setLines(prev => [...prev, ["warn", "[error] Could not connect to VPN host"]]); };
  };

  const stop = () => {
    if (wsRef.current) { wsRef.current.close(); wsRef.current = null; }
    setRunning(false);
  };

  useEffect(() => () => stop(), []);

  return (
    <div>
      <div className="section-header">
        <div className="section-title">TCPDump Live Capture</div>
        <span className={`badge ${running ? "badge-green" : "badge-gray"}`}>{running ? "Capturing" : "Idle"}</span>
      </div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: "flex", gap: 12, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div style={{ flex: "0 0 140px" }}>
            <label style={{ display: "block", fontSize: 11, fontWeight: 700, color: "var(--text2)", textTransform: "uppercase", letterSpacing: "0.8px", marginBottom: 7 }}>Interface</label>
            <select value={iface} onChange={e => setIface(e.target.value)}>
              <option>tun0</option><option>eth0</option><option>eth1</option><option>any</option>
            </select>
          </div>
          <div style={{ flex: 1 }}>
            <label style={{ display: "block", fontSize: 11, fontWeight: 700, color: "var(--text2)", textTransform: "uppercase", letterSpacing: "0.8px", marginBottom: 7 }}>BPF Filter (optional)</label>
            <input type="text" value={filter} onChange={e => setFilter(e.target.value)} placeholder="e.g. port 443 or host 10.8.0.2" />
          </div>
          <div className="tcpdump-controls">
            {!running
              ? <button className="btn btn-green" onClick={start}><Icon d={ICONS.play} size={14} />Start Capture</button>
              : <button className="btn btn-danger" onClick={stop}><Icon d={ICONS.stop} size={14} />Stop Capture</button>
            }
            <button className="btn btn-ghost" onClick={() => setLines([])}><Icon d={ICONS.trash} size={14} />Clear</button>
          </div>
        </div>
      </div>
      <div ref={termRef} className="terminal">
        {lines.length === 0 && !running && <span style={{ color: "var(--text2)" }}># Click "Start Capture" to begin live packet inspection...</span>}
        {lines.map((l, i) => <span key={i} className={`terminal-line ${l[0]}`}>{l[1]}<br /></span>)}
        {running && <span className="terminal-cursor" />}
      </div>
      <div style={{ marginTop: 10, fontSize: 12, color: "var(--text2)", display: "flex", gap: 16 }}>
        <span>Interface: <b style={{ color: "var(--text1)" }}>{iface}</b></span>
        <span>Packets: <b style={{ color: "var(--accent2)" }}>{lines.length}</b></span>
        {filter && <span>Filter: <b style={{ color: "var(--amber)", fontFamily: "var(--mono)" }}>{filter}</b></span>}
      </div>
    </div>
  );
}

// ─── Admin Panel ─────────────────────────────────────────────────────────────
function Admin() {
  const [users, setUsers] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [newUser, setNewUser] = useState({ username: "", name: "", role: "viewer", password: "" });
  const [editId, setEditId] = useState(null);
  const [err, setErr] = useState("");

  const loadUsers = () => api.users().then(setUsers).catch(() => {});
  useEffect(() => { loadUsers(); }, []);

  const addUser = async () => {
    if (!newUser.username || !newUser.name || !newUser.password) return;
    setErr("");
    try {
      await api.createUser(newUser);
      setNewUser({ username: "", name: "", role: "viewer", password: "" });
      setShowAdd(false);
      loadUsers();
    } catch (e) { setErr(e.message); }
  };

  const updateUser = async (id, patch) => {
    try { await api.updateUser(id, patch); loadUsers(); } catch {}
  };
  const deleteUser = async (id) => {
    if (!confirm("Delete this user?")) return;
    try { await api.deleteUser(id); loadUsers(); } catch {}
  };

  return (
    <div>
      <div className="section-header">
        <div className="section-title">RBAC — User Management</div>
        <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(true)}>
          <Icon d={ICONS.plus} size={14} />Add User
        </button>
      </div>

      <div className="card" style={{ marginBottom: 20, padding: 0, overflow: "hidden" }}>
        <table>
          <thead>
            <tr><th>Username</th><th>Name</th><th>Role</th><th>Permissions</th><th>Status</th><th>Actions</th></tr>
          </thead>
          <tbody>
            {users.map(u => (
              <tr key={u.id}>
                <td style={{ fontFamily: "var(--mono)", fontSize: 13 }}>{u.username}</td>
                <td style={{ fontWeight: 600 }}>{u.name}</td>
                <td>
                  <span className={`badge ${u.role === "admin" ? "badge-blue" : u.role === "operator" ? "badge-purple" : "badge-gray"}`}>{u.role}</span>
                </td>
                <td>
                  <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                    {ROLE_PERMISSIONS[u.role]?.map(p => (
                      <span key={p} style={{ fontSize: 10, padding: "2px 6px", background: "rgba(99,140,255,0.08)", border: "1px solid var(--border)", borderRadius: 4, color: "var(--text1)", textTransform: "uppercase", letterSpacing: "0.4px" }}>{p}</span>
                    ))}
                  </div>
                </td>
                <td><span className={`badge badge-${u.status === "active" ? "green" : "gray"}`}>{u.status}</span></td>
                <td>
                  <div style={{ display: "flex", gap: 6 }}>
                    <button className="btn btn-ghost btn-sm" onClick={() => setEditId(editId === u.id ? null : u.id)}>
                      <Icon d={ICONS.settings} size={12} />
                    </button>
                    {u.username !== "admin" && (
                      <button className="btn btn-danger btn-sm" onClick={() => deleteUser(u.id)}>
                        <Icon d={ICONS.trash} size={12} />
                      </button>
                    )}
                    <button className="btn btn-ghost btn-sm" onClick={() => updateUser(u.id, { status: u.status === "active" ? "suspended" : "active" })}>
                      {u.status === "active" ? "Suspend" : "Activate"}
                    </button>
                  </div>
                  {editId === u.id && (
                    <div style={{ marginTop: 10, padding: 12, background: "var(--bg3)", borderRadius: 8, border: "1px solid var(--border)" }}>
                      <label style={{ display: "block", fontSize: 11, fontWeight: 700, color: "var(--text2)", textTransform: "uppercase", letterSpacing: "0.8px", marginBottom: 7 }}>Change Role</label>
                      <select value={u.role} onChange={e => updateUser(u.id, { role: e.target.value })} style={{ width: "100%" }}>
                        <option value="admin">Admin</option>
                        <option value="operator">Operator</option>
                        <option value="viewer">Viewer</option>
                      </select>
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="grid2">
        {["admin","operator","viewer"].map(role => (
          <div key={role} className="card">
            <div className="card-title">{role} — Permissions</div>
            {["dashboard","clients","generate","tcpdump","admin","logs"].map(p => {
              const allowed = ROLE_PERMISSIONS[role]?.includes(p);
              return (
                <div key={p} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "7px 0", borderBottom: "1px solid rgba(99,140,255,0.06)", fontSize: 13 }}>
                  <span style={{ textTransform: "capitalize", color: "var(--text1)" }}>{p}</span>
                  <span style={{ color: allowed ? "var(--green)" : "var(--red)", fontSize: 12, fontWeight: 700 }}>{allowed ? "✓ Allowed" : "✗ Denied"}</span>
                </div>
              );
            })}
          </div>
        ))}
      </div>

      {showAdd && (
        <div className="modal-overlay" onClick={() => setShowAdd(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-title">Add New User</div>
            {[["Username", "username", "text", "jdoe"], ["Display Name", "name", "text", "John Doe"], ["Password", "password", "password", "••••••••"]].map(([label, key, type, ph]) => (
              <div className="form-group" key={key}>
                <label>{label}</label>
                <input type={type} value={newUser[key]} onChange={e => setNewUser(u => ({ ...u, [key]: e.target.value }))} placeholder={ph} />
              </div>
            ))}
            <div className="form-group">
              <label>Role</label>
              <select value={newUser.role} onChange={e => setNewUser(u => ({ ...u, role: e.target.value }))}>
                <option value="admin">Admin — Full Access</option>
                <option value="operator">Operator — Manage + Generate</option>
                <option value="viewer">Viewer — Read Only</option>
              </select>
            </div>
            <div style={{ fontSize: 12, color: "var(--text2)", marginBottom: 16, padding: "10px", background: "rgba(59,130,246,0.04)", borderRadius: 8, border: "1px solid var(--border)" }}>
              <b style={{ color: "var(--text1)" }}>Permissions for {newUser.role}:</b> {ROLE_PERMISSIONS[newUser.role]?.join(", ")}
            </div>
            <div className="modal-footer">
              <button className="btn btn-ghost" onClick={() => setShowAdd(false)}>Cancel</button>
              <button className="btn btn-primary" onClick={addUser}><Icon d={ICONS.plus} size={14} />Create User</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Logs ────────────────────────────────────────────────────────────────────
function Logs() {
  const [entries, setEntries] = useState([]);
  useEffect(() => { api.logs().then(setEntries).catch(() => {}); }, []);
  const color = { INFO: "badge-blue", WARN: "badge-amber", ERROR: "badge-red" };
  return (
    <div>
      <div className="section-header"><div className="section-title">System Logs</div></div>
      <div className="card" style={{ padding: 0, overflow: "hidden" }}>
        <table>
          <thead><tr><th>Time</th><th>Level</th><th>Message</th></tr></thead>
          <tbody>
            {entries.map((e, i) => (
              <tr key={i}>
                <td style={{ fontFamily: "var(--mono)", fontSize: 12, color: "var(--text2)" }}>{e.time}</td>
                <td><span className={`badge ${color[e.level] || "badge-blue"}`}>{e.level}</span></td>
                <td style={{ fontFamily: "var(--mono)", fontSize: 12 }}>{e.message}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─── App ─────────────────────────────────────────────────────────────────────
const NAV = [
  { id: "dashboard", label: "Dashboard",    icon: ICONS.grid,     section: "monitor" },
  { id: "clients",   label: "Clients",      icon: ICONS.users,    section: "monitor" },
  { id: "generate",  label: "Generate",     icon: ICONS.shield,   section: "config" },
  { id: "tcpdump",   label: "TCPDump",      icon: ICONS.terminal, section: "tools" },
  { id: "logs",      label: "Logs",         icon: ICONS.log,      section: "tools" },
  { id: "admin",     label: "Admin",        icon: ICONS.settings, section: "admin" },
];

const PAGE_TITLES = { dashboard: "Dashboard", clients: "Connected Devices", generate: "Generate OVPN", tcpdump: "Packet Capture", logs: "System Logs", admin: "Admin Panel" };

export default function App() {
  const [user, setUser] = useState(null);
  const [page, setPage] = useState("dashboard");
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    if (api.getToken()) {
      api.me().then(u => { setUser(u); setChecking(false); }).catch(() => setChecking(false));
    } else { setChecking(false); }
  }, []);

  if (checking) return <><style>{S}</style><div style={{ display:"flex",alignItems:"center",justifyContent:"center",height:"100vh",color:"var(--text2)",fontFamily:"var(--font)" }}>Loading...</div></>;

  if (!user) return (
    <>
      <style>{S}</style>
      <Login onLogin={u => { setUser(u); setPage("dashboard"); }} />
    </>
  );

  const logout = () => { api.logout(); setUser(null); };

  const perms = ROLE_PERMISSIONS[user.role] || [];
  const visibleNav = NAV.filter(n => perms.includes(n.id));
  const sections = [...new Set(visibleNav.map(n => n.section))];

  const sectionLabel = { monitor: "Monitor", config: "Configuration", tools: "Tools", admin: "Administration" };

  return (
    <>
      <style>{S}</style>
      <div className="app">
        <aside className="sidebar">
          <div className="sidebar-logo">
            <div className="logo-icon"><Icon d={ICONS.shield} size={18} /></div>
            <div className="logo-text">Open<span>VPN</span></div>
          </div>
          <nav className="sidebar-nav">
            {sections.map(sec => (
              <div key={sec}>
                <div className="nav-section">{sectionLabel[sec]}</div>
                {visibleNav.filter(n => n.section === sec).map(n => (
                  <div key={n.id} className={`nav-item ${page === n.id ? "active" : ""}`} onClick={() => setPage(n.id)}>
                    <Icon d={n.icon} size={14} />{n.label}
                    {n.id === "clients" && <span className="nav-badge">3</span>}
                  </div>
                ))}
              </div>
            ))}
          </nav>
          <div className="sidebar-user">
            <div className="user-avatar">{user.name[0]}</div>
            <div className="user-info">
              <div className="user-name">{user.name}</div>
              <div className="user-role">{user.role}</div>
            </div>
            <div className="logout-btn" onClick={logout} title="Sign out">
              <Icon d={ICONS.logout} size={16} />
            </div>
          </div>
        </aside>
        <main className="main">
          <div className="topbar">
            <div className="topbar-title">{PAGE_TITLES[page]}<span>OpenVPN Panel</span></div>
            <div className="topbar-right">
              <div className="status-label"><div className="status-dot" />Server Online</div>
            </div>
          </div>
          <div className="page">
            {page === "dashboard" && <Dashboard />}
            {page === "clients"   && <Clients />}
            {page === "generate"  && <Generate />}
            {page === "tcpdump"   && <TCPDump />}
            {page === "logs"      && <Logs />}
            {page === "admin"     && <Admin />}
          </div>
        </main>
      </div>
    </>
  );
}
