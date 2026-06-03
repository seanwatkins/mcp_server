# OctopusBaby 🐙

A Docker container running a live **Common Lisp MCP server** that Claude can connect to over the internet via a Cloudflare Tunnel.

No cloud account required. No open inbound ports. Just a machine running Docker and a free Cloudflare Tunnel.

---

## What it does

OctopusBaby boots a [SBCL](http://sbcl.org/) Lisp image serving the [MCP protocol](https://modelcontextprotocol.io/). Claude connects to it and gets a set of tools — a shell, a filesystem, a Lisp REPL, and whatever else you define. New tools can be added at runtime by Claude itself and persist across restarts.

---

## Requirements

- Docker (or Docker Compose)
- A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) token (free)

---

## Quickstart

**1. Clone and configure**

```bash
git clone https://github.com/seanwatkins/octopusbaby
cd octopusbaby/docker
cp .env.example .env
```

Edit `.env`:
```
MCP_SERVER_URL=https://your-tunnel.example.com
TUNNEL_TOKEN=your-cloudflare-tunnel-token
```

**2. Build and start**

```bash
docker compose up -d
```

First build takes ~5 minutes (downloads and pre-compiles Lisp dependencies). Subsequent starts are fast.

**3. Add to Claude**

Go to **claude.ai → Settings → Integrations → Add MCP Server** and enter your tunnel URL.

---

## Getting a Cloudflare Tunnel token

1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com)
2. Networks → Tunnels → **Create a tunnel**
3. Name it (e.g. `octopus`)
4. Copy the token — paste it into `.env` as `TUNNEL_TOKEN`
5. In the tunnel's **Public Hostname** tab, add a route pointing at `http://localhost:8765`

---

## Build manually (no compose)

```bash
# from the mcp-server/ parent directory
docker build -f docker/Dockerfile -t octopusbaby .

docker run -d \
  --name octopusBaby \
  -p 8765:8765 \
  -e MCP_SERVER_URL=https://your-tunnel.example.com \
  -e TUNNEL_TOKEN=your-cloudflare-tunnel-token \
  -v $(pwd)/docker/data:/app/data \
  octopusbaby
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MCP_SERVER_URL` | `http://localhost:8765` | Public URL Claude connects to — **must be set** |
| `MCP_PORT` | `8765` | Port the server listens on |
| `TUNNEL_TOKEN` | — | Cloudflare Tunnel token |
| `TOOLS_FILE` | `/app/tools.lisp` | Tool definitions (auto-loaded at startup) |
| `LOG_FILE` | `/var/log/octopus-mcp.log` | Log path |
| `GRAFANA_URL` | — | Grafana base URL (e.g. `http://10.0.0.1:3000`) |
| `GRAFANA_USER` | — | Grafana username |
| `GRAFANA_PASS` | — | Grafana password |

---

## Built-in tools

| Tool | Description |
|---|---|
| `eval_lisp` | Evaluate Common Lisp in the running image |
| `exec_command` | Run a shell command on the container |
| `read_file` | Read a file |
| `write_file` | Write a file |
| `list_directory` | List a directory |
| `server_info` | Uptime, tool count, hostname |
| `grafana` | Grafana REST API calls (set `GRAFANA_URL` to enable) |

---

## Defining new tools from Claude

Claude can define new tools at runtime and they persist across restarts:

```lisp
;; Claude calls eval_lisp with this — the tool is immediately available
(define-tool weather
  "Get the current weather for a city."
  (jobj "type" "object"
        "properties" (jobj "city" (jobj "type" "string")))
  (format nil "Weather in ~A: sunny, 22°C" (gethash "city" args)))
```

Tools are appended to `tools.lisp` (in the mounted `data/` volume) and reloaded on restart.

---

## Persistent data

Mount `./data` to `/app/data` (already done in `docker-compose.yml`):

```
docker/data/
  tools.lisp     ← your custom tools survive here
  .env           ← optional: override env vars
```

---

## Architecture

```
Claude.ai ──HTTPS──► Cloudflare edge ──tunnel──► cloudflared
                                                       │
                                                  port 8765
                                                       │
                                              OctopusBaby container
                                              ┌─────────────────────┐
                                              │  SBCL Lisp image     │
                                              │  Hunchentoot HTTP    │
                                              │  OAuth 2.0 + PKCE    │
                                              │  MCP protocol        │
                                              │  tools.lisp          │
                                              └─────────────────────┘
```

---

## Why Lisp?

The server is a live Lisp image — not a compiled binary. Claude can redefine functions, add tools, and inspect state at runtime. Changes persist via `tools.lisp`. It's the closest thing to a programmable server that evolves through conversation.

See [Octopus](https://octopusmcp.xyz) for the full story.

---

## License

GNU General Public License v3.0 — see [LICENSE](../LICENSE) for details.

Copyright © 2026 Sean Watkins. Free to use, modify, and distribute under the
terms of the GPL v3. If you ship this in a product or fork it, your changes
must also be open source under GPL v3.
