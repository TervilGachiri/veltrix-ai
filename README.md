# Veltrix AI — Foundation Build

A local development starter for Veltrix AI with a React/TypeScript chat interface, light/dark/system theme, Personal/Business modes, browser-local conversation history, and FastAPI backend connected to the OpenAI Responses API.

## Requirements
- Node.js 20+ / npm
- Python 3.10+
- An OpenAI **API** key with billing enabled (API billing is separate from ChatGPT subscriptions). AI requests incur usage-based costs.

## Start the backend (Terminal 1)
```bash
cd veltrix-ai/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```
Edit `backend/.env` and set `OPENAI_API_KEY=...` to your own API key. **Never put this secret in frontend code or commit the .env file.**
```bash
uvicorn main:app --reload --port 8000
```
Check http://127.0.0.1:8000/api/health

## Start the frontend (Terminal 2)
```bash
cd veltrix-ai/frontend
npm install
npm run dev
```
Open http://localhost:5173

## Current scope and limitations
- Working: chat requests with a configured model, interface, settings theme, Personal/Business prompts, local conversation history, responsive layout.
- Not yet included: login, backend storage, file uploads, voice, real business connectors, subscriptions, true organization accounts/tenant separation, enterprise security, mobile native builds.
- Chat history is stored in browser localStorage only. Requests and recent conversation content are sent to the configured AI provider to generate replies. Do not submit sensitive company data to this foundation build.
- API is for **local development only**: it has no user authentication, quotas or production abuse protections. Do not publish it as a public server until those protections exist.
- Personal/Business modes change assistant behavior; they do not provide secure data separation yet.
