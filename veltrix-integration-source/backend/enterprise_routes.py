import hashlib
import secrets
import sqlite3
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, Cookie, HTTPException
from pydantic import BaseModel, Field

from auth_routes import require_user, db

router = APIRouter(
    prefix="/api/enterprise",
    tags=["Enterprise"],
)

INVITE_LIFETIME = 60 * 60 * 24
MAX_MEMBERS = 100


def initialize():
    with db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS organizations (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_by TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS organization_members (
                organization_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (
                    role IN ('owner','admin','member')
                ),
                joined_at INTEGER NOT NULL,
                PRIMARY KEY (organization_id, user_id),
                FOREIGN KEY (organization_id)
                    REFERENCES organizations(id),
                FOREIGN KEY (user_id)
                    REFERENCES users(id)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS organization_invites (
                token_hash TEXT PRIMARY KEY,
                organization_id TEXT NOT NULL,
                created_by TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                used_by TEXT
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_members_user
            ON organization_members(user_id)
        """)


initialize()


class CreateOrganization(BaseModel):
    name: str = Field(min_length=2, max_length=100)


class JoinOrganization(BaseModel):
    code: str = Field(min_length=20, max_length=200)


def identity(cookie):
    return require_user(cookie)


def membership(conn, org_id, user_id):
    return conn.execute("""
        SELECT role FROM organization_members
        WHERE organization_id = ? AND user_id = ?
    """, (org_id, user_id)).fetchone()


def require_membership(conn, org_id, user_id, roles=None):
    row = membership(conn, org_id, user_id)
    if row is None:
        raise HTTPException(404, "Organization not found.")
    if roles and row["role"] not in roles:
        raise HTTPException(403, "Insufficient permissions.")
    return row


@router.post("/organizations", status_code=201)
def create_organization(
    data: CreateOrganization,
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)
    name = data.name.strip()

    if len(name) < 2:
        raise HTTPException(400, "Invalid organization name.")

    org_id = str(uuid.uuid4())
    now = int(time.time())

    with db() as conn:
        conn.execute("""
            INSERT INTO organizations
            (id, name, created_by, created_at)
            VALUES (?, ?, ?, ?)
        """, (org_id, name, user["id"], now))

        conn.execute("""
            INSERT INTO organization_members
            (organization_id, user_id, role, joined_at)
            VALUES (?, ?, 'owner', ?)
        """, (org_id, user["id"], now))

    return {
        "id": org_id,
        "name": name,
        "role": "owner",
    }


@router.get("/organizations")
def list_organizations(
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)

    with db() as conn:
        rows = conn.execute("""
            SELECT o.id, o.name, m.role
            FROM organizations o
            JOIN organization_members m
              ON m.organization_id = o.id
            WHERE m.user_id = ?
            ORDER BY o.created_at DESC
        """, (user["id"],)).fetchall()

    return {"organizations": [dict(row) for row in rows]}


@router.get("/organizations/{org_id}/members")
def list_members(
    org_id: str,
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)

    with db() as conn:
        require_membership(conn, org_id, user["id"])

        members = conn.execute("""
            SELECT u.id, u.name, u.email, m.role
            FROM organization_members m
            JOIN users u ON u.id = m.user_id
            WHERE m.organization_id = ?
            ORDER BY
              CASE m.role
                WHEN 'owner' THEN 0
                WHEN 'admin' THEN 1
                ELSE 2
              END, u.name
        """, (org_id,)).fetchall()

    return {"members": [dict(row) for row in members]}


@router.post("/organizations/{org_id}/invites")
def create_invite(
    org_id: str,
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)
    code = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(code.encode()).hexdigest()

    with db() as conn:
        require_membership(
            conn, org_id, user["id"], ("owner", "admin")
        )

        count = conn.execute("""
            SELECT COUNT(*) AS total
            FROM organization_members
            WHERE organization_id = ?
        """, (org_id,)).fetchone()["total"]

        if count >= MAX_MEMBERS:
            raise HTTPException(409, "Member limit reached.")

        conn.execute("""
            INSERT INTO organization_invites
            (token_hash, organization_id, created_by, expires_at)
            VALUES (?, ?, ?, ?)
        """, (
            token_hash,
            org_id,
            user["id"],
            int(time.time()) + INVITE_LIFETIME,
        ))

    return {
        "code": code,
        "expires_in_hours": 24,
        "role": "member",
    }


@router.post("/join")
def join_organization(
    data: JoinOrganization,
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)
    token_hash = hashlib.sha256(
        data.code.strip().encode()
    ).hexdigest()
    now = int(time.time())

    with db() as conn:
        invite = conn.execute("""
            SELECT organization_id
            FROM organization_invites
            WHERE token_hash = ?
              AND used_at IS NULL
              AND expires_at > ?
        """, (token_hash, now)).fetchone()

        if not invite:
            raise HTTPException(400, "Invalid or expired invitation.")

        org_id = invite["organization_id"]

        if membership(conn, org_id, user["id"]):
            raise HTTPException(
                409, "Already a member of this organization."
            )

        total = conn.execute("""
            SELECT COUNT(*) AS total
            FROM organization_members
            WHERE organization_id = ?
        """, (org_id,)).fetchone()["total"]

        if total >= MAX_MEMBERS:
            raise HTTPException(409, "Member limit reached.")

        # Claim the one-use invitation atomically.
        claimed = conn.execute("""
            UPDATE organization_invites
            SET used_at = ?, used_by = ?
            WHERE token_hash = ?
              AND used_at IS NULL
              AND expires_at > ?
        """, (now, user["id"], token_hash, now))

        if claimed.rowcount != 1:
            raise HTTPException(409, "Invitation already used.")

        conn.execute("""
            INSERT INTO organization_members
            (organization_id, user_id, role, joined_at)
            VALUES (?, ?, 'member', ?)
        """, (org_id, user["id"], now))

    return {"success": True, "organization_id": org_id}


@router.delete("/organizations/{org_id}/members/{member_id}")
def remove_member(
    org_id: str,
    member_id: str,
    veltrix_session: str | None = Cookie(default=None),
):
    user = identity(veltrix_session)

    with db() as conn:
        actor = require_membership(
            conn, org_id, user["id"], ("owner", "admin")
        )
        target = require_membership(conn, org_id, member_id)

        if target["role"] == "owner":
            raise HTTPException(403, "Cannot remove organization owner.")

        if target["role"] == "admin" and actor["role"] != "owner":
            raise HTTPException(403, "Only an owner can remove an admin.")

        conn.execute("""
            DELETE FROM organization_members
            WHERE organization_id = ? AND user_id = ?
        """, (org_id, member_id))

    return {"success": True}
