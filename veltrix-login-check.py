import sqlite3
import urllib.request
import urllib.error
from pathlib import Path

print("\n===== VELTRIX AI LOGIN DIAGNOSTICS =====")

for name, url in [
    ("Backend", "http://127.0.0.1:8001/openapi.json"),
    ("Frontend", "http://localhost:5173/"),
    ("Authentication", "http://127.0.0.1:8001/api/auth/me"),
]:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            print(name, "HTTP", response.status)
    except urllib.error.HTTPError as error:
        print(name, "HTTP", error.code)
    except Exception as error:
        print(name, "UNAVAILABLE:", type(error).__name__)

database = Path("backend/veltrix_auth.db")

if database.exists():
    with sqlite3.connect(database) as conn:
        accounts = conn.execute(
            "SELECT role FROM users"
        ).fetchall()

        print("\nAccounts found:", len(accounts))
        print("Account roles:", [row[0] for row in accounts])

print("\n===== FRONTEND LOGIN CODE =====")

source = Path("frontend/src/AuthScreen.tsx").read_text()

for number, line in enumerate(source.splitlines(), 1):
    if any(term in line for term in [
        "fetch(", "response.json()", "onAuthenticated",
        "setError(", "credentials:"
    ]):
        print(f"Line {number}: {line.strip()}")

print("\nDiagnostic complete.")
