#!/bin/bash
set -e

cd "$(dirname "$0")/backend"

echo "Starting Veltrix AI backend..."

if lsof -tiTCP:8001 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 8001 is already occupied."
  echo "Checking the existing server..."
else
  nohup .venv/bin/python -m uvicorn main:app \
    --host 127.0.0.1 \
    --port 8001 \
    > /tmp/veltrix-backend.log 2>&1 &
fi

echo ""
echo "Checking server startup..."

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS --max-time 3 \
    http://127.0.0.1:8001/openapi.json >/dev/null 2>&1; then
    echo "SUCCESS: Veltrix AI backend is running."
    break
  fi

  sleep 1
done

echo ""
echo "Authentication endpoint:"
curl -s -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://127.0.0.1:8001/api/auth/me

echo ""
echo "Conversation endpoint:"
curl -s -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://127.0.0.1:8001/api/conversations

echo ""
echo "Backend log:"
tail -n 12 /tmp/veltrix-backend.log
