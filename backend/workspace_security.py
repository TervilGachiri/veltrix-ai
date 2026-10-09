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
