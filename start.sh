#!/bin/bash
cd "$(dirname "$0")"

set -a
source .env
set +a

case "${1:-start}" in

  start)
    if screen -list | grep -q "mcp-server"; then
      echo "mcp-server is already running"
      screen -r mcp-server
    else
      screen -dmS mcp-server sbcl --load mcp-server.lisp
      echo "Started mcp-server in screen session 'mcp-server'"
      echo "Attach with: screen -r mcp-server"
    fi
    ;;

  stop)
    if screen -list | grep -q "mcp-server"; then
      screen -S mcp-server -X quit
      echo "Stopped mcp-server"
    else
      echo "mcp-server is not running"
    fi
    ;;

  restart)
    if screen -list | grep -q "mcp-server"; then
      echo "Stopping mcp-server..."
      screen -S mcp-server -X quit
      sleep 1
    fi
    echo "Starting mcp-server..."
    screen -dmS mcp-server sbcl --load mcp-server.lisp
    echo "Restarted mcp-server in screen session 'mcp-server'"
    echo "Attach with: screen -r mcp-server"
    ;;

  status)
    if screen -list | grep -q "mcp-server"; then
      echo "mcp-server is running"
      screen -list | grep "mcp-server"
    else
      echo "mcp-server is not running"
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;

esac
