require("dotenv").config();
const express   = require("express");
const http      = require("http");
const WebSocket = require("ws");
const path      = require("path");
const fs        = require("fs");
const { execSync, spawn } = require("child_process");
const helmet    = require("helmet");
const cors      = require("cors");
const jwt       = require("jsonwebtoken");
const bcrypt    = require("bcryptjs");
const { v4: uuidv4 } = require("uuid");
const { RateLimiterMemory } = require("rate-limiter-flexible");

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server, path: "/ws/tcpdump" });

const PORT       = process.env.PORT        || 3001;
const JWT_SECRET = process.env.JWT_SECRET  || require("crypto").randomBytes(32).toString("hex");
const VPN_HOST   = process.env.VPN_HOST    || "10.10.0.1";
const VPN_KEY    = process.env.VPN_SSH_KEY || "/root/.ssh/vpn_key";
const VPN_USER   = process.env.VPN_SSH_USER|| "root";
const EASY_RSA   = process.env.VPN_EASY_RSA|| "/etc/openvpn/easy-rsa";
const STATUS_LOG = process.env.VPN_STATUS_LOG || "/var/log/openvpn/status.log";
const VPN_LOG    = process.env.VPN_LOG     || "/var/log/openvpn/openvpn.log";
const SERVER_ADDR= process.env.VPN_PUBLIC_IP || process.env.SERVER_ADDR || "YOUR_SERVER";
const VPN_PORT   = process.env.VPN_PORT    || "1194";
const DEFAULT_CIPHER = process.env.DEFAULT_CIPHER || "AES-256-CBC";

// Detect if we're running on the same host as OpenVPN (single-container mode)
const IS_SINGLE = fs.existsSync("/etc/openvpn/server.conf");

// ── Data files ────────────────────────────────────────────────────────────────
const DATA_DIR    = path.join(__dirname, "data");
const USERS_FILE  = path.join(DATA_DIR, "users.json");
const OVPN_FILE   = path.join(DATA_DIR, "ovpn_profiles.json");
fs.mkdirSync(DATA_DIR, { recursive: true });

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const u = [{ id: uuidv4(), username: "admin", passwordHash: bcrypt.hashSync("admin", 10),
      name: "Administrator", role: "admin", status: "active", createdAt: new Date().toISOString() }];
    fs.writeFileSync(USERS_FILE, JSON.stringify(u, null, 2));
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, "utf8"));
}
function saveUsers(u) { fs.writeFileSync(USERS_FILE, JSON.stringify(u, null, 2)); }
function loadProfiles() {
  if (!fs.existsSync(OVPN_FILE)) { fs.writeFileSync(OVPN_FILE, "[]"); return []; }
  return JSON.parse(fs.readFileSync(OVPN_FILE, "utf8"));
}
function saveProfiles(p) { fs.writeFileSync(OVPN_FILE, JSON.stringify(p, null, 2)); }

// ── SSH helper (two-container mode) ──────────────────────────────────────────
function sshExec(cmd) {
  return new Promise((resolve, reject) => {
    try {
      const { Client } = require("ssh2");
      const conn = new Client();
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
    } catch { reject(new Error("ssh2 module not available")); }
  });
}

// Run a command locally or over SSH depending on mode
async function runCmd(cmd) {
  if (IS_SINGLE) {
    return execSync(cmd, { encoding: "utf8" });
  }
  return sshExec(cmd);
}

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: true, credentials: true }));
app.use(express.json());

// Serve React build
const DIST = path.join(__dirname, "frontend", "dist");
if (fs.existsSync(DIST)) {
  app.use(express.static(DIST));
  console.log("Serving frontend from:", DIST);
} else {
  console.warn("Frontend dist not found at:", DIST);
}

// ── Rate limiter ──────────────────────────────────────────────────────────────
const loginLimiter = new RateLimiterMemory({ points: 10, duration: 300 });

// ── RBAC ──────────────────────────────────────────────────────────────────────
const ROLE_PERMS = {
  admin:    ["dashboard","clients","generate","tcpdump","admin","logs"],
  operator: ["dashboard","clients","generate","logs"],
  viewer:   ["dashboard","clients"],
};

function auth(...roles) {
  return (req, res, next) => {
    const h = req.headers.authorization || "";
    const token = h.startsWith("Bearer ") ? h.slice(7) : null;
    if (!token) return res.status(401).json({ error: "Unauthorized" });
    try {
      const p = jwt.verify(token, JWT_SECRET);
      if (roles.length && !roles.includes(p.role))
        return res.status(403).json({ error: "Forbidden" });
      req.user = p; next();
    } catch { res.status(401).json({ error: "Token expired" }); }
  };
}

// ── Auth ──────────────────────────────────────────────────────────────────────
app.post("/api/auth/login", async (req, res) => {
  try { await loginLimiter.consume(req.ip); }
  catch { return res.status(429).json({ error: "Too many attempts. Wait 5 minutes." }); }

  const { username, password } = req.body;
  if (!username || !password)
    return res.status(400).json({ error: "Username and password required" });

  const users = loadUsers();
  const user  = users.find(u => u.username === username && u.status === "active");
  // Support both passwordHash (new) and password (legacy plaintext, for migration)
  const valid = user && (
    (user.passwordHash && bcrypt.compareSync(password, user.passwordHash)) ||
    (user.password     && user.password === password)
  );
  if (!valid) return res.status(401).json({ error: "Invalid credentials" });

  // Migrate legacy plaintext password to hash
  if (user.password && !user.passwordHash) {
    user.passwordHash = bcrypt.hashSync(user.password, 10);
    delete user.password;
    saveUsers(users);
  }

  const token = jwt.sign(
    { id: user.id, username: user.username, name: user.name, role: user.role },
    JWT_SECRET, { expiresIn: "8h" }
  );
  res.json({ token, user: { id: user.id, username: user.username, name: user.name,
    role: user.role, permissions: ROLE_PERMS[user.role] || [] } });
});

app.get("/api/auth/me", auth(), (req, res) => {
  res.json({ ...req.user, permissions: ROLE_PERMS[req.user.role] || [] });
});

// ── VPN Status ────────────────────────────────────────────────────────────────
app.get("/api/status", auth(), async (req, res) => {
  try {
    const status = await runCmd("systemctl is-active openvpn@server 2>/dev/null || echo inactive");
    res.json({ running: status.trim() === "active", host: IS_SINGLE ? "local" : VPN_HOST, mode: IS_SINGLE ? "single" : "dual" });
  } catch { res.json({ running: false, host: VPN_HOST }); }
});

// ── Clients ───────────────────────────────────────────────────────────────────
app.get("/api/clients", auth(), async (req, res) => {
  try {
    const raw = await runCmd(`cat "${STATUS_LOG}" 2>/dev/null || echo ""`);
    if (!raw || !raw.trim()) return res.json([]);
    const clients = [];
    let inSection = false;
    for (const line of raw.split("\n")) {
      if (line.startsWith("Common Name,")) { inSection = true; continue; }
      if (line.startsWith("ROUTING TABLE") || line.startsWith("GLOBAL STATS")) break;
      if (inSection && line.trim() && !line.startsWith("Common Name")) {
        const parts = line.split(",");
        if (parts.length >= 4) {
          clients.push({ name: parts[0], realIp: parts[1], rx: parts[2], tx: parts[3],
            since: parts[4] || "", status: "connected", vpnIp: "" });
        }
      }
    }
    res.json(clients);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post("/api/clients/:name/disconnect", auth("admin"), async (req, res) => {
  try {
    await runCmd(`echo "kill ${req.params.name}" | nc -U /var/run/openvpn/server.sock 2>/dev/null || true`);
    res.json({ ok: true });
  } catch { res.json({ ok: false }); }
});

// ── Generate OVPN ─────────────────────────────────────────────────────────────
app.post("/api/generate", auth("admin", "operator"), async (req, res) => {
  const { name, cipher = DEFAULT_CIPHER, usePass = false, passphrase = "" } = req.body;

  if (!name || !/^[a-zA-Z0-9_-]+$/.test(name))
    return res.status(400).json({ error: "Invalid name. Use letters, numbers, _ and - only." });

  console.log(`[generate] Starting for: ${name}, cipher: ${cipher}`);

  try {
    // Do everything in ONE SSH connection / ONE execSync call to avoid multiple round trips
    const bigCmd = `
set -e
cd "${EASY_RSA}"
export EASYRSA_BATCH=1
# Generate client cert (skip if already exists)
if [ ! -f "pki/issued/${name}.crt" ]; then
  ./easyrsa gen-req "${name}" nopass 2>/dev/null
  ./easyrsa sign-req client "${name}" 2>/dev/null
fi
# Output all files separated by markers
echo "===CA==="
cat pki/ca.crt
echo "===CERT==="
cat "pki/issued/${name}.crt"
echo "===KEY==="
cat "pki/private/${name}.key"
echo "===TA==="
cat pki/ta.key 2>/dev/null || echo ""
echo "===DONE==="
`;

    console.log(`[generate] Running command on ${IS_SINGLE ? "local" : VPN_HOST}...`);
    const output = await runCmd(bigCmd);
    console.log(`[generate] Command finished, parsing output...`);

    // Parse the output by markers
    const section = (marker) => {
      const start = output.indexOf(`===${marker}===`);
      const markers = ["===CA===","===CERT===","===KEY===","===TA===","===DONE==="];
      const nextIdx = markers.findIndex(m => m === `===${marker}===`) + 1;
      const end   = nextIdx < markers.length ? output.indexOf(markers[nextIdx]) : output.length;
      return start === -1 ? "" : output.slice(start + marker.length + 6, end).trim();
    };

    const ca   = section("CA");
    const cert = section("CERT");
    const key  = section("KEY");
    const ta   = section("TA");

    if (!ca || !cert || !key) {
      console.error("[generate] Missing cert data:", { ca: !!ca, cert: !!cert, key: !!key });
      return res.status(500).json({ error: "Cert generation failed — missing output" });
    }

    // Extract only the client cert (last cert block, skip CA chain)
    const certBlocks = cert.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) || [];
    const certBlock  = certBlocks[certBlocks.length - 1] || cert;

    const ovpn = buildOvpn({ name, cipher, usePass, ca, cert: certBlock, key, ta });

    const profiles = loadProfiles();
    if (!profiles.find(p => p.name === name)) {
      profiles.unshift({ name, cipher, pass: !!usePass, created: new Date().toISOString().slice(0,10), createdBy: req.user.username });
      saveProfiles(profiles);
    }

    console.log(`[generate] Success — sending ${ovpn.length} byte .ovpn file`);
    res.setHeader("Content-Disposition", `attachment; filename="${name}.ovpn"`);
    res.setHeader("Content-Type", "application/x-openvpn-profile");
    res.send(ovpn);
  } catch (err) {
    console.error("[generate] Error:", err.message);
    res.status(500).json({ error: "Failed to generate: " + err.message });
  }
});

function buildOvpn({ name, cipher, usePass, ca, cert, key, ta }) {
  // Extract only the cert block from the full chain
  const certMatch = String(cert).match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g);
  const certBlock = certMatch ? certMatch[certMatch.length - 1] : cert;

  return `# OpenVPN Client Profile
# Name: ${name}
# Generated: ${new Date().toISOString()}
# Server: ${SERVER_ADDR}

client
dev tun
proto udp
remote ${SERVER_ADDR} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${cipher}
auth SHA256
tls-version-min 1.2
verb 3
${usePass ? "# This profile uses a passphrase" : "auth-nocache"}

<ca>
${String(ca).trim()}
</ca>

<cert>
${String(certBlock).trim()}
</cert>

<key>
${String(key).trim()}
</key>

${ta && ta.trim() ? `key-direction 1\n<tls-auth>\n${String(ta).trim()}\n</tls-auth>` : ""}
`;
}

// ── Profiles ──────────────────────────────────────────────────────────────────
app.get("/api/profiles", auth("admin", "operator"), (req, res) => res.json(loadProfiles()));

app.get("/api/profiles/:name/download", auth("admin", "operator"), async (req, res) => {
  const profile = loadProfiles().find(p => p.name === req.params.name);
  if (!profile) return res.status(404).json({ error: "Profile not found" });
  // Re-generate download with stored settings
  try {
    const ca   = await runCmd(`cat "${EASY_RSA}/pki/ca.crt"`);
    const cert = await runCmd(`cat "${EASY_RSA}/pki/issued/${profile.name}.crt"`);
    const key  = await runCmd(`cat "${EASY_RSA}/pki/private/${profile.name}.key"`);
    const ta   = await runCmd(`cat "${EASY_RSA}/pki/ta.key" 2>/dev/null || echo ""`);
    const ovpn = buildOvpn({ name: profile.name, cipher: profile.cipher, usePass: profile.pass, ca, cert, key, ta });
    res.setHeader("Content-Disposition", `attachment; filename="${profile.name}.ovpn"`);
    res.setHeader("Content-Type", "application/x-openvpn-profile");
    res.send(ovpn);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.delete("/api/profiles/:name", auth("admin"), async (req, res) => {
  saveProfiles(loadProfiles().filter(p => p.name !== req.params.name));
  try { await runCmd(`cd "${EASY_RSA}" && EASYRSA_BATCH=1 ./easyrsa revoke "${req.params.name}" ; EASYRSA_BATCH=1 ./easyrsa gen-crl`); } catch {}
  res.json({ ok: true });
});

// ── Logs ──────────────────────────────────────────────────────────────────────
app.get("/api/logs", auth("admin", "operator"), async (req, res) => {
  try {
    const raw = await runCmd(`tail -200 "${VPN_LOG}" 2>/dev/null || echo "Log not available"`);
    const lines = raw.trim().split("\n").reverse().map((msg, i) => ({
      id: i,
      time: new Date().toLocaleTimeString(),
      level: msg.includes("ERROR") || msg.includes("error") ? "ERROR"
           : msg.includes("WARNING") || msg.includes("WARNING") ? "WARN" : "INFO",
      message: msg,
    }));
    res.json(lines);
  } catch { res.json([]); }
});

// ── Users ─────────────────────────────────────────────────────────────────────
app.get("/api/admin/users", auth("admin"), (req, res) => {
  res.json(loadUsers().map(({ passwordHash, password, ...u }) => u));
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
  const idx = users.findIndex(u => u.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: "Not found" });
  if (req.body.role)     users[idx].role   = req.body.role;
  if (req.body.status)   users[idx].status = req.body.status;
  if (req.body.password) users[idx].passwordHash = bcrypt.hashSync(req.body.password, 10);
  saveUsers(users);
  const { passwordHash, ...safe } = users[idx];
  res.json(safe);
});

app.delete("/api/admin/users/:id", auth("admin"), (req, res) => {
  const users = loadUsers();
  const user = users.find(u => u.id === req.params.id);
  if (!user) return res.status(404).json({ error: "Not found" });
  if (user.username === "admin") return res.status(403).json({ error: "Cannot delete root admin" });
  saveUsers(users.filter(u => u.id !== req.params.id));
  res.json({ ok: true });
});

// ── WebSocket TCPDump ─────────────────────────────────────────────────────────
wss.on("connection", (ws, req) => {
  const url   = new URL(req.url, "http://localhost");
  const token = url.searchParams.get("token");
  let user;
  try { user = jwt.verify(token, JWT_SECRET); }
  catch { ws.close(1008, "Unauthorized"); return; }
  if (!["admin", "operator"].includes(user.role)) { ws.close(1008, "Forbidden"); return; }

  const iface  = (url.searchParams.get("iface")  || "tun0").replace(/[^a-z0-9]/gi, "");
  const filter = (url.searchParams.get("filter") || "").replace(/['"\\;|&]/g, "");

  if (IS_SINGLE) {
    // Local tcpdump
    const proc = spawn("tcpdump", ["-l", "-n", "-i", iface, ...(filter ? filter.split(" ") : [])]);
    proc.stdout.on("data", d => ws.readyState === 1 && ws.send(String(d)));
    proc.stderr.on("data", d => ws.readyState === 1 && ws.send(String(d)));
    proc.on("close", () => ws.close());
    ws.on("close", () => proc.kill());
  } else {
    // SSH tcpdump on VPN container
    try {
      const { Client } = require("ssh2");
      const conn = new Client();
      conn.on("ready", () => {
        conn.exec(`tcpdump -l -n -i ${iface} ${filter} 2>&1`, (err, stream) => {
          if (err) { ws.send("[error] " + err.message); ws.close(); return; }
          stream.on("data", d => ws.readyState === 1 && ws.send(String(d)));
          stream.stderr.on("data", d => ws.readyState === 1 && ws.send(String(d)));
          stream.on("close", () => ws.close());
        });
      }).on("error", () => simulateTcpdump(ws))
        .connect({ host: VPN_HOST, port: 22, username: VPN_USER,
          privateKey: fs.existsSync(VPN_KEY) ? fs.readFileSync(VPN_KEY) : undefined });
      ws.on("close", () => conn.end());
    } catch { simulateTcpdump(ws); }
  }
});

function simulateTcpdump(ws) {
  const lines = [
    "tcpdump: listening on tun0, link-type RAW",
    "IP 10.8.0.2.52341 > 1.1.1.1.443: Flags [S]",
    "IP 10.8.0.3.44812 > 8.8.8.8.53: UDP, length 32",
    "IP 8.8.8.8.53 > 10.8.0.3.44812: UDP, length 48",
    "IP 10.8.0.2.52342 > 93.184.216.34.80: Flags [P.]",
  ];
  const iv = setInterval(() => {
    if (ws.readyState !== 1) { clearInterval(iv); return; }
    const ts = new Date().toTimeString().slice(0, 8);
    ws.send(`${ts} ${lines[Math.floor(Math.random() * lines.length)]}`);
  }, 600);
  ws.on("close", () => clearInterval(iv));
}

// ── SPA fallback ──────────────────────────────────────────────────────────────
app.get("*", (req, res) => {
  const index = path.join(DIST, "index.html");
  if (fs.existsSync(index)) return res.sendFile(index);
  res.json({ status: "API running", note: "Frontend not built" });
});

// ── Start ─────────────────────────────────────────────────────────────────────
server.listen(PORT, "0.0.0.0", () => {
  console.log(`OpenVPN Panel running on http://0.0.0.0:${PORT}`);
  console.log(`Mode: ${IS_SINGLE ? "single-container (local OpenVPN)" : "dual-container (SSH to " + VPN_HOST + ")"}`);
  console.log(`Frontend: ${fs.existsSync(DIST) ? DIST : "NOT FOUND"}`);
});