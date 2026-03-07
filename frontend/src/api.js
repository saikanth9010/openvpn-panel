const BASE = "/api";

function getToken() { return localStorage.getItem("ovpn_token"); }
function setToken(t) { localStorage.setItem("ovpn_token", t); }
function clearToken() { localStorage.removeItem("ovpn_token"); }

async function req(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(getToken() ? { Authorization: `Bearer ${getToken()}` } : {}),
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  if (res.status === 401) { clearToken(); window.location.reload(); return; }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

export const api = {
  login:   (u, p) => req("POST", "/auth/login", { username: u, password: p })
                       .then(d => { setToken(d.token); return d; }),
  me:      ()     => req("GET", "/auth/me"),
  logout:  ()     => { clearToken(); },

  clients:    ()     => req("GET", "/clients"),
  disconnect: (name) => req("POST", `/clients/${name}/disconnect`),

  status: () => req("GET", "/status"),
  logs:   () => req("GET", "/logs"),

  profiles:      ()     => req("GET", "/profiles"),
  deleteProfile: (name) => req("DELETE", `/profiles/${name}`),

  generate: async (body) => {
    const res = await fetch(BASE + "/generate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${getToken()}`,
      },
      body: JSON.stringify(body),
    });
    // Check content-type — if JSON it's an error, if octet-stream it's the file
    const ct = res.headers.get("content-type") || "";
    if (!res.ok || ct.includes("json")) {
      const d = await res.json().catch(() => ({}));
      throw new Error(d.error || `Generate failed (${res.status})`);
    }
    const blob = await res.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url;
    a.download = `${body.name}.ovpn`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  },

  downloadProfile: async (name) => {
    const res = await fetch(`${BASE}/profiles/${name}/download`, {
      headers: { Authorization: `Bearer ${getToken()}` },
    });
    if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.error || "Download failed"); }
    const blob = await res.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url; a.download = `${name}.ovpn`;
    document.body.appendChild(a); a.click();
    document.body.removeChild(a); URL.revokeObjectURL(url);
  },

  users:      ()       => req("GET",    "/admin/users"),
  createUser: (u)      => req("POST",   "/admin/users", u),
  updateUser: (id, u)  => req("PATCH",  `/admin/users/${id}`, u),
  deleteUser: (id)     => req("DELETE", `/admin/users/${id}`),

  tcpdumpWs: (iface, filter) => {
    const token  = getToken();
    const proto  = location.protocol === "https:" ? "wss" : "ws";
    const params = new URLSearchParams({ token, iface, filter });
    return new WebSocket(`${proto}://${location.host}/ws/tcpdump?${params}`);
  },

  getToken,
};
