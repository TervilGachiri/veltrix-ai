import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Cookie, HTTPException, Request
from pydantic import BaseModel, Field

from auth_routes import require_user

router = APIRouter(
    prefix="/api/conversations",
    tags=["Conversations"],
)

DB_PATH = Path(os.getenv("VELTRIX_DATABASE_PATH", str(Path(__file__).parent / "veltrix_auth.db")))


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=20000)


class Conversation(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=100)
    workspace: Literal["personal", "business"]
    messages: list[ChatMessage] = Field(max_length=100)


class ConversationSync(BaseModel):
    threads: list[Conversation] = Field(max_length=200)


def connection():
    db = sqlite3.connect(DB_PATH, timeout=10)
    db.row_factory = sqlite3.Row
    return db


def initialize():
    with connection() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS conversations (
                user_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                title TEXT NOT NULL,
                workspace TEXT NOT NULL,
                messages_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, conversation_id),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)

        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_conversations_user
            ON conversations(user_id, updated_at)
        """)


initialize()


@router.get("")
def list_conversations(
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)

    with connection() as db:
        rows = db.execute("""
            SELECT conversation_id, title, workspace, messages_json
            FROM conversations
            WHERE user_id = ?
            ORDER BY updated_at DESC
        """, (user["id"],)).fetchall()

    return {
        "threads": [
            {
                "id": row["conversation_id"],
                "title": row["title"],
                "workspace": row["workspace"],
                "messages": json.loads(row["messages_json"]),
            }
            for row in rows
        ]
    }


@router.put("/sync")
def sync_conversations(
    data: ConversationSync,
    request: Request,
    veltrix_session: str | None = Cookie(default=None),
):
    user = require_user(veltrix_session)

    # Additional origin protection for browser write requests.
    origin = request.headers.get("origin")

    allowed_origins = {
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    }

    configured_origin = os.getenv("VELTRIX_FRONTEND_ORIGIN")
    if configured_origin:
        allowed_origins.add(configured_origin.rstrip("/"))

    if origin and origin not in allowed_origins:
        raise HTTPException(
            403,
            "Untrusted request origin.",
        )

    ids = [thread.id for thread in data.threads]

    if len(ids) != len(set(ids)):
        raise HTTPException(
            400,
            "Duplicate conversation identifiers.",
        )

    now = int(time.time())

    with connection() as db:
        # Replace only the authenticated user's own snapshot.
        # Never modify another account's conversations.
        db.execute(
            "DELETE FROM conversations WHERE user_id = ?",
            (user["id"],),
        )

        for thread in data.threads:
            db.execute("""
                INSERT INTO conversations (
                    user_id,
                    conversation_id,
                    title,
                    workspace,
                    messages_json,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?)
            """, (
                user["id"],
                thread.id,
                thread.title,
                thread.workspace,
                json.dumps([
                    message.model_dump()
                    for message in thread.messages
                ]),
                now,
            ))

    return {
        "success": True,
        "saved": len(data.threads),
    }
