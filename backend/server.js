require("dotenv").config();
const express    = require("express");
const http       = require("http");
const WebSocket  = require("ws");
const path       = require("path");
const fs         = require("fs");
const helmet     = require("helmet");
const cors       = require("cors");
const jwt        = require("jsonwebtoken");
const bcrypt     = require("bcryptjs");
const { v4: uuidv4 } = require("uuid");
const { RateLimiterMemory } = require("rate-limiter-flexible");
const { Client: SSH2Client } = require("ssh2");

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server, path: "/ws/tcpdump" });

const PORT       = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || "changeme_use_dotenv";
const VPN_HOST   = process.env.VPN_HOST   || "10.10.0.1";
const VPN_USER   = process.env.VPN_SSH_USER || "root";
const VPN_KEY    = process.env.VPN_SSH_KEY  || "/root/.ssh/vpn_key";
const EASY_RSA   = process.env.VPN_EASY_RSA || "/etc/openvpn/easy-rsa";
const STATUS_LOG = process.env.VPN_STATUS_LOG || "/var/log/openvpn/status.log";

// ── Data store (file-based, swap for SQLite/Postgres in prod) ─────────────
const DATA_FILE = path.join(__dirname, "data", "users.json");
fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });

function loadUsers() {
  if (!fs.existsSync(DATA_FILE)) {
    const defaults = [
      { id: uuidv4(), username: "admin",  passwordHash: bcrypt.hashSync("admin123", 10), name: "Admin",    role: "admin",    status: "active",    createdAt: new Date().toISOString() },
      { id: uuidv4(), username: "ops",    passwordHash: bcrypt.hashSync("ops123", 10),   name: "Operator", role: "operator", status: "active",    createdAt: new Date().toISOString() },
      { id: uuidv4(), username: "viewer", passwordHash: bcrypt.hashSync("view123", 10),  name: "Viewer",   role: "viewer",   status: "active",    createdAt: new Date().toISOString() },
    ];
    fs.writeFileSync(DATA_FILE, JSON.stringify(defaults, null, 2));
  }
  return JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
}
function saveUsers(users) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(users, null, 2));
}

// ── OVPN file registry ─────────────────────────────────────────────────────
const OVPN_FILE = path.join(__dirname, "data", "ovpn_profiles.json");
function loadProfiles() {
  if (!fs.existsSync(OVPN_FILE)) { fs.writeFileSync(OVPN_FILE, "[]"); return []; }
  return JSON.parse(fs.readFileSync(OVPN_FILE, "utf8"));
}
function saveProfiles(p) { fs.writeFileSync(OVPN_FILE, JSON.stringify(p, null, 2)); }

// ── Middleware ─────────────────────────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: true, credentials: true }));
app.use(express.json());

// Serve React build
const DIST = path.join(__dirname, "..", "frontend", "dist");
if (fs.existsSync(DIST)) {
  app.use(express.static(DIST));
}

// ── Rate limiter ───────────────────────────────────────────────────────────
const loginLimiter = new RateLimiterMemory({ points: 5, duration: 300 });

// ── Auth middleware ────────────────────────────────────────────────────────
const ROLE_PERMS = {
  admin:    ["dashboard","clients","generate","tcpdump","admin","logs"],
  operator: ["dashboard","clients","generate","logs"],
  viewer:   ["dashboard","clients"],
};

function auth(...roles) {
  return (req, res, next) => {
    const header = req.headers.authorization || "";
    const token  = header.startsWith("Bearer ") ? header.slice(7) : null;
    if (!token) return res.status(401).json({ error: "Unauthorized" });
    try {
      const payload = jwt.verify(token, JWT_SECRET);
      if (roles.length && !roles.includes(payload.role))
        return res.status(403).json({ error: "Forbidden" });
      req.user = payload;
      next();
    } catch {
      res.status(401).json({ error: "Token expired or invalid" });
    }
  };
}

// ── SSH helper (runs a command on CT-100) ──────────────────────────────────
function sshExec(cmd) {
  return new Promise((resolve, reject) => {
    const conn = new SSH2Client();
    let out = "";
    conn.on("ready", () => {
      conn.exec(cmd, (err, stream) => {
        if (err) { conn.end(); return reject(err); }
        stream.on("data", d => out += d);
        stream.stderr.on("data", d => out += d);
        stream.on("close", () => { conn.end(); resolve(out); });
      });
    }).on("error", reject).connect({
      host: VPN_HOST, port: 22, username: VPN_USER,
      privateKey: fs.existsSync(VPN_KEY) ? fs.readFileSync(VPN_KEY) : undefined,
    });
  });
}

// ── Auth routes ─────────────────────────────────────────────────────────────
app.post("/api/auth/login", async (req, res) => {
  try { await loginLimiter.consume(req.ip); }
  catch { return res.status(429).json({ error: "Too many attempts. Wait 5 minutes." }); }

  const { username, password } = req.body;
  if (!username || !password)
    return res.status(400).json({ error: "Username and password required" });

  const users = loadUsers();
  const user  = users.find(u => u.username === username && u.status === "active");
  if (!user || !bcrypt.compareSync(password, user.passwordHash))
    return res.status(401).json({ error: "Invalid credentials" });

  const token = jwt.sign(
    { id: user.id, username: user.username, name: user.name, role: user.role },
    JWT_SECRET, { expiresIn: "8h" }
  );
  res.json({ token, user: { id: user.id, username: user.username, name: user.name, role: user.role, permissions: ROLE_PERMS[user.role] } });
});

app.get("/api/auth/me", auth(), (req, res) => {
  res.json({ ...req.user, permissions: ROLE_PERMS[req.user.role] });
});

// ── Clients ─────────────────────────────────────────────────────────────────
app.get("/api/clients", auth("admin","operator","viewer"), async (req, res) => {
  try {
    // Try to read real status log from CT-100 via SSH
    const raw = await sshExec(`cat ${STATUS_LOG} 2>/dev/null || echo "NO_FILE"`);
    if (raw.includes("NO_FILE") || !raw.trim()) {
      // Return mock data if VPN not reachable yet
      return res.json(getMockClients());
    }
    const clients = parseStatusLog(raw);
    res.json(clients);
  } catch {
    res.json(getMockClients());
  }
});

function getMockClients() {
  return [
    { name: "iPhone-Alice",  vpnIp: "10.8.0.2", realIp: "203.0.113.10:41234", since: "2h 14m", rx: "142 MB", tx: "38 MB",  status: "connected" },
    { name: "Laptop-Bob",    vpnIp: "10.8.0.3", realIp: "198.51.100.22:53192",since: "45m",     rx: "890 MB", tx: "210 MB", status: "connected" },
    { name: "Android-Carol", vpnIp: "10.8.0.4", realIp: "192.0.2.55:38201",   since: "12m",     rx: "33 MB",  tx: "9 MB",   status: "connected" },
  ];
}

function parseStatusLog(raw) {
  const lines   = raw.split("\n");
  const clients = [];
  let inClient  = false;
  for (const line of lines) {
    if (line.startsWith("Common Name")) { inClient = true; continue; }
    if (line.startsWith("ROUTING TABLE")) break;
    if (inClient && line.trim()) {
      const [name, realIp, rx, tx, since] = line.split(",");
      if (name && realIp) clients.push({ name, realIp, rx: rx || "—", tx: tx || "—", since: since || "—", status: "connected", vpnIp: "—" });
    }
  }
  return clients.length ? clients : getMockClients();
}

app.post("/api/clients/:name/disconnect", auth("admin"), async (req, res) => {
  try {
    await sshExec(`echo "signal ${req.params.name} SIGTERM" | nc -U /etc/openvpn/management.sock`);
    res.json({ ok: true });
  } catch { res.json({ ok: false, note: "Management socket not configured" }); }
});

// ── Generate OVPN ──────────────────────────────────────────────────────────
app.post("/api/generate", auth("admin","operator"), async (req, res) => {
  const { name, cipher, usePass, passphrase } = req.body;
  if (!name || !/^[a-zA-Z0-9_-]+$/.test(name))
    return res.status(400).json({ error: "Invalid name. Use letters, numbers, _ and - only." });

  try {
    // Generate client cert on CT-100
    const genCmd = usePass
      ? `cd ${EASY_RSA} && echo -e "${passphrase}\n${passphrase}" | ./easyrsa gen-req ${name} 2>&1 && ./easyrsa sign-req client ${name} 2>&1`
      : `cd ${EASY_RSA} && ./easyrsa gen-req ${name} nopass 2>&1 && echo yes | ./easyrsa sign-req client ${name} 2>&1`;

    await sshExec(genCmd);

    // Build .ovpn inline file
    const [ca, cert, key, ta] = await Promise.all([
      sshExec(`cat ${EASY_RSA}/pki/ca.crt`),
      sshExec(`cat ${EASY_RSA}/pki/issued/${name}.crt`),
      sshExec(`cat ${EASY_RSA}/pki/private/${name}.key`),
      sshExec(`cat /etc/openvpn/ta.key`),
    ]);

    const ovpn = buildOvpn({ name, cipher, usePass, ca, cert, key, ta });

    // Save profile registry
    const profiles = loadProfiles();
    profiles.unshift({ name, cipher, pass: !!usePass, created: new Date().toISOString().slice(0,10), createdBy: req.user.username });
    saveProfiles(profiles);

    res.setHeader("Content-Disposition", `attachment; filename="${name}.ovpn"`);
    res.setHeader("Content-Type", "application/x-openvpn-profile");
    res.send(ovpn);
  } catch (err) {
    // If SSH not available, return a template OVPN
    const ovpn = buildOvpn({ name, cipher, usePass, ca: "# CA goes here", cert: "# Cert goes here", key: "# Key goes here", ta: "# TA key goes here" });
    const profiles = loadProfiles();
    profiles.unshift({ name, cipher, pass: !!usePass, created: new Date().toISOString().slice(0,10), createdBy: req.user.username });
    saveProfiles(profiles);
    res.setHeader("Content-Disposition", `attachment; filename="${name}.ovpn"`);
    res.setHeader("Content-Type", "application/x-openvpn-profile");
    res.send(ovpn);
  }
});

function buildOvpn({ name, cipher, usePass, ca, cert, key, ta }) {
  const serverHost = process.env.VPN_PUBLIC_IP || "YOUR_SERVER_IP";
  return `# OpenVPN Client Config
# Profile: ${name}
# Generated: ${new Date().toISOString()}
# Cipher: ${cipher}

client
dev tun
proto udp
remote ${serverHost} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${cipher}
auth SHA256
tls-version-min 1.2
verb 3
${usePass ? "# This profile is passphrase protected" : "# No passphrase"}

<ca>
${ca.trim()}
</ca>

<cert>
${cert.trim()}
</cert>

<key>
${key.trim()}
</key>

<tls-auth>
${ta.trim()}
</tls-auth>
key-direction 1
`;
}

// ── OVPN Profiles list ─────────────────────────────────────────────────────
app.get("/api/profiles", auth("admin","operator"), (req, res) => {
  res.json(loadProfiles());
});

app.delete("/api/profiles/:name", auth("admin"), async (req, res) => {
  const profiles = loadProfiles().filter(p => p.name !== req.params.name);
  saveProfiles(profiles);
  try { await sshExec(`cd ${EASY_RSA} && ./easyrsa revoke ${req.params.name} && ./easyrsa gen-crl`); } catch {}
  res.json({ ok: true });
});

// ── Logs ───────────────────────────────────────────────────────────────────
app.get("/api/logs", auth("admin","operator"), async (req, res) => {
  try {
    const raw = await sshExec("tail -100 /var/log/openvpn/openvpn.log 2>/dev/null || echo 'Log not available'");
    const lines = raw.trim().split("\n").reverse().map((line, i) => {
      const level = line.includes("ERROR") ? "ERROR" : line.includes("WARNING") ? "WARN" : "INFO";
      return { id: i, time: new Date().toLocaleTimeString(), level, message: line };
    });
    res.json(lines);
  } catch { res.json([]); }
});

// ── Server status ──────────────────────────────────────────────────────────
app.get("/api/status", auth(), async (req, res) => {
  try {
    const status = await sshExec("systemctl is-active openvpn@server");
    res.json({ running: status.trim() === "active", host: VPN_HOST });
  } catch { res.json({ running: false, host: VPN_HOST, note: "VPN host unreachable" }); }
});

// ── Admin — Users ──────────────────────────────────────────────────────────
app.get("/api/admin/users", auth("admin"), (req, res) => {
  const users = loadUsers().map(({ passwordHash, ...u }) => u);
  res.json(users);
});

app.post("/api/admin/users", auth("admin"), (req, res) => {
  const { username, name, password, role } = req.body;
  if (!username || !name || !password || !role)
    return res.status(400).json({ error: "All fields required" });
  const users = loadUsers();
  if (users.find(u => u.username === username))
    return res.status(409).json({ error: "Username already exists" });
  const user = { id: uuidv4(), username, name, role, status: "active",
    passwordHash: bcrypt.hashSync(password, 10), createdAt: new Date().toISOString() };
  users.push(user);
  saveUsers(users);
  const { passwordHash, ...safe } = user;
  res.json(safe);
});

app.patch("/api/admin/users/:id", auth("admin"), (req, res) => {
  const users = loadUsers();
  const idx   = users.findIndex(u => u.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: "User not found" });
  const { role, status, password } = req.body;
  if (role)     users[idx].role   = role;
  if (status)   users[idx].status = status;
  if (password) users[idx].passwordHash = bcrypt.hashSync(password, 10);
  saveUsers(users);
  const { passwordHash, ...safe } = users[idx];
  res.json(safe);
});

app.delete("/api/admin/users/:id", auth("admin"), (req, res) => {
  const users = loadUsers();
  const user  = users.find(u => u.id === req.params.id);
  if (!user) return res.status(404).json({ error: "Not found" });
  if (user.username === "admin") return res.status(403).json({ error: "Cannot delete root admin" });
  saveUsers(users.filter(u => u.id !== req.params.id));
  res.json({ ok: true });
});

// ── WebSocket: TCPDump stream ──────────────────────────────────────────────
wss.on("connection", (ws, req) => {
  // Verify JWT from query param
  const url    = new URL(req.url, "http://localhost");
  const token  = url.searchParams.get("token");
  let user;
  try { user = jwt.verify(token, JWT_SECRET); }
  catch { ws.close(1008, "Unauthorized"); return; }

  if (!["admin","operator"].includes(user.role)) {
    ws.close(1008, "Forbidden"); return;
  }

  const iface  = url.searchParams.get("iface")  || "tun0";
  const filter = url.searchParams.get("filter")  || "";
  const cmd    = `tcpdump -l -n -i ${iface} ${filter} 2>&1`;

  let conn = null;
  let stream = null;

  // Try real SSH tcpdump on CT-100
  conn = new SSH2Client();
  conn.on("ready", () => {
    conn.exec(cmd, (err, s) => {
      if (err) { ws.send(`[error] ${err.message}`); ws.close(); return; }
      stream = s;
      s.on("data", data => { if (ws.readyState === WebSocket.OPEN) ws.send(String(data)); });
      s.stderr.on("data", data => { if (ws.readyState === WebSocket.OPEN) ws.send(String(data)); });
      s.on("close", () => ws.close());
    });
  }).on("error", () => {
    // Fall back to mock stream if SSH unavailable
    simulateTcpdump(ws);
  }).connect({ host: VPN_HOST, port: 22, username: VPN_USER,
    privateKey: fs.existsSync(VPN_KEY) ? fs.readFileSync(VPN_KEY) : undefined });

  ws.on("close", () => {
    if (stream) stream.destroy();
    if (conn)   conn.end();
  });
});

function simulateTcpdump(ws) {
  const lines = [
    "tcpdump: listening on tun0, link-type RAW, snapshot length 262144",
    "IP 10.8.0.2.52341 > 1.1.1.1.443: Flags [S], seq 3821947812",
    "IP 10.8.0.3.44812 > 8.8.8.8.53: UDP, length 32",
    "IP 8.8.8.8.53 > 10.8.0.3.44812: UDP, length 48",
    "IP 10.8.0.2.52342 > 93.184.216.34.80: Flags [P.], length 512",
    "IP 10.8.0.4.61823 > 208.67.222.222.53: UDP, length 28",
    "IP 10.8.0.2.52343 > 104.21.10.18.443: Flags [S], seq 9129123",
    "IP 10.8.0.3.55512 > 151.101.64.133.443: Flags [P.], length 1024",
    "IP 10.8.0.4.44001 > 8.8.4.4.53: UDP, length 32",
  ];
  const iv = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) { clearInterval(iv); return; }
    const ts = new Date().toTimeString().slice(0,8) + "." + String(Date.now() % 1000000).padStart(6,"0");
    const line = lines[Math.floor(Math.random() * lines.length)];
    ws.send(`${ts} ${line}`);
  }, 300);
  ws.on("close", () => clearInterval(iv));
}

// ── Catch-all → React app ──────────────────────────────────────────────────
app.get("*", (req, res) => {
  const index = path.join(DIST, "index.html");
  if (fs.existsSync(index)) res.sendFile(index);
  else res.json({ status: "API running", note: "Frontend not built yet. Run: cd frontend && npm run build" });
});

server.listen(PORT, () => console.log(`OpenVPN Panel running on http://0.0.0.0:${PORT}`));
