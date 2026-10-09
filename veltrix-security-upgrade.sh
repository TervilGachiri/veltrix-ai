#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "===== VELTRIX AI SECURITY UPGRADE ====="

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

# Preserve code and the existing account database.
cp backend/main.py "backups/main-$STAMP.py"
cp backend/auth_routes.py "backups/auth-$STAMP.py"

if [ -f backend/veltrix_auth.db ]; then
  cp backend/veltrix_auth.db \
    "backups/veltrix-auth-$STAMP.db"
  chmod 600 "backups/veltrix-auth-$STAMP.db"
fi

cat > backend/account_routes.py <<'PY'
import hashlib
import hmac
import sqlite3
import time

from fastapi import APIRouter, Cookie, HTTPException, Response
from pydantic import BaseModel, Field

from auth_routes import (
    DATABASE,
    COOKIE_NAME,
    db,
    get_user,
    hash_password,
    require_user,
)

router = APIRouter(prefix="/api/account", tags=["Account"])


class ProfileUpdate(BaseModel):
    name: str = Field(min_length=2, max_length=100)


class PasswordChange(BaseModel):
    current_password: str
    new_password: str = Field(min_length=12, max_length=128)


def init_audit():
    with db() as connection:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS security_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                action TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)


init_audit()


def audit(connection, user_id, action):
    connection.execute(
        """INSERT INTO security_audit
           (user_id, action, created_at)
           VALUES (?, ?, ?)""",
        (user_id, action, int(time.time())),
    )


@router.get("/profile")
def profile(
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)
    return {
        "id": user["id"],
        "name": user["name"],
        "email": user["email"],
        "role": user["role"],
    }


@router.patch("/profile")
def update_profile(
    data: ProfileUpdate,
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)
    name = data.name.strip()

    if len(name) < 2:
        raise HTTPException(400, "Enter a valid name.")

    with db() as connection:
        connection.execute(
            "UPDATE users SET name = ? WHERE id = ?",
            (name, user["id"]),
        )
        audit(connection, user["id"], "profile_updated")

    return {"success": True, "name": name}


@router.post("/change-password")
def change_password(
    data: PasswordChange,
    response: Response,
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)

    if data.current_password == data.new_password:
        raise HTTPException(
            400,
            "Choose a different password.",
        )

    with db() as connection:
        row = connection.execute(
            "SELECT salt, password_hash FROM users WHERE id = ?",
            (user["id"],),
        ).fetchone()

        if not row:
            raise HTTPException(401, "Account not found.")

        candidate = hash_password(
            data.current_password,
            row["salt"],
        )

        if not hmac.compare_digest(
            candidate, row["password_hash"]
        ):
            raise HTTPException(
                400,
                "Current password is incorrect.",
            )

        import secrets
        salt = secrets.token_bytes(16)
        new_hash = hash_password(data.new_password, salt)

        connection.execute(
            """UPDATE users
               SET salt = ?, password_hash = ?
               WHERE id = ?""",
            (salt, new_hash, user["id"]),
        )

        # Changing passwords invalidates all sessions.
        connection.execute(
            "DELETE FROM sessions WHERE user_id = ?",
            (user["id"],),
        )

        audit(connection, user["id"], "password_changed")

    response.delete_cookie(COOKIE_NAME, path="/")

    return {
        "success": True,
        "message": "Password changed. Please sign in again.",
    }


@router.post("/logout-all")
def logout_all(
    response: Response,
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)

    with db() as connection:
        connection.execute(
            "DELETE FROM sessions WHERE user_id = ?",
            (user["id"],),
        )
        audit(connection, user["id"], "all_sessions_revoked")

    response.delete_cookie(COOKIE_NAME, path="/")

    return {"success": True}
PY

python3 - <<'PY'
from pathlib import Path

p = Path("backend/main.py")
code = p.read_text()

statement = "from account_routes import router as account_router"

if statement not in code:
    lines = code.splitlines(keepends=True)
    position = 0

    for index, line in enumerate(lines):
        if line.startswith("from __future__ import"):
            position = index + 1

    lines.insert(position, statement + "\n")
    code = "".join(lines)

if "app.include_router(account_router)" not in code:
    code += "\napp.include_router(account_router)\n"

if "async def veltrix_security_headers" not in code:
    code += '''

@app.middleware("http")
async def veltrix_security_headers(request, call_next):
    response = await call_next(request)

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = (
        "camera=(), microphone=(), geolocation=()"
    )
    response.headers["Cache-Control"] = "no-store"

    return response
'''

compile(code, str(p), "exec")
p.write_text(code)
print("Account routes and security headers installed.")
PY

# Ensure database and environment remain private.
touch .gitignore

cat >> .gitignore <<'EOF'

# Veltrix AI security
backend/.env
backend/.venv/
backend/veltrix_auth.db
backend/veltrix_auth.db-*
backups/
__pycache__/
*.pyc
EOF

echo ""
echo "===== VERIFY PYTHON ====="

backend/.venv/bin/python -m py_compile \
  backend/main.py \
  backend/auth_routes.py \
  backend/account_routes.py \
  backend/conversation_routes.py

echo "PASS: Python syntax"

echo ""
echo "===== VERIFY FRONTEND ====="

(
  cd frontend
  npm run build
)

echo ""
echo "===== RESULT ====="
echo "Account security upgrade installed."
echo "Existing Ollama configuration preserved."
echo "Existing frontend preserved."
echo "Database backup created."
