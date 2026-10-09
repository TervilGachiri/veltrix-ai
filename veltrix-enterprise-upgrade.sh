#!/bin/bash
set -e

cd "$(dirname "$0")"
STAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p backups

cp backend/main.py "backups/main-enterprise-$STAMP.py"
cp frontend/src/App.tsx "backups/App-enterprise-$STAMP.tsx"
cp frontend/src/styles.css "backups/styles-enterprise-$STAMP.css"

# Preserve the SQLite database while it is in use.
# SQLite's backup API creates a consistent backup.
backend/.venv/bin/python - <<'PY'
import sqlite3
from pathlib import Path

source = Path("backend/veltrix_auth.db")
if source.exists():
    import time
    target = Path("backups") / f"veltrix-db-{int(time.time())}.db"
    with sqlite3.connect(source) as src:
        with sqlite3.connect(target) as dest:
            src.backup(dest)
    target.chmod(0o600)
    print("Database backup completed.")
PY

cat > backend/enterprise_routes.py <<'PY'
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
PY

python3 - <<'PY'
from pathlib import Path

p = Path("backend/main.py")
source = p.read_text()

statement = (
    "from enterprise_routes import router as enterprise_router"
)

if statement not in source:
    lines = source.splitlines(keepends=True)
    position = 0
    for i, line in enumerate(lines):
        if line.startswith("from __future__ import"):
            position = i + 1
    lines.insert(position, statement + "\n")
    source = "".join(lines)

if "app.include_router(enterprise_router)" not in source:
    source += "\napp.include_router(enterprise_router)\n"

compile(source, str(p), "exec")
p.write_text(source)

print("Enterprise backend registered.")
PY

echo "Backend enterprise module created."

cat > frontend/src/EnterprisePanel.tsx <<'TSX'
import { useCallback, useEffect, useState } from "react";
import {
  Building2, Plus, Users, ShieldCheck,
  Copy, RefreshCw, UserPlus, Trash2
} from "lucide-react";

type Organization = {
  id: string;
  name: string;
  role: "owner" | "admin" | "member";
};

type Member = {
  id: string;
  name: string;
  email: string;
  role: string;
};

async function api<T>(
  path: string,
  options?: RequestInit
): Promise<T> {
  const response = await fetch(path, {
    ...options,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });

  const result = await response.json();

  if (!response.ok) {
    throw new Error(
      typeof result.detail === "string"
        ? result.detail
        : "Request failed."
    );
  }

  return result as T;
}

export default function EnterprisePanel() {
  const [organizations, setOrganizations] =
    useState<Organization[]>([]);
  const [selected, setSelected] =
    useState<Organization | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [name, setName] = useState("");
  const [invite, setInvite] = useState("");
  const [joinCode, setJoinCode] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  const loadOrganizations = useCallback(async () => {
    const result = await api<{
      organizations: Organization[];
    }>("/api/enterprise/organizations");

    setOrganizations(result.organizations);

    setSelected(previous =>
      result.organizations.find(
        org => org.id === previous?.id
      ) || result.organizations[0] || null
    );
  }, []);

  const loadMembers = useCallback(async (id: string) => {
    const result = await api<{ members: Member[] }>(
      `/api/enterprise/organizations/${encodeURIComponent(id)}/members`
    );
    setMembers(result.members);
  }, []);

  useEffect(() => {
    loadOrganizations().catch(e => setError(e.message));
  }, [loadOrganizations]);

  useEffect(() => {
    if (selected) {
      loadMembers(selected.id).catch(e => setError(e.message));
    } else {
      setMembers([]);
    }
  }, [selected?.id, loadMembers]);

  async function perform(action: () => Promise<void>) {
    setBusy(true);
    setError("");
    setNotice("");

    try {
      await action();
    } catch (e) {
      setError(
        e instanceof Error ? e.message : "Operation failed."
      );
    } finally {
      setBusy(false);
    }
  }

  const manager =
    selected?.role === "owner" ||
    selected?.role === "admin";

  return (
    <div className="page-content enterprise-panel">
      <div className="page-heading">
        <Building2 size={29} />
        <div>
          <h2>Veltrix Enterprise</h2>
          <p>Manage your company's AI workspace and staff.</p>
        </div>
      </div>

      {error && (
        <div className="error-msg" role="alert">{error}</div>
      )}

      {notice && (
        <div className="notice" role="status">{notice}</div>
      )}

      <div className="setting-card">
        <h3><Plus size={19}/> Create organization</h3>
        <p>Set up a new company workspace.</p>
        <form
          className="enterprise-form"
          onSubmit={event => {
            event.preventDefault();
            perform(async () => {
              const result = await api<Organization>(
                "/api/enterprise/organizations",
                {
                  method: "POST",
                  body: JSON.stringify({ name }),
                }
              );
              setName("");
              await loadOrganizations();
              setSelected(result);
              setNotice("Organization created successfully.");
            });
          }}
        >
          <input
            aria-label="Company name"
            placeholder="Company or organization name"
            value={name}
            onChange={event => setName(event.target.value)}
            minLength={2}
            maxLength={100}
            required
          />
          <button
            className="enterprise-action"
            type="submit"
            disabled={busy}
          >
            <Plus size={17}/> Create
          </button>
        </form>
      </div>

      <div className="setting-card">
        <h3><UserPlus size={19}/> Join an organization</h3>
        <p>Enter an invitation code provided by a company administrator.</p>
        <form
          className="enterprise-form"
          onSubmit={event => {
            event.preventDefault();
            perform(async () => {
              await api("/api/enterprise/join", {
                method: "POST",
                body: JSON.stringify({ code: joinCode.trim() }),
              });
              setJoinCode("");
              await loadOrganizations();
              setNotice("You joined the organization.");
            });
          }}
        >
          <input
            aria-label="Invitation code"
            placeholder="Paste invitation code"
            value={joinCode}
            onChange={event => setJoinCode(event.target.value)}
            required
          />
          <button
            className="enterprise-action"
            type="submit"
            disabled={busy}
          >
            Join
          </button>
        </form>
      </div>

      <div className="setting-card">
        <h3><Building2 size={19}/> Your organizations</h3>

        {organizations.length === 0 ? (
          <p>No organizations yet. Create one above or join with an invitation.</p>
        ) : (
          <div className="enterprise-organizations">
            {organizations.map(org => (
              <button
                key={org.id}
                className={
                  selected?.id === org.id ? "chosen" : ""
                }
                onClick={() => setSelected(org)}
              >
                <Building2 size={18}/>
                <span>{org.name}</span>
                <small>{org.role}</small>
              </button>
            ))}
          </div>
        )}
      </div>

      {selected && (
        <div className="setting-card">
          <h3><Users size={19}/> {selected.name} — Staff</h3>
          <p>Your role: <strong>{selected.role}</strong></p>

          <button
            className="outline-btn"
            onClick={() =>
              perform(async () => loadMembers(selected.id))
            }
          >
            <RefreshCw size={16}/> Refresh members
          </button>

          {manager && (
            <>
              <button
                className="enterprise-action"
                disabled={busy}
                onClick={() => perform(async () => {
                  const result = await api<{
                    code: string;
                  }>(
                    `/api/enterprise/organizations/${selected.id}/invites`,
                    { method: "POST" }
                  );
                  setInvite(result.code);
                  setNotice(
                    "A one-use invitation was created. It expires in 24 hours."
                  );
                })}
              >
                <UserPlus size={16}/> Generate staff invitation
              </button>

              {invite && (
                <div className="enterprise-invite">
                  <code>{invite}</code>
                  <button
                    className="outline-btn"
                    onClick={() =>
                      navigator.clipboard.writeText(invite)
                    }
                  >
                    <Copy size={15}/> Copy invitation
                  </button>
                </div>
              )}
            </>
          )}

          <div className="enterprise-members">
            {members.map(member => (
              <div className="enterprise-member" key={member.id}>
                <div>
                  <strong>{member.name}</strong>
                  <small>{member.email}</small>
                </div>
                <span>{member.role}</span>

                {manager &&
                  member.role !== "owner" &&
                  (member.role !== "admin" ||
                    selected.role === "owner") && (
                    <button
                      className="small-icon"
                      aria-label={`Remove ${member.name}`}
                      disabled={busy}
                      onClick={() => {
                        if (!confirm(
                          `Remove ${member.name} from this organization?`
                        )) return;

                        perform(async () => {
                          await api(
                            `/api/enterprise/organizations/${selected.id}/members/${member.id}`,
                            { method: "DELETE" }
                          );
                          await loadMembers(selected.id);
                          setNotice("Member removed.");
                        });
                      }}
                    >
                      <Trash2 size={16}/>
                    </button>
                  )}
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="setting-card">
        <h3><ShieldCheck size={19}/> Enterprise security</h3>
        <p>
          Organization membership is checked by the backend.
          Invitation codes are one-use and expire after 24 hours.
        </p>
        <p className="notice">
          Company knowledge, company-specific conversation storage,
          verified business ownership, billing, and deployment
          isolation are not active yet. Do not upload confidential
          business information during development.
        </p>
      </div>
    </div>
  );
}
TSX

cat >> frontend/src/styles.css <<'CSS'

/* Veltrix Enterprise */
.enterprise-form {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}

.enterprise-form input {
  flex: 1;
  min-width: 180px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--bg);
  color: var(--text);
  padding: 13px;
}

.enterprise-action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  border: 0;
  border-radius: 10px;
  background: var(--accent);
  color: white;
  padding: 12px 17px;
  font-weight: 700;
  margin: 6px;
}

.enterprise-action:disabled { opacity: .5; }

.enterprise-organizations {
  display: grid;
  gap: 9px;
}

.enterprise-organizations button {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--bg);
  color: var(--text);
  text-align: left;
}

.enterprise-organizations button.chosen {
  border-color: var(--accent);
  background: var(--accent-soft);
}

.enterprise-organizations span { flex: 1; }
.enterprise-organizations small { color: var(--muted); }

.enterprise-members { margin-top: 18px; }

.enterprise-member {
  display: flex;
  gap: 12px;
  align-items: center;
  border-bottom: 1px solid var(--border);
  padding: 13px 0;
}

.enterprise-member > div { flex: 1; min-width: 0; }
.enterprise-member strong,
.enterprise-member small { display: block; overflow-wrap: anywhere; }
.enterprise-member small { color: var(--muted); margin-top: 5px; }
.enterprise-member > span { color: var(--accent); font-size: 12px; }

.enterprise-invite {
  margin: 12px 0;
  padding: 14px;
  border: 1px solid var(--border);
  border-radius: 10px;
  overflow-wrap: anywhere;
}

.enterprise-invite code { display: block; margin-bottom: 9px; }

@media (max-width: 600px) {
  .enterprise-form { flex-direction: column; }
  .enterprise-member { flex-wrap: wrap; }
}
CSS

python3 - <<'PY'
from pathlib import Path

p = Path("frontend/src/App.tsx")
source = p.read_text()

import_line = 'import EnterprisePanel from "./EnterprisePanel";'

if import_line not in source:
    anchor = 'import "./styles.css";'
    if anchor not in source:
        raise SystemExit("Frontend import location not found.")
    source = source.replace(
        anchor, anchor + "\n" + import_line, 1
    )

start_marker = '        {page === "enterprise" && ('
end_marker = '        {page === "admin" &&'

start = source.find(start_marker)
end = source.find(end_marker, start)

if start < 0 or end < 0:
    raise SystemExit(
        "Enterprise screen location not found. No changes saved."
    )

source = (
    source[:start]
    + '        {page === "enterprise" && <EnterprisePanel />}\n\n'
    + source[end:]
)

p.write_text(source)
print("Enterprise interface connected.")
PY

echo ""
echo "===== VERIFY BACKEND ====="

backend/.venv/bin/python -m py_compile \
  backend/main.py \
  backend/auth_routes.py \
  backend/account_routes.py \
  backend/conversation_routes.py \
  backend/enterprise_routes.py

echo "PASS: Python syntax"

echo ""
echo "===== VERIFY FRONTEND ====="

(
  cd frontend
  npm run build
)

echo ""
echo "======================================"
echo "VELTRIX ENTERPRISE UPGRADE COMPLETE"
echo "======================================"
