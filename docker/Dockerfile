FROM ubuntu:24.04

LABEL maintainer="sean.watkins@gmail.com"
LABEL description="OctopusBaby — Lisp-native MCP server in a container"
LABEL version="0.1"

ENV DEBIAN_FRONTEND=noninteractive

# Install SBCL and dependencies
RUN apt-get update && apt-get install -y \
    sbcl \
    cl-quicklisp \
    curl \
    wget \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Quicklisp
RUN sbcl --non-interactive \
    --load /usr/share/common-lisp/source/quicklisp/quicklisp.lisp \
    --eval "(quicklisp-quickstart:install :path \"/quicklisp/\")" \
    --eval "(quit)"

# Add Quicklisp to SBCL init
RUN echo '(load "/quicklisp/setup.lisp")' > /root/.sbclrc

# Pre-load all dependencies so container startup is fast
RUN sbcl --non-interactive \
    --eval "(load \"/quicklisp/setup.lisp\")" \
    --eval "(ql:quickload '(:hunchentoot :dexador :yason :cl-base64 :ironclad :usocket :bordeaux-threads) :silent t)" \
    --eval "(quit)"

WORKDIR /app

# Copy server files (build context is the mcp-server/ parent directory)
COPY mcp-server.lisp .
COPY tools.lisp .
COPY docker/start.sh .
RUN chmod +x start.sh

# Runtime config via environment — override with -e flags or mount an .env file
ENV MCP_PORT=8765
ENV MCP_SERVER_URL=http://localhost:8765
ENV TOOLS_FILE=/app/tools.lisp
ENV LOG_FILE=/var/log/octopus-mcp.log

# Mount this for persistent tools and logs across restarts
VOLUME ["/app/data"]

EXPOSE 8765

CMD ["./start.sh"]
