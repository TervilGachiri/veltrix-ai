from pathlib import Path
from datetime import datetime
import sqlite3
import re
import sys

ROOT = Path.cwd()
BACKEND = ROOT / "backend"
FRONTEND = ROOT / "frontend/src/App.tsx"
DB = BACKEND / "veltrix_auth.db"
ROUTES = BACKEND / "conversation_routes.py"
BACKUPS = ROOT / "backups/chat-recovery"

print("\n========== VELTRIX CHAT RECOVERY ==========\n")

for path in (DB, ROUTES, FRONTEND):
    if not path.exists():
        sys.exit(f"ERROR: Required file missing: {path}")

BACKUPS.mkdir(parents=True, exist_ok=True)

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
backup = BACKUPS / f"veltrix_auth_{stamp}.db"

print("1. CREATING DATABASE BACKUP")

# SQLite's backup API safely copies a live database.
with sqlite3.connect(
    f"file:{DB.resolve()}?mode=ro", uri=True
) as source:
    with sqlite3.connect(backup) as destination:
        source.backup(destination)

with sqlite3.connect(
    f"file:{backup.resolve()}?mode=ro", uri=True
) as connection:
    result = connection.execute(
        "PRAGMA integrity_check"
    ).fetchone()[0]

if result != "ok":
    sys.exit("ERROR: Database backup failed integrity check.")

print("Backup:", backup)
print("Integrity:", result)
print("Original database unchanged.")

print("\n2. CONVERSATION STORAGE")

with sqlite3.connect(
    f"file:{DB.resolve()}?mode=ro", uri=True
) as connection:
    tables = connection.execute(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' ORDER BY name"
    ).fetchall()

    for (name,) in tables:
        if any(x in name.lower() for x in
               ("conversation", "thread", "message")):

            quoted = '"' + name.replace('"', '""') + '"'

            columns = connection.execute(
                f"PRAGMA table_info({quoted})"
            ).fetchall()

            count = connection.execute(
                f"SELECT COUNT(*) FROM {quoted}"
            ).fetchone()[0]

            print("Table:", name)
            print("Records:", count)
            print("Columns:", [c[1] for c in columns])

print("\n3. BACKEND CONVERSATION ROUTES")

lines = ROUTES.read_text().splitlines()
matches = set()

for index, line in enumerate(lines):
    if re.search(
        r'@router\.|def .*sync|def .*conversation|'
        r'DELETE FROM|INSERT INTO|UPDATE |'
        r'CREATE TABLE|executemany',
        line,
        re.I
    ):
        matches.update(
            range(max(0, index - 3),
                  min(len(lines), index + 14))
        )

for index in sorted(matches):
    print(f"{index+1:4}: {lines[index]}")

print("\n4. FRONTEND CHAT SYNCHRONIZATION")

lines = FRONTEND.read_text().splitlines()
matches = set()

for index, line in enumerate(lines):
    if re.search(
        r'/api/conversations|setThreads|'
        r'localStorage|sessionStorage|'
        r'useEffect|sync|hydrated|loaded',
        line,
        re.I
    ):
        matches.update(
            range(max(0, index - 4),
                  min(len(lines), index + 9))
        )

for index in sorted(matches):
    if index >= 420:
        continue
    print(f"{index+1:4}: {lines[index]}")

print("\n========== CHECK COMPLETE ==========")
print("Your original database has not been modified.")
print("Keep the backup until chat persistence is verified.")
