#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")" || exit 1

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="backups/integration-$STAMP"
REPORT="$DEST/readiness-report.txt"

mkdir -p "$DEST"

exec > >(tee "$REPORT") 2>&1

PASS=0
FAIL=0
WARN=0

ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

warn() {
  echo "CHECK: $1"
  WARN=$((WARN + 1))
}

check_file() {
  if [ -f "$1" ]; then
    ok "$1 exists"
  else
    bad "$1 missing"
  fi
}

check_api() {
  NAME="$1"
  URL="$2"
  EXPECTED="$3"

  STATUS=$(curl -sS \
    --max-time 8 \
    -o /dev/null \
    -w "%{http_code}" \
    "$URL" 2>/dev/null || true)

  if [ "$STATUS" = "$EXPECTED" ]; then
    ok "$NAME (HTTP $STATUS)"
  else
    bad "$NAME (HTTP $STATUS, expected $EXPECTED)"
  fi
}

echo "======================================"
echo "VELTRIX AI — INTEGRATION READINESS"
echo "======================================"

echo ""
echo "1. BACKUP EXISTING SYSTEM"

for FILE in \
  backend/main.py \
  backend/auth_routes.py \
  backend/conversation_routes.py \
  backend/enterprise_routes.py \
  backend/media_routes.py \
  frontend/src/App.tsx \
  frontend/src/MediaTools.tsx \
  frontend/src/styles.css
do
  if [ -f "$FILE" ]; then
    mkdir -p "$DEST/$(dirname "$FILE")"
    cp "$FILE" "$DEST/$FILE"
  fi
done

if [ -f backend/veltrix_auth.db ]; then
  if backend/.venv/bin/python - "$DEST/auth-backup.db" <<'PY'
import sqlite3
import sys
from pathlib import Path

source = Path("backend/veltrix_auth.db").resolve()
target = Path(sys.argv[1]).resolve()

with sqlite3.connect(
    f"file:{source}?mode=ro", uri=True
) as original:
    with sqlite3.connect(target) as backup:
        original.backup(backup)

with sqlite3.connect(
    f"file:{target}?mode=ro", uri=True
) as check:
    assert check.execute(
        "PRAGMA integrity_check"
    ).fetchone()[0] == "ok"
PY
  then
    ok "SQLite database backed up and verified"
  else
    bad "SQLite database backup"
  fi
else
  bad "Authentication database missing"
fi

echo ""
echo "2. CORE BACKEND MODULES"

for FILE in \
  backend/main.py \
  backend/auth_routes.py \
  backend/conversation_routes.py \
  backend/account_routes.py \
  backend/enterprise_routes.py \
  backend/platform_admin.py \
  backend/platform_security.py \
  backend/media_routes.py
do
  check_file "$FILE"
done

echo ""
echo "3. PYTHON SYNTAX"

if backend/.venv/bin/python -m compileall -q backend; then
  ok "Python compilation"
else
  bad "Python compilation"
fi

echo ""
echo "4. FRONTEND COMPONENTS"

for FILE in \
  frontend/src/App.tsx \
  frontend/src/AuthScreen.tsx \
  frontend/src/MediaTools.tsx \
  frontend/src/EnterprisePanel.tsx \
  frontend/src/PlatformAdmin.tsx
do
  check_file "$FILE"
done

echo ""
echo "5. FRONTEND BUILD"

if (
  cd frontend
  npm run build
); then
  ok "React/TypeScript production build"
else
  bad "React/TypeScript production build"
fi

echo ""
echo "6. API CONNECTIVITY"

check_api \
  "Backend API" \
  "http://127.0.0.1:8001/openapi.json" \
  "200"

check_api \
  "Frontend" \
  "http://localhost:5173/" \
  "200"

check_api \
  "Frontend API proxy" \
  "http://localhost:5173/openapi.json" \
  "200"

echo ""
echo "7. AUTHENTICATION ROUTES"

# Without cookies, 401 is expected.
check_api \
  "Session protection" \
  "http://127.0.0.1:8001/api/auth/me" \
  "401"

check_api \
  "Conversation protection" \
  "http://127.0.0.1:8001/api/conversations" \
  "401"

echo ""
echo "8. MEDIA API REGISTRATION"

if curl -fsS \
  http://127.0.0.1:8001/openapi.json \
  | backend/.venv/bin/python -c '
import sys,json
p=json.load(sys.stdin)["paths"]
expected=[
 "/api/media/extract",
 "/api/media/vision",
 "/api/media/export"
]
missing=[x for x in expected if x not in p]
if missing:
 print("Missing media routes:", missing)
 sys.exit(1)
print("All media API routes registered")
'; then
  ok "Media API registration"
else
  bad "Media API registration"
fi

echo ""
echo "9. MULTIMEDIA FRONTEND"

if grep -q '<MediaTools' frontend/src/App.tsx; then
  ok "Multimedia toolbar connected"
else
  bad "Multimedia toolbar not connected"
fi

echo ""
echo "10. OLLAMA MODELS"

if command -v ollama >/dev/null 2>&1; then
  ollama list

  if ollama list | grep -q 'qwen3:1.7b'; then
    ok "Fast model installed"
  else
    warn "Fast model not detected"
  fi

  if ollama list | grep -q 'qwen3:4b'; then
    ok "Smart model installed"
  else
    warn "Smart model not detected"
  fi

  if ollama list | grep -q 'gemma3:4b'; then
    ok "Gemma vision model installed"
  else
    warn "Gemma vision model not yet installed"
  fi
else
  bad "Ollama command unavailable"
fi

echo ""
echo "11. ANDROID PROJECT"

if [ -d frontend/android ]; then
  ok "Android project exists"
else
  warn "Android project not detected"
fi

echo ""
echo "12. DEVELOPMENT FEATURE INVENTORY"

if grep -Eq 'StreamingResponse|text/event-stream' \
  backend/main.py; then
  warn "Streaming code found; functional testing still required"
else
  warn "AI response streaming implementation not detected"
fi

if grep -Rql 'api/conversations/sync' \
  frontend/src/App.tsx; then
  warn "Conversation sync present; concurrency audit required"
fi

echo ""
echo "======================================"
echo "RESULTS"
echo "======================================"

echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Further checks: $WARN"
echo ""
echo "Backup folder: $DEST"
echo "Report: $REPORT"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "STATUS: NOT READY — repair failed checks."
else
  echo ""
  echo "STATUS: BASIC LOCAL CHECKS PASSED."
  echo "Production security and feature tests still required."
fi
