#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "===== VELTRIX AI BATCH 3 ====="

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

cp backend/main.py "backups/main-before-batch3-$STAMP.py"
cp frontend/src/App.tsx "backups/App-before-batch3-$STAMP.tsx"

echo "Backups created."

cat > backend/platform_security.py <<'PY'
import os
import threading
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

# Local development limiter.
# Production deployments require a shared limiter such as Redis.
_attempts = defaultdict(deque)
_lock = threading.Lock()

ALLOWED_ORIGINS = {
    "http://localhost:5173",
    "http://127.0.0.1:5173",
}

extra_origin = os.getenv("VELTRIX_FRONTEND_ORIGIN", "").rstrip("/")
if extra_origin:
    ALLOWED_ORIGINS.add(extra_origin)

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


def rate_limited(ip: str, path: str) -> bool:
    if path == "/api/auth/login":
        limit, window = 8, 300
    elif path == "/api/auth/register":
        limit, window = 5, 3600
    else:
        return False

    key = (ip, path)
    now = time.monotonic()

    with _lock:
        hits = _attempts[key]

        while hits and now - hits[0] > window:
            hits.popleft()

        if len(hits) >= limit:
            return True

        hits.append(now)

    return False


async def security_middleware(request: Request, call_next):
    path = request.url.path
    method = request.method

    if path.startswith("/api/") and method not in SAFE_METHODS:
        origin = request.headers.get("origin")
        has_session = bool(request.cookies.get("veltrix_session"))

        # Protect browser requests using session cookies.
        if origin and origin.rstrip("/") not in ALLOWED_ORIGINS:
            return JSONResponse(
                status_code=403,
                content={"detail": "Untrusted request origin."},
            )

        if has_session and not origin:
            return JSONResponse(
                status_code=403,
                content={"detail": "Request origin required."},
            )

        if path in {"/api/auth/login", "/api/auth/register"}:
            ip = request.client.host if request.client else "unknown"

            if rate_limited(ip, path):
                return JSONResponse(
                    status_code=429,
                    content={
                        "detail": "Too many attempts. Try again later."
                    },
                    headers={"Retry-After": "300"},
                )

    response = await call_next(request)

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Permissions-Policy"] = (
        "camera=(), geolocation=(), microphone=()"
    )

    return response
PY

cat > backend/platform_admin.py <<'PY'
import sqlite3
import time

from fastapi import APIRouter, Cookie, HTTPException

from auth_routes import db, require_user

router = APIRouter(
    prefix="/api/platform",
    tags=["Platform Administration"],
)


def require_admin(token):
    user = require_user(token)

    if user["role"] != "admin":
        raise HTTPException(
            status_code=403,
            detail="Platform administrator access required.",
        )

    return user


def initialize():
    with db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS platform_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                actor_id TEXT NOT NULL,
                action TEXT NOT NULL,
                detail TEXT,
                created_at INTEGER NOT NULL
            )
        """)


initialize()


@router.get("/overview")
def overview(
    veltrix_session: str | None = Cookie(default=None),
):
    admin = require_admin(veltrix_session)

    with db() as conn:
        users = conn.execute(
            "SELECT COUNT(*) FROM users"
        ).fetchone()[0]

        conversations = conn.execute(
            "SELECT COUNT(*) FROM conversations"
        ).fetchone()[0]

        organizations = conn.execute(
            "SELECT COUNT(*) FROM organizations"
        ).fetchone()[0]

        members = conn.execute(
            "SELECT COUNT(*) FROM organization_members"
        ).fetchone()[0]

        active_sessions = conn.execute(
            "SELECT COUNT(*) FROM sessions WHERE expires_at > ?",
            (int(time.time()),),
        ).fetchone()[0]

    return {
        "users": users,
        "conversations": conversations,
        "organizations": organizations,
        "memberships": members,
        "active_sessions": active_sessions,
        "administrator": admin["name"],
    }


@router.get("/users")
def platform_users(
    veltrix_session: str | None = Cookie(default=None),
):
    require_admin(veltrix_session)

    with db() as conn:
        users = conn.execute("""
            SELECT id, name, email, role, created_at
            FROM users
            ORDER BY created_at DESC
            LIMIT 100
        """).fetchall()

    return {"users": [dict(row) for row in users]}


@router.get("/audit")
def audit_events(
    veltrix_session: str | None = Cookie(default=None),
):
    require_admin(veltrix_session)

    with db() as conn:
        events = conn.execute("""
            SELECT id, actor_id, action, detail, created_at
            FROM platform_audit
            ORDER BY id DESC
            LIMIT 100
        """).fetchall()

    return {"events": [dict(row) for row in events]}
PY

python3 - <<'PY'
from pathlib import Path

p = Path("backend/main.py")
source = p.read_text()

imports = [
    "from platform_admin import router as platform_router",
    "from platform_security import security_middleware",
]

for statement in imports:
    if statement not in source:
        lines = source.splitlines(keepends=True)
        position = 0

        for i, line in enumerate(lines):
            if line.startswith("from __future__ import"):
                position = i + 1

        lines.insert(position, statement + "\n")
        source = "".join(lines)

if "app.include_router(platform_router)" not in source:
    source += "\napp.include_router(platform_router)\n"

if "app.middleware('http')(security_middleware)" not in source:
    source += "\napp.middleware('http')(security_middleware)\n"

compile(source, str(p), "exec")
p.write_text(source)

print("Security middleware and platform APIs registered.")
PY

echo ""
echo "===== VERIFY BACKEND ====="

backend/.venv/bin/python -m py_compile \
  backend/main.py \
  backend/auth_routes.py \
  backend/account_routes.py \
  backend/conversation_routes.py \
  backend/enterprise_routes.py \
  backend/platform_security.py \
  backend/platform_admin.py

echo "PASS: Backend syntax"

echo ""
echo "===== VERIFY FRONTEND ====="

(
  cd frontend
  npm run build
)

echo ""
echo "BATCH 3 BACKEND INSTALLED SUCCESSFULLY"
