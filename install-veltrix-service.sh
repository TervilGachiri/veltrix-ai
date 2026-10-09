#!/bin/bash
set -euo pipefail

PROJECT="$(pwd)"
BACKEND="$PROJECT/backend"
PYTHON="$BACKEND/.venv/bin/python"
PLIST="$HOME/Library/LaunchAgents/com.veltrix.ai.backend.plist"
LABEL="com.veltrix.ai.backend"
LOGDIR="$HOME/Library/Logs/VeltrixAI"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Backend Python environment missing."
  exit 1
fi

echo "===== VELTRIX AI BACKEND SERVICE ====="

mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

echo "Checking application imports..."
(
  cd "$BACKEND"
  "$PYTHON" -c "from main import app; print('Backend imports successful')"
)

echo "Stopping previous Veltrix service, if present..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "Checking for existing processes..."

PIDS=$(lsof -tiTCP:8001 -sTCP:LISTEN || true)

if [ -n "$PIDS" ]; then
  for PID in $PIDS; do
    COMMAND=$(ps -p "$PID" -o command= || true)

    if echo "$COMMAND" | grep -Eq 'uvicorn main:app'; then
      echo "Stopping old Veltrix backend PID $PID"
      kill "$PID" 2>/dev/null || true
    else
      echo "ERROR: Port 8001 is used by another process:"
      echo "$COMMAND"
      exit 1
    fi
  done
fi

for i in 1 2 3 4 5; do
  if ! lsof -tiTCP:8001 -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if lsof -tiTCP:8001 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: Port 8001 is still occupied."
  exit 1
fi

echo "Creating macOS background service..."

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>-m</string>
        <string>uvicorn</string>
        <string>main:app</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>8001</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$BACKEND</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOGDIR/backend.log</string>

    <key>StandardErrorPath</key>
    <string>$LOGDIR/backend-error.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST"

echo "Starting managed backend..."

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo ""
echo "===== WAITING FOR BACKEND ====="

READY=0

for i in $(seq 1 20); do
  STATUS=$(curl -sS -o /dev/null \
    -w "%{http_code}" \
    --max-time 2 \
    http://127.0.0.1:8001/openapi.json 2>/dev/null || true)

  if [ "$STATUS" = "200" ]; then
    READY=1
    break
  fi

  sleep 1
done

if [ "$READY" -eq 1 ]; then
  echo "BACKEND ONLINE: HTTP 200"

  echo ""
  echo "===== TEST AUTHENTICATION ====="

  curl -sS --max-time 10 \
    -X POST \
    http://127.0.0.1:8001/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"email":"diagnostic@example.invalid","password":"invalid-test-password"}' \
    -w '\nHTTP %{http_code}\n'

  echo ""
  echo "Service installed successfully."

else
  echo "Backend did not become ready."
  echo "===== ERROR LOG ====="
  tail -n 40 "$LOGDIR/backend-error.log"
  exit 1
fi
