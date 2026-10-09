from workspace_security import router as workspace_security_router, workspace_audit_middleware
from veltrix_extensions import router as extensions_router
from media_routes import router as media_router
from platform_security import security_middleware
from platform_admin import router as platform_router
from enterprise_routes import router as enterprise_router
from account_routes import router as account_router
from conversation_routes import router as conversation_router
from auth_routes import router as auth_router
import re
import os
import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from openai import OpenAI, OpenAIError

load_dotenv()
app = FastAPI(title="Veltrix AI API", version="0.1.0")
origins = os.getenv("FRONTEND_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173").split(",")
app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=False, allow_methods=["GET", "POST"], allow_headers=["Content-Type"])

class Message(BaseModel):
    role: str
    content: str = Field(min_length=1, max_length=12000)

class ChatRequest(BaseModel):
    messages: list[Message] = Field(min_length=1, max_length=25)
    mode: str = "personal"

    model_mode: str = 'fast'
@app.get("/api/health")
def health():
    return {"status": "ok", "service": "veltrix-ai"}

@app.post("/api/chat")
def chat(data: ChatRequest):
    if data.mode not in ("personal", "business"):
        raise HTTPException(422, "Unsupported mode")
    if any(m.role not in ("user", "assistant") for m in data.messages) or data.messages[-1].role != "user":
        raise HTTPException(422, "Invalid conversation")


    # Veltrix AI model selection
    model_mode = getattr(data, "model_mode", "fast")

    if model_mode not in ("fast", "smart", "auto"):
        raise HTTPException(
            status_code=400,
            detail="Invalid AI model selection."
        )

    if model_mode == "auto":
        latest_message = data.messages[-1].content.lower() if data.messages else ""
        complex_terms = (
            "code", "python", "debug", "programming",
            "analyze", "analyse", "compare", "architecture",
            "complex", "explain in detail", "mathematics",
            "business strategy", "javascript"
        )
        model_mode = (
            "smart"
            if any(term in latest_message for term in complex_terms)
            else "fast"
        )

    chosen_model = (
        "qwen3:4b"
        if model_mode == "smart"
        else "qwen3:1.7b"
    )

    provider = os.getenv("AI_PROVIDER", "ollama").lower()

    if provider == "ollama":
        instruction = (
            "You are Veltrix AI, the assistant inside the Veltrix AI application. "
            "Introduce yourself as Veltrix AI. "
            "Your underlying language model is Qwen, running through Ollama. "
            "If asked about your technology, disclose that accurately. "
            "Be friendly, accurate, professional, and concise. "
            "Be transparent about uncertainty and limitations. "
            "Never claim capabilities or actions you do not have. "
        )

        if data.mode == "business":
            instruction += (
                "You are assisting in a business workspace. "
                "Help with business planning, operations, productivity, "
                "reports, management and professional tasks. "
                "Do not claim access to private company records."
            )
        else:
            instruction += (
                "Help with learning, technology, creativity, "
                "research, programming and everyday questions."
            )

        messages = [
            {"role": "system", "content": instruction},
            *[
                {"role": m.role, "content": m.content}
                for m in data.messages
            ],
        ]

        try:
            with httpx.Client(timeout=240.0) as client:
                response = client.post(
                    "http://127.0.0.1:11434/api/chat",
                    json={
                        "model": chosen_model,
                        "messages": messages,
                        "stream": False,
                        "options": {"num_predict": 700},
                        "think": False,
                    },
                )
                response.raise_for_status()
                result = response.json()

            reply = result.get("message", {}).get("content", "")

            # Remove reasoning blocks if the model includes them.
            reply = re.sub(
                r"<think>.*?</think>",
                "",
                reply,
                flags=re.DOTALL
            ).strip()

            # Handle a response with a dangling closing think tag.
            if "</think>" in reply:
                reply = reply.split("</think>")[-1].strip()

            if not reply:
                raise HTTPException(
                    502, "The local AI returned an empty response."
                )

            return {"reply": reply}

        except httpx.ConnectError:
            raise HTTPException(
                503, "Ollama is not running. Start Ollama first."
            )
        except httpx.TimeoutException:
            raise HTTPException(
                504, "The local AI took too long to respond."
            )
        except httpx.HTTPStatusError:
            raise HTTPException(
                502, "Ollama could not process the AI request."
            )

    if provider == "groq":
        # Groq Chat Completions is compatible with the existing OpenAI SDK.
        # Never send this key to the frontend or store it in Git.
        key = os.getenv("GROQ_API_KEY")
        if not key:
            raise HTTPException(503, "Groq AI is not configured on the server.")
        instruction = (
            "You are Veltrix AI, a helpful and accurate AI assistant. "
            "Do not claim access to tools, private records, or actions you cannot perform. "
        )
        if data.mode == "business":
            instruction += "Provide clear, practical business assistance. "
        else:
            instruction += "Help with learning, technology and everyday questions. "
        try:
            client = OpenAI(
                api_key=key,
                base_url="https://api.groq.com/openai/v1",
                timeout=45.0,
                max_retries=1,
            )
            result = client.chat.completions.create(
                model=os.getenv("GROQ_MODEL", "openai/gpt-oss-20b"),
                messages=[
                    {"role": "system", "content": instruction},
                    *[{"role": m.role, "content": m.content} for m in data.messages],
                ],
                max_tokens=900,
            )
            reply = (result.choices[0].message.content or "").strip()
            if not reply:
                raise HTTPException(502, "AI returned an empty response.")
            return {"reply": reply}
        except OpenAIError:
            raise HTTPException(
                502,
                "Hosted AI request failed. Check provider access, model and rate limits.",
            )

    if provider != "openai":
        raise HTTPException(503, "Unsupported AI provider.")

    key = os.getenv("OPENAI_API_KEY")
    if not key:
        raise HTTPException(503, "AI provider is not configured. Add OPENAI_API_KEY to backend/.env.")
    instruction = (
        "You are Veltrix AI, a helpful, accurate, friendly AI assistant. Be transparent about uncertainty. "
        "Do not claim actions, tools, or integrations you do not have. "
    )
    if data.mode == "business":
        instruction += "Focus on practical, clear business assistance; do not pretend to have access to company data."
    else:
        instruction += "Support general questions, learning, creativity and everyday tasks."
    try:
        client = OpenAI(api_key=key, timeout=40.0)
        resp = client.responses.create(
            model=os.getenv("OPENAI_MODEL", "gpt-4.1-mini"),
            instructions=instruction,
            input=[{"role": m.role, "content": m.content} for m in data.messages],
            max_output_tokens=1200,
        )
        return {"reply": resp.output_text or "No text response was returned."}
    except OpenAIError:
        raise HTTPException(502, "AI provider request failed. Check your API key, model access and billing.")


app.include_router(auth_router)


# Veltrix AI local authentication gate.
# Production security hardening will be completed before deployment.
from auth_routes import get_user
from fastapi.responses import JSONResponse


@app.middleware("http")
async def veltrix_access_control(request, call_next):
    path = request.url.path

    if path.startswith("/api/"):
        fetch_site = request.headers.get("sec-fetch-site", "")
        if fetch_site == "cross-site":
            return JSONResponse(
                status_code=403,
                content={"detail": "Cross-site request blocked."},
            )

    if path == "/api/chat":
        token = request.cookies.get("veltrix_session")
        if get_user(token) is None:
            return JSONResponse(
                status_code=401,
                content={"detail": "Please sign in to use Veltrix AI."},
            )

    return await call_next(request)

app.include_router(conversation_router)

app.include_router(account_router)


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

app.include_router(enterprise_router)

app.include_router(platform_router)

app.middleware('http')(security_middleware)

app.include_router(media_router)

app.include_router(extensions_router)

app.include_router(workspace_security_router)
app.middleware('http')(workspace_audit_middleware)
