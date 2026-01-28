#!/bin/bash
set -e

# Get values from environment or use defaults
PLAY_HTTP_ADDRESS=${PLAY_HTTP_ADDRESS:-0.0.0.0}
PLAY_HTTP_PORT=${PLAY_HTTP_PORT:-9000}
API_BASE_URL=${API_BASE_URL:-http://localhost:9000}

echo "Starting Reversi Game Engine..."
echo "Configuration:"
echo "  - Address: $PLAY_HTTP_ADDRESS"
echo "  - Port: $PLAY_HTTP_PORT"
echo "  - Base URL: $API_BASE_URL"
echo "  - Config: /app/conf/application.conf"
echo ""

# Run the application with necessary Java module options for Java 17+
exec java \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.lang.invoke=ALL-UNNAMED \
  -Dplay.server.provider=play.core.server.NettyServerProvider \
  -Dplay.server.http.address=$PLAY_HTTP_ADDRESS \
  -Dplay.server.http.port=$PLAY_HTTP_PORT \
  -Dconfig.file=/app/conf/application.conf \
  -Dplay.server.pidfile.path=/dev/null \
  -cp "/app/lib/*:/app/conf" \
  play.core.server.ProdServerStart
