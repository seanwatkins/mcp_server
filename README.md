# MCP Server

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)


A live Common Lisp MCP server. Connects to Claude via the Model Context Protocol,
serving tools that Claude can call, extend, and redefine at runtime.

## Structure

```
mcp-server/
├── mcp-server.lisp     core server — OAuth, MCP protocol, tool dispatch
├── tools.lisp          user-defined tools (loaded at startup, persisted on change)
├── start.sh            startup script for running directly on a host
├── apache.conf         example Apache reverse proxy config
├── docker/
│   ├── Dockerfile      builds the OctopusBaby container image
│   ├── docker-compose.yml
│   ├── start.sh        container entrypoint
│   ├── .env.example    copy to .env and fill in your values
│   └── README.md       full Docker setup guide
└── README.md           this file
```

## Running directly on a host

```bash
# Install SBCL and Quicklisp, then:
cd mcp-server
cp .env.example .env   # edit with your tunnel URL etc.
./start.sh
```

`start.sh` manages the server as a `screen` session:

```bash
./start.sh            # start (default)
./start.sh start      # start in screen session 'mcp-server'
./start.sh stop       # kill the session
./start.sh restart    # stop + start
./start.sh status     # check if running

screen -r mcp-server  # attach to the running session
```

## Running in Docker (recommended for sharing)

See [docker/README.md](docker/README.md) for the full guide. Quick version:

```bash
cd docker
cp .env.example .env   # set MCP_SERVER_URL and TUNNEL_TOKEN
docker compose up -d
```

## Adding tools

Claude can define new tools at runtime via `eval_lisp`. Tools are automatically
appended to `tools.lisp` and survive restarts.

```lisp
(define-tool my_tool
  "Description of what it does."
  (jobj "type" "object"
        "properties" (jobj "arg" (jobj "type" "string"
                                       "description" "An argument"))
        "required" (list "arg"))
  (let ((arg (gethash "arg" args)))
    (values (format nil "Result: ~A" arg) nil)))
```

### How persistence works

When `define-tool` is called outside of the startup load, it:

1. Registers the tool immediately in the live server (available right away)
2. Appends the `define-tool` form to `tools.lisp` on disk
3. On next restart, `tools.lisp` is replayed — all tools come back automatically

If you want to add tools that persist across restarts without going through
`eval_lisp`, just add `define-tool` forms directly to `tools.lisp` and restart
the server (or call `(load-tools-file)` via `eval_lisp` to hot-reload).

### Docker persistence

In the Docker setup, `tools.lisp` inside the container is ephemeral. To make
tools persist across container rebuilds, mount a volume and point `TOOLS_FILE`
at it:

```yaml
# docker-compose.yml
volumes:
  - ./data:/app/data

environment:
  - TOOLS_FILE=/app/data/tools.lisp
```

The `docker/start.sh` entrypoint automatically uses `/app/data/tools.lisp` if
it exists, falling back to the bundled `/app/tools.lisp` otherwise.

## Built-in tools

| Tool | Description |
|---|---|
| `eval_lisp` | Evaluate Common Lisp in the running image |
| `exec_command` | Run a shell command |
| `read_file` | Read a file from the projects root |
| `write_file` | Write a file to the projects root |
| `list_directory` | List a directory under the projects root |
| `server_info` | Uptime, tool count, hostname |
| `reverse_string` | Reverses a string |
| `pig_latin` | Converts text to Pig Latin |
| `grafana` | Make Grafana REST API calls |
| `led_on` | Turn on a Home Assistant LED |
| `led_off` | Turn off a Home Assistant LED |
| `led_morse` | Flash a message in Morse code via LED |

## Environment variables

| Variable | Description |
|---|---|
| `MCP_SERVER_URL` | Public URL Claude connects to |
| `MCP_PORT` | Port to listen on (default 8765) |
| `TUNNEL_TOKEN` | Cloudflare Tunnel token |
| `TOOLS_FILE` | Path to tools.lisp (default `/app/tools.lisp`) |
| `LOG_FILE` | Log path |
| `GRAFANA_URL` | Grafana base URL |
| `GRAFANA_USER` | Grafana username |
| `GRAFANA_PASS` | Grafana password |

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

Copyright © 2026 Sean Watkins. Free to use, modify, and distribute under the
terms of the GPL v3. Any derivative work must also be open source under GPL v3.
