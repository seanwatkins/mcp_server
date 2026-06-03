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

## Running in Docker (recommended for sharing)

See [docker/README.md](docker/README.md) for the full guide. Quick version:

```bash
cd docker
cp .env.example .env   # set MCP_SERVER_URL and TUNNEL_TOKEN
docker compose up -d
```

## Adding tools

Claude can define new tools at runtime via `eval_lisp`:

```lisp
(define-tool my-tool
  "Description of what it does."
  (jobj "type" "object"
        "properties" (jobj "arg" (jobj "type" "string")))
  (format nil "Result: ~A" (gethash "arg" args)))
```

Tools are appended to `tools.lisp` and survive restarts.

## Environment variables

| Variable | Description |
|---|---|
| `MCP_SERVER_URL` | Public URL Claude connects to |
| `MCP_PORT` | Port to listen on (default 8765) |
| `TUNNEL_TOKEN` | Cloudflare Tunnel token |
| `TOOLS_FILE` | Path to tools.lisp |
| `LOG_FILE` | Log path |
| `GRAFANA_URL` | Grafana base URL |
| `GRAFANA_USER` | Grafana username |
| `GRAFANA_PASS` | Grafana password |

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

Copyright © 2026 Sean Watkins. Free to use, modify, and distribute under the
terms of the GPL v3. Any derivative work must also be open source under GPL v3.
