#!/bin/bash
# OctopusBaby container entrypoint

set -a
[ -f /app/.env ]       && source /app/.env
[ -f /app/data/.env ]  && source /app/data/.env
set +a

# Prefer tools in the mounted data volume so they survive image rebuilds
[ -f /app/data/tools.lisp ] && export TOOLS_FILE=/app/data/tools.lisp

echo "╔══════════════════════════════════════════╗"
echo "║       OctopusBaby MCP Server v0.1        ║"
echo "╚══════════════════════════════════════════╝"
echo "  URL   : ${MCP_SERVER_URL}"
echo "  Port  : ${MCP_PORT}"
echo "  Tools : ${TOOLS_FILE}"
echo ""

exec sbcl --non-interactive \
    --eval "(load \"/quicklisp/setup.lisp\")" \
    --load /app/mcp-server.lisp
