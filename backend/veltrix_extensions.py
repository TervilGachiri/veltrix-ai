"""
Veltrix AI additional platform services.

Features:
- Local Ollama text streaming
- Organization-scoped shared projects
- Team project messages
- Subscription plan catalog
- Platform feature readiness

Production billing, real advertisements, and secure
file-based knowledge bases require further services.
"""

import json
import os
import sqlite3
import time
import uuid

import httpx

from fastapi import (
    APIRouter,
    Cookie,
    HTTPException,
    Request
)
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from auth_routes import (
    db,
    require_user
)

from enterprise_routes import require_membership


router = APIRouter(
    prefix="/api/v2",
    tags=["Veltrix Platform"]
)


def identity(token):
    return require_user(token)


def check_origin(request: Request):
    origin = request.headers.get("origin")

    allowed = {
        "http://localhost:5173",
        "http://127.0.0.1:5173"
    }

    extra = os.getenv(
        "VELTRIX_FRONTEND_ORIGIN", ""
    ).rstrip("/")

    if extra:
        allowed.add(extra)

    if origin and origin.rstrip("/") not in allowed:
        raise HTTPException(
            403,
            "Untrusted request origin."
        )


def initialize():
    with db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS team_projects (
                id TEXT PRIMARY KEY,
                organization_id TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                created_by TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS
            idx_team_projects_organization
            ON team_projects(organization_id)
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS team_project_messages (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (project_id)
                  REFERENCES team_projects(id)
            )
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS
            idx_team_messages_project
            ON team_project_messages(project_id, created_at)
        """)


initialize()


class StreamMessage(BaseModel):
    role: str
    content: str = Field(
        min_length=1,
        max_length=12000
    )


class StreamRequest(BaseModel):
    messages: list[StreamMessage] = Field(
        min_length=1,
        max_length=25
    )

    model_mode: str = "fast"
    mode: str = "personal"


def choose_model(data):
    if data.model_mode not in (
        "fast", "smart", "auto"
    ):
        raise HTTPException(
            422, "Invalid model mode."
        )

    if data.mode not in (
        "personal", "business"
    ):
        raise HTTPException(
            422, "Invalid workspace mode."
        )

    if any(
        m.role not in ("user", "assistant")
        for m in data.messages
    ):
        raise HTTPException(
            422, "Invalid message role."
        )

    if data.messages[-1].role != "user":
        raise HTTPException(
            422, "Last message must be from user."
        )

    selected = data.model_mode

    if selected == "auto":
        latest = data.messages[-1].content.lower()

        complex_terms = (
            "python", "code", "debug", "analyse",
            "analyze", "architecture",
            "mathematics", "programming"
        )

        selected = (
            "smart"
            if any(t in latest for t in complex_terms)
            else "fast"
        )

    return (
        "qwen3:4b"
        if selected == "smart"
        else "qwen3:1.7b"
    )


@router.post("/chat/stream")
async def stream_chat(
    data: StreamRequest,
    request: Request,
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    identity(veltrix_session)
    check_origin(request)

    if os.getenv(
        "AI_PROVIDER", "ollama"
    ).lower() != "ollama":
        raise HTTPException(
            503,
            "Streaming currently requires Ollama."
        )

    model = choose_model(data)

    instructions = (
        "You are Veltrix AI. "
        "Answer accurately and professionally. "
        "Do not pretend to have access to private "
        "company information or external systems. "
        "If asked about your underlying model, "
        "explain that you use Qwen through Ollama."
    )

    messages = [
        {
            "role": "system",
            "content": instructions
        },
        *[
            {
                "role": m.role,
                "content": m.content
            }
            for m in data.messages
        ]
    ]

    async def generate():
        full = []

        try:
            timeout = httpx.Timeout(
                connect=10,
                read=240,
                write=15,
                pool=10
            )

            async with httpx.AsyncClient(
                timeout=timeout
            ) as client:

                async with client.stream(
                    "POST",
                    "http://127.0.0.1:11434/api/chat",
                    json={
                        "model": model,
                        "messages": messages,
                        "stream": True,
                        "think": False,
                        "options": {
                            "num_predict": 700
                        }
                    }
                ) as response:

                    response.raise_for_status()

                    async for line in response.aiter_lines():
                        if await request.is_disconnected():
                            break

                        if not line.strip():
                            continue

                        payload = json.loads(line)

                        piece = payload.get(
                            "message", {}
                        ).get("content", "")

                        if piece:
                            full.append(piece)

                            yield json.dumps({
                                "type": "delta",
                                "text": piece
                            }) + "\n"

                        if payload.get("done"):
                            yield json.dumps({
                                "type": "done",
                                "model": model
                            }) + "\n"
                            return

        except (
            httpx.HTTPError,
            ValueError,
            json.JSONDecodeError
        ):
            yield json.dumps({
                "type": "error",
                "detail": (
                    "The AI streaming service failed."
                )
            }) + "\n"

    return StreamingResponse(
        generate(),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-store",
            "X-Accel-Buffering": "no",
            "X-Content-Type-Options": "nosniff"
        }
    )


class CreateProject(BaseModel):
    name: str = Field(
        min_length=2, max_length=100
    )
    description: str = Field(
        default="", max_length=2000
    )


def project_access(conn, org_id, project_id, user_id):
    require_membership(conn, org_id, user_id)

    project = conn.execute("""
        SELECT id, organization_id, name,
               description, created_by, created_at
        FROM team_projects
        WHERE id = ?
          AND organization_id = ?
    """, (project_id, org_id)).fetchone()

    if not project:
        raise HTTPException(
            404, "Project not found."
        )

    return project


@router.get("/organizations/{org_id}/projects")
def projects(
    org_id: str,
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    user = identity(veltrix_session)

    with db() as conn:
        require_membership(
            conn, org_id, user["id"]
        )

        rows = conn.execute("""
            SELECT id, name, description,
                   created_by, created_at
            FROM team_projects
            WHERE organization_id = ?
            ORDER BY created_at DESC
            LIMIT 100
        """, (org_id,)).fetchall()

        return {
            "projects": [
                dict(row) for row in rows
            ]
        }


@router.post(
    "/organizations/{org_id}/projects",
    status_code=201
)
def create_project(
    org_id: str,
    data: CreateProject,
    request: Request,
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    user = identity(veltrix_session)
    check_origin(request)

    project_id = str(uuid.uuid4())
    now = int(time.time())

    with db() as conn:
        require_membership(
            conn, org_id, user["id"],
            ("owner", "admin", "member")
        )

        conn.execute("""
            INSERT INTO team_projects
            (id, organization_id, name,
             description, created_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            project_id,
            org_id,
            data.name.strip(),
            data.description,
            user["id"],
            now
        ))

    return {
        "id": project_id,
        "organization_id": org_id,
        "name": data.name.strip()
    }


class ProjectMessage(BaseModel):
    content: str = Field(
        min_length=1,
        max_length=10000
    )


@router.get(
    "/organizations/{org_id}/projects/{project_id}/messages"
)
def read_project_messages(
    org_id: str,
    project_id: str,
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    user = identity(veltrix_session)

    with db() as conn:
        project_access(
            conn, org_id, project_id, user["id"]
        )

        rows = conn.execute("""
            SELECT pm.id, pm.content, pm.created_at,
                   u.name AS author
            FROM team_project_messages pm
            JOIN users u ON u.id = pm.user_id
            WHERE pm.project_id = ?
            ORDER BY pm.created_at ASC, pm.rowid ASC
            LIMIT 500
        """, (project_id,)).fetchall()

        return {
            "messages": [
                dict(row) for row in rows
            ]
        }


@router.post(
    "/organizations/{org_id}/projects/{project_id}/messages",
    status_code=201
)
def add_project_message(
    org_id: str,
    project_id: str,
    data: ProjectMessage,
    request: Request,
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    user = identity(veltrix_session)
    check_origin(request)

    message_id = str(uuid.uuid4())

    with db() as conn:
        project_access(
            conn, org_id, project_id, user["id"]
        )

        conn.execute("""
            INSERT INTO team_project_messages
            (id, project_id, user_id,
             content, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, (
            message_id,
            project_id,
            user["id"],
            data.content.strip(),
            int(time.time())
        ))

    return {
        "success": True,
        "message_id": message_id
    }


# Catalog only. No real billing is initiated.
PLANS = [
    {
        "id": "free",
        "name": "Free",
        "billing": "not_configured"
    },
    {
        "id": "premium",
        "name": "Premium",
        "billing": "not_configured"
    },
    {
        "id": "team",
        "name": "Team",
        "billing": "not_configured"
    },
    {
        "id": "enterprise",
        "name": "Enterprise",
        "billing": "contact_sales"
    }
]


@router.get("/billing/plans")
def plans():
    return {
        "plans": PLANS,
        "payments_enabled": False
    }


@router.get("/platform/features")
def feature_status(
    veltrix_session: str | None = Cookie(
        default=None
    )
):
    identity(veltrix_session)

    return {
        "streaming_api": True,
        "document_api": True,
        "voice": "browser_implementation",
        "team_projects_api": True,
        "organization_membership": True,
        "payments_enabled": False,
        "advertising_enabled": False,
        "production_ready": False
    }
