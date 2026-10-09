from pathlib import Path
import ast
import subprocess
import urllib.request
import urllib.error
import json

print("\n===== VELTRIX LOGIN ROOT-CAUSE CHECK =====")

files = [
    "backend/main.py",
    "backend/auth_routes.py",
    "backend/platform_security.py",
    "backend/media_routes.py"
]

for filename in files:
    path = Path(filename)
    if not path.exists():
        print(f"MISSING: {filename}")
        continue

    try:
        ast.parse(path.read_text(), filename=filename)
        print(f"SYNTAX OK: {filename}")
    except SyntaxError as error:
        print(f"SYNTAX ERROR: {filename}: {error}")

print("\n===== CURRENT PORT OWNER =====")
subprocess.run([
    "lsof", "-nP",
    "-iTCP:8001", "-sTCP:LISTEN"
], check=False)

print("\n===== API AUTH ROUTE =====")
try:
    with urllib.request.urlopen(
        "http://127.0.0.1:8001/openapi.json",
        timeout=8
    ) as response:
        spec = json.load(response)

    for path, methods in spec.get("paths", {}).items():
        if "auth/login" in path:
            print(path, sorted(methods.keys()))
except Exception as error:
    print(type(error).__name__, str(error))

print("\n===== LOGIN HANDLER AND SECURITY CODE =====")

for filename, patterns in [
    ("backend/auth_routes.py", ["def login", "def hash", "def verify", "scrypt", "set_cookie"]),
    ("backend/platform_security.py", ["middleware", "origin", "rate_limit", "login"])
]:
    path = Path(filename)
    if not path.exists():
        continue

    lines = path.read_text().splitlines()

    print(f"\nFILE: {filename}")
    positions = set()

    for i, line in enumerate(lines):
        if any(pattern in line.lower() for pattern in patterns):
            positions.update(range(
                max(0, i - 2),
                min(len(lines), i + 5)
            ))

    for i in sorted(positions):
        line = lines[i]

        # Avoid displaying possible secrets or token values.
        if any(x in line.lower() for x in [
            "secret_key =", "password =", "token =",
            "api_key =", "authorization:"
        ]):
            print(f"{i + 1}: [redacted]")
        else:
            print(f"{i + 1}: {line}")

print("\n===== CHECK COMPLETE =====")
