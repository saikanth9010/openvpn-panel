// Central API client — all calls go through here

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
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (res.status === 401) { clearToken(); window.location.reload(); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || "Request failed");
  return data;
}

export const api = {
  // Auth
  login:    (u, p)   => req("POST", "/auth/login", { username: u, password: p }).then(d => { setToken(d.token); return d; }),
  me:       ()        => req("GET",  "/auth/me"),
  logout:   ()        => clearToken(),

  // Clients
  clients:  ()        => req("GET",  "/clients"),
  disconnect: (name)  => req("POST", `/clients/${name}/disconnect`),

  // Generate
  profiles: ()        => req("GET",  "/profiles"),
  deleteProfile: (n)  => req("DELETE", `/profiles/${n}`),
  generate: async (body) => {
    const res = await fetch(BASE + "/generate", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${getToken()}` },
      body: JSON.stringify(body),
    });
    if (!res.ok) { const d = await res.json(); throw new Error(d.error); }
    const blob = await res.blob();
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement("a");
    a.href     = url;
    a.download = `${body.name}.ovpn`;
    a.click();
    URL.revokeObjectURL(url);
  },

  // Logs & status
  logs:     ()        => req("GET",  "/logs"),
  status:   ()        => req("GET",  "/status"),

  // Admin
  users:    ()        => req("GET",  "/admin/users"),
  createUser: (u)     => req("POST", "/admin/users", u),
  updateUser: (id, u) => req("PATCH",`/admin/users/${id}`, u),
  deleteUser: (id)    => req("DELETE",`/admin/users/${id}`),

  // TCPDump WebSocket
  tcpdumpWs: (iface, filter) => {
    const token = getToken();
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const params = new URLSearchParams({ token, iface, filter });
    return new WebSocket(`${proto}://${location.host}/ws/tcpdump?${params}`);
  },

  getToken,
};
