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
