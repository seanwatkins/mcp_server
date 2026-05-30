# mcp-server

A live Common Lisp MCP (Model Context Protocol) server for Claude.ai.

Rather than a static list of tools defined at deploy time, this server exposes a
live SBCL image over HTTP. New tools can be added from inside a Claude.ai
conversation — they take effect immediately and persist across restarts
automatically. No redeploy, no restart required.

Written by Claude (https://claude.ai) with Sean Watkins.

---

## How it works

The server implements the MCP Streamable HTTP transport with OAuth 2.0 + PKCE,
which is what Claude.ai requires for remote connectors. Incoming JSON-RPC
requests are dispatched through a tool registry — a hash table mapping tool
names to handler functions.

Because the server is a running SBCL image, the `eval_lisp` tool lets Claude
evaluate arbitrary Common Lisp forms inside it. This means Claude can redefine
functions, inspect state, and register new tools — all live, without touching
the server process.

---

## Files

| File | Purpose |
|---|---|
| `mcp-server.lisp` | Main server — HTTP, OAuth, tool registry, built-in tools |
| `tools.lisp` | User-defined tools, auto-managed by `define-tool` |
| `start.sh` | Start/stop/restart/status script using GNU screen |
| `apache.conf` | Apache reverse proxy snippet for HTTPS termination |
| `mcp-server.log` | Rotating log — all requests, tool calls, auth events |

---

## Requirements

- **SBCL** (Steel Bank Common Lisp)
- **Quicklisp** with: `hunchentoot`, `yason`, `ironclad`, `cl-base64`, `cl-ppcre`, `uiop`, `bordeaux-threads`, `usocket`
- **GNU screen** (for `start.sh`)
- An HTTPS endpoint pointing at the server — either Apache (see `apache.conf`) or a tunnel like Cloudflare

---

## Configuration

Set these in a `.env` file in the same directory (sourced by `start.sh`):

| Variable | Default | Description |
|---|---|---|
| `MCP_SERVER_URL` | `http://localhost:8765` | Public HTTPS URL Claude.ai connects to |
| `MCP_PORT` | `8765` | Local port the server listens on |
| `MCP_ROOT` | `/share/projects/` | Root directory for file tools |
| `MCP_ENDPOINT` | `/claude` | HTTP path for the MCP endpoint |
| `TOOLS_FILE` | `mcp-server/tools.lisp` | Path to the user tools persistence file |
| `LOG_FILE` | `mcp-server/mcp-server.log` | Log file path |
| `MQTT_HOST` | `10.0.69.63` | MQTT broker for logging and status |
| `MQTT_PORT` | `1883` | MQTT broker port |
| `MQTT_TOPIC` | `mcp-server/log` | MQTT topic for log lines |
| `MQTT_STATUS_TOPIC` | `mcp-server/status` | MQTT topic for 1s heartbeat |

---

## Usage

```bash
# Start the server in a screen session
./start.sh start

# Stop it
./start.sh stop

# Restart (e.g. after editing mcp-server.lisp)
./start.sh restart

# Check if it's running
./start.sh status

# Attach to the screen session to see live output
screen -r mcp-server
```

Then add the server URL to **Claude.ai → Settings → Connectors**.

---

## Built-in tools

These are always registered from `mcp-server.lisp` and are never written to `tools.lisp`.

| Tool | Description |
|---|---|
| `read_file` | Read a file under `MCP_ROOT` |
| `write_file` | Write a file under `MCP_ROOT` |
| `list_directory` | List a directory under `MCP_ROOT` |
| `exec_command` | Run a shell command (30s timeout, 50KB output limit) |
| `eval_lisp` | Evaluate Common Lisp forms in the live server image |

---

## Adding tools at runtime

Use `eval_lisp` to call `define-tool` from inside Claude.ai. The tool is
registered immediately in the live image **and** appended to `tools.lisp` so
it survives the next restart.

```lisp
(define-tool disk_usage
  "Show disk usage for a path"
  (jobj "type" "object"
        "properties" (jobj "path" (jobj "type" "string"
                                        "description" "Path to check"))
        "required" (list "path"))
  (let ((path (or (gethash "path" args) "/")))
    (values (uiop:run-program (list "du" "-sh" path) :output :string) nil)))
```

`define-tool` arguments:
- **name** — unquoted symbol, lowercased to become the MCP tool name
- **description** — string shown to Claude
- **input-schema** — `jobj` form describing the parameters
- **handler body** — body of `(lambda (args) ...)` where `args` is a hash table; return `(values text-string is-error-bool)`

User tools live in `tools.lisp` and are loaded at startup via `load-tools-file`,
which binds `*loading-tools*` to `T` during the load so `define-tool` registers
each tool without re-appending it to the file.

---

## Removing a tool

```lisp
;; Remove from the live image immediately
(remhash "tool_name" *tool-registry*)
```

Then edit `tools.lisp` to remove the corresponding `define-tool` form so it
does not come back on the next restart.

---

## Live image capabilities

Because `eval_lisp` runs inside the server process, Claude can also:

- **Redefine any function** without restarting — e.g. patch a bug in a handler
- **Change configuration** at runtime — e.g. `(setf *exec-timeout* 60)`
- **Inspect state** — query `*tool-registry*`, check active tokens, read uptime
- **Load additional files** — `(load "/share/projects/something.lisp")`

The only things that require a restart are the Hunchentoot HTTP route handlers
(`define-easy-handler` forms), since those register URI routes at macro-expansion
time during startup.

---

## HTTPS with Apache

See `apache.conf` for a ready-to-use reverse proxy snippet. Add it inside your
existing SSL `VirtualHost` block and reload Apache:

```bash
sudo a2enmod proxy proxy_http
sudo systemctl reload apache2
```

The snippet proxies all OAuth discovery, registration, authorization, token, and
MCP endpoint paths through to `http://claude:8765/`.

---

## MQTT telemetry

The server publishes to two MQTT topics:

| Topic | Content | Interval |
|---|---|---|
| `mcp-server/log` | Every log line as a plain string | On each event |
| `mcp-server/status` | JSON heartbeat with uptime, tool count, status | Every 1 second |
