#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "====================================="
echo " VELTRIX AI — WORKSPACE SECURITY"
echo "====================================="

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="backups/workspace-security-$STAMP"
mkdir -p "$BACKUP"

PYTHON="backend/.venv/bin/python"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Backend virtual environment missing."
  exit 1
fi

cp backend/main.py "$BACKUP/main.py"

if [ -f backend/workspace_security.py ]; then
  cp backend/workspace_security.py \
    "$BACKUP/workspace_security.py"
fi

echo "===== BACKING UP DATABASE ====="

"$PYTHON" - "$BACKUP/database.db" <<'PY'
import sqlite3
import sys
from pathlib import Path

source = Path("backend/veltrix_auth.db").resolve()
target = Path(sys.argv[1]).resolve()

if not source.is_file():
    raise SystemExit("Authentication database not found.")

with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as old:
    with sqlite3.connect(target) as new:
        old.backup(new)

with sqlite3.connect(target) as check:
    result = check.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        raise SystemExit("Database backup integrity check failed.")

print("Database backup verified.")
PY

echo "===== INSTALLING SECURITY MODULE ====="

cat > backend/workspace_security.py <<'PY'
import re
import time

from fastapi import APIRouter, Cookie, HTTPException, Request
from auth_routes import db, get_user, require_user
from enterprise_routes import require_membership

router = APIRouter(
    prefix="/api/security",
    tags=["Workspace Security"]
)

ORG_ROUTE = re.compile(
    r"^/api/(?:enterprise|v2)/organizations/"
    r"([^/]+)(?:/|$)"
)

AUDIT_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def initialize():
    with db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS workspace_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                organization_id TEXT NOT NULL,
                actor_id TEXT NOT NULL,
                action TEXT NOT NULL,
                result_status INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS
            idx_workspace_audit_org
            ON workspace_audit(organization_id, id)
        """)


initialize()


def classify_action(method: str, path: str) -> str:
    if "/invites" in path:
        return "invitation_created"
    if "/members/" in path and method == "DELETE":
        return "member_removed"
    if "/projects/" in path and path.endswith("/messages"):
        return "project_message_added"
    if path.endswith("/projects") and method == "POST":
        return "project_created"
    return "organization_updated"


async def workspace_audit_middleware(request: Request, call_next):
    """
    Record successful organization-scoped writes only.

    Never store message bodies, invitation codes,
    session cookies, document text or passwords.
    """
    path = request.url.path
    match = ORG_ROUTE.match(path)

    response = await call_next(request)

    if not match or request.method not in AUDIT_METHODS:
        return response

    # Failed requests are not written to the success audit log.
    if response.status_code < 200 or response.status_code >= 300:
        return response

    token = request.cookies.get("veltrix_session")
    user = get_user(token)

    if user is None:
        return response

    org_id = match.group(1)

    try:
        with db() as conn:
            conn.execute("""
                INSERT INTO workspace_audit (
                    organization_id,
                    actor_id,
                    action,
                    result_status,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?)
            """, (
                org_id,
                user["id"],
                classify_action(request.method, path),
                response.status_code,
                int(time.time())
            ))
    except Exception:
        # The application response has already been created.
        # Audit-write failure must not turn a successful action
        # into a misleading client error.
        import logging
        logging.exception("Workspace audit logging failed")

    return response


@router.get("/workspaces/{org_id}/access")
def workspace_access(
    org_id: str,
    veltrix_session: str | None = Cookie(default=None)
):
    user = require_user(veltrix_session)

    with db() as conn:
        membership = require_membership(
            conn, org_id, user["id"]
        )

        org = conn.execute("""
            SELECT id, name
            FROM organizations
            WHERE id = ?
        """, (org_id,)).fetchone()

        if org is None:
            raise HTTPException(404, "Organization not found.")

        return {
            "authorized": True,
            "organization_id": org["id"],
            "organization_name": org["name"],
            "role": membership["role"],
            "permissions": {
                "view_projects": True,
                "post_project_messages": True,
                "manage_invitations": membership["role"] in (
                    "owner", "admin"
                ),
                "manage_members": membership["role"] in (
                    "owner", "admin"
                ),
                "view_audit": membership["role"] in (
                    "owner", "admin"
                )
            }
        }


@router.get("/workspaces/{org_id}/audit")
def workspace_audit(
    org_id: str,
    veltrix_session: str | None = Cookie(default=None)
):
    user = require_user(veltrix_session)

    with db() as conn:
        require_membership(
            conn,
            org_id,
            user["id"],
            ("owner", "admin")
        )

        rows = conn.execute("""
            SELECT
                a.id,
                u.name AS actor,
                a.action,
                a.result_status,
                a.created_at
            FROM workspace_audit a
            LEFT JOIN users u ON u.id = a.actor_id
            WHERE a.organization_id = ?
            ORDER BY a.id DESC
            LIMIT 100
        """, (org_id,)).fetchall()

        return {
            "organization_id": org_id,
            "events": [dict(row) for row in rows]
        }


@router.get("/workspaces")
def my_secure_workspaces(
    veltrix_session: str | None = Cookie(default=None)
):
    user = require_user(veltrix_session)

    with db() as conn:
        rows = conn.execute("""
            SELECT
                o.id,
                o.name,
                m.role
            FROM organizations o
            JOIN organization_members m
              ON m.organization_id = o.id
            WHERE m.user_id = ?
            ORDER BY o.created_at DESC
        """, (user["id"],)).fetchall()

        return {
            "workspaces": [dict(row) for row in rows]
        }
PY

echo "===== REGISTERING SECURITY SERVICES ====="

"$PYTHON" - <<'PY'
from pathlib import Path

path = Path("backend/main.py")
source = path.read_text()

imp = (
    "from workspace_security import "
    "router as workspace_security_router, "
    "workspace_audit_middleware"
)

routes = (
    "\napp.include_router(workspace_security_router)\n"
    "app.middleware('http')(workspace_audit_middleware)\n"
)

if imp not in source:
    source = imp + "\n" + source

if "app.include_router(workspace_security_router)" not in source:
    source += routes

compile(source, str(path), "exec")
path.write_text(source)

print("Security routes and auditing registered.")
PY

echo "===== VERIFYING IMPLEMENTATION ====="

if ! (
  cd backend
  .venv/bin/python - <<'PY'
from main import app

paths = set(app.openapi()["paths"])

required = (
    "/api/security/workspaces",
    "/api/security/workspaces/{org_id}/access",
    "/api/security/workspaces/{org_id}/audit",
    "/api/v2/organizations/{org_id}/projects",
    "/api/v2/chat/stream",
    "/api/media/extract"
)

for path in required:
    if path not in paths:
        raise SystemExit(f"FAILED: {path}")
    print(f"PASS: {path}")

from auth_routes import db

with db() as conn:
    tables = {
        row["name"]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }

    assert "workspace_audit" in tables
    assert "organization_members" in tables

print("PASS: Workspace audit database")
PY
); then
  echo "Validation failed. Restoring backend entrypoint."
  cp "$BACKUP/main.py" backend/main.py
  if [ -f "$BACKUP/workspace_security.py" ]; then
    cp "$BACKUP/workspace_security.py" \
      backend/workspace_security.py
  else
    rm -f backend/workspace_security.py
  fi
  exit 1
fi

echo "===== FRONTEND REGRESSION BUILD ====="

if ! (cd frontend && npm run build); then
  echo "Frontend build failed."
  echo "Security entrypoint changes will be restored."
  cp "$BACKUP/main.py" backend/main.py
  if [ -f "$BACKUP/workspace_security.py" ]; then
    cp "$BACKUP/workspace_security.py" \
      backend/workspace_security.py
  else
    rm -f backend/workspace_security.py
  fi
  exit 1
fi

echo "===== RESTARTING BACKEND ====="

SERVICE="gui/$(id -u)/com.veltrix.ai.backend"

if launchctl print "$SERVICE" >/dev/null 2>&1; then
  launchctl kickstart -k "$SERVICE"
else
  echo "Managed backend service not found."
fi

echo "===== WAITING FOR HEALTH CHECK ====="

READY=0

for i in 1 2 3 4 5 6 7 8 9 10; do
  STATUS=$(curl -sS --max-time 3 \
    -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:8001/api/health \
    2>/dev/null || true)

  if [ "$STATUS" = "200" ]; then
    READY=1
    break
  fi

  sleep 1
done

if [ "$READY" -eq 1 ]; then
  echo "PASS: Backend HTTP 200"
else
  echo "WARNING: Backend did not pass health check."
  echo "Check ~/Library/Logs/VeltrixAI/backend-error.log"
fi

echo ""
echo "====================================="
echo " SECURITY FOUNDATION INSTALLED"
echo "====================================="
echo "Organization access checks: Added"
echo "Organization audit events: Added"
echo "Owner/admin audit permissions: Added"
echo "Team project membership checks: Preserved"
echo "Personal chat storage: Unchanged"
echo "Document Intelligence: Unchanged"
echo "Live AI: Unchanged"
echo "Database backup: $BACKUP/database.db"
echo "====================================="
