import hashlib
import hmac
import os
import re
import secrets
import sqlite3
from db_compat import connect, is_integrity_error
import time
from contextlib import contextmanager
from pathlib import Path

from fastapi import APIRouter, Cookie, HTTPException, Request, Response
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/auth", tags=["Authentication"])

DATABASE = Path(os.getenv("VELTRIX_DATABASE_PATH", str(Path(__file__).parent / "veltrix_auth.db")))
COOKIE_NAME = "veltrix_session"
SESSION_SECONDS = 60 * 60 * 24 * 7
PRODUCTION = os.getenv("VELTRIX_ENV") == "production"


@contextmanager
def db():
    connection = connect(DATABASE, timeout=10)
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


def initialize():
    with db() as connection:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                salt BLOB NOT NULL,
                password_hash BLOB NOT NULL,
                role TEXT NOT NULL DEFAULT 'user',
                created_at INTEGER NOT NULL
            )
        """)
        connection.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)


initialize()


class RegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    email: str = Field(min_length=5, max_length=254)
    password: str = Field(min_length=12, max_length=128)


class LoginRequest(BaseModel):
    email: str
    password: str


def normalize_email(email):
    email = email.strip().lower()
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise HTTPException(400, "Enter a valid email address.")
    return email


def hash_password(password, salt):
    return hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=2**14,
        r=8,
        p=1,
        dklen=32,
    )


def safe_user(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "email": row["email"],
        "role": row["role"],
    }


def create_session(response, user_id):
    token = secrets.token_urlsafe(48)
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    expires = int(time.time()) + SESSION_SECONDS

    with db() as connection:
        connection.execute(
            "DELETE FROM sessions WHERE expires_at < ?",
            (int(time.time()),),
        )
        connection.execute(
            "INSERT INTO sessions VALUES (?, ?, ?)",
            (token_hash, user_id, expires),
        )

    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        httponly=True,
        secure=PRODUCTION,
        samesite="none" if PRODUCTION else "lax",
        max_age=SESSION_SECONDS,
        path="/",
    )


def get_user(token):
    if not token:
        return None

    token_hash = hashlib.sha256(token.encode()).hexdigest()

    with db() as connection:
        return connection.execute("""
            SELECT users.id, users.name, users.email, users.role
            FROM sessions
            JOIN users ON users.id = sessions.user_id
            WHERE sessions.token_hash = ?
              AND sessions.expires_at > ?
        """, (token_hash, int(time.time()))).fetchone()


def require_user(token):
    user = get_user(token)
    if user is None:
        raise HTTPException(401, "Please sign in.")
    return user


@router.post("/register", status_code=201)
def register(data: RegisterRequest, response: Response):
    email = normalize_email(data.email)
    name = data.name.strip()

    if len(name) < 2:
        raise HTTPException(400, "Enter your full name.")

    salt = secrets.token_bytes(16)
    password_hash = hash_password(data.password, salt)
    user_id = secrets.token_hex(16)

    try:
        with db() as connection:
            connection.execute("""
                INSERT INTO users
                (id, name, email, salt, password_hash, role, created_at)
                VALUES (?, ?, ?, ?, ?, 'user', ?)
            """, (
                user_id, name, email, salt, password_hash,
                int(time.time())
            ))
    except Exception as exc:
        if not is_integrity_error(exc):
            raise
        raise HTTPException(
            409, "An account with this email already exists."
        )

    create_session(response, user_id)

    return {
        "user": {
            "id": user_id,
            "name": name,
            "email": email,
            "role": "user",
        }
    }


@router.post("/login")
def login(data: LoginRequest, response: Response):
    email = normalize_email(data.email)

    with db() as connection:
        row = connection.execute(
            "SELECT * FROM users WHERE email = ?",
            (email,),
        ).fetchone()

    # Perform password hashing even for unknown accounts.
    if row:
        salt = row["salt"]
        stored_hash = row["password_hash"]
    else:
        salt = b"\0" * 16
        stored_hash = b"\0" * 32

    candidate = hash_password(data.password, salt)

    if not row or not hmac.compare_digest(
        candidate, stored_hash
    ):
        raise HTTPException(401, "Invalid email or password.")

    create_session(response, row["id"])
    return {"user": safe_user(row)}


@router.get("/me")
def me(veltrix_session: str | None = Cookie(default=None)):
    user = require_user(veltrix_session)
    return {"user": safe_user(user)}


@router.post("/logout")
def logout(
    response: Response,
    veltrix_session: str | None = Cookie(default=None),
):
    if veltrix_session:
        token_hash = hashlib.sha256(
            veltrix_session.encode()
        ).hexdigest()
        with db() as connection:
            connection.execute(
                "DELETE FROM sessions WHERE token_hash = ?",
                (token_hash,),
            )

    response.delete_cookie(COOKIE_NAME, path="/")
    return {"success": True}
