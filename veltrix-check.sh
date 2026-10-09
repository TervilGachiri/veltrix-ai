#!/bin/bash
set -u

cd "$(dirname "$0")" || exit 1

STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="veltrix-check-$STAMP.txt"

echo "================================="
echo "   VELTRIX AI DEVELOPMENT CHECK"
echo "================================="

mkdir -p backups

echo ""
echo "[1/7] Backing up project..."

tar -czf "backups/veltrix-$STAMP.tar.gz" \
  --exclude="node_modules" \
  --exclude=".venv" \
  --exclude="dist" \
  --exclude="__pycache__" \
  --exclude="backups" \
  --exclude=".git" \
  --exclude="*.db" \
  --exclude=".env" \
  backend frontend README.md 2>/dev/null

echo "Project code backed up."
echo "Existing databases and secrets remain unchanged."

echo ""
echo "[2/7] Checking Python backend..."

if backend/.venv/bin/python -m py_compile \
  backend/main.py \
  backend/auth_routes.py \
  backend/conversation_routes.py; then
  echo "PASS: Python syntax"
else
  echo "FAIL: Python syntax"
fi

echo ""
echo "[3/7] Checking frontend..."

(
  cd frontend || exit 1
  npm run build
)

echo ""
echo "[4/7] Checking Ollama..."

curl -fsS --max-time 5 \
  http://127.0.0.1:11434/api/tags \
  >/dev/null \
  && echo "PASS: Ollama responding" \
  || echo "WARNING: Ollama unavailable"

echo ""
echo "[5/7] Checking backend..."

curl -fsS --max-time 5 \
  http://127.0.0.1:8001/openapi.json \
  >/dev/null \
  && echo "PASS: Backend responding" \
  || echo "WARNING: Backend not running"

echo ""
echo "[6/7] Checking API endpoints..."

for endpoint in \
  /api/auth/me \
  /api/conversations
do
  STATUS=$(curl -s -o /dev/null \
    -w "%{http_code}" \
    --max-time 5 \
    "http://127.0.0.1:8001$endpoint")

  echo "$endpoint : HTTP $STATUS"
done

echo ""
echo "[7/7] Checking security files..."

for file in \
  backend/.env \
  backend/auth_routes.py \
  backend/conversation_routes.py \
  frontend/src/AuthScreen.tsx
do
  if [ -f "$file" ]; then
    echo "FOUND: $file"
  else
    echo "MISSING: $file"
  fi
done

{
  echo "VELTRIX AI DEVELOPMENT REPORT"
  echo "Date: $(date)"
  echo ""
  echo "Python files:"
  find backend -maxdepth 1 -name "*.py" -print
  echo ""
  echo "Frontend files:"
  find frontend/src -maxdepth 2 -type f -print
  echo ""
  echo "Available API paths:"
  curl -fsS --max-time 5 \
    http://127.0.0.1:8001/openapi.json \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("paths",{})))' \
    2>/dev/null || echo "Backend unavailable"
} > "$REPORT"

echo ""
echo "================================="
echo "VELTRIX AI CHECK COMPLETE"
echo "Report: $REPORT"
echo "================================="
