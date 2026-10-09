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
