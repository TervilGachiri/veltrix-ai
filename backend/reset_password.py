import sqlite3
import secrets
import getpass
import sys
from pathlib import Path

from auth_routes import DATABASE, hash_password

print("\n===== VELTRIX AI PASSWORD RECOVERY =====")

email = input("Account email: ").strip().lower()

with sqlite3.connect(DATABASE) as db:
    db.row_factory = sqlite3.Row

    user = db.execute(
        "SELECT id, name FROM users WHERE email = ?",
        (email,)
    ).fetchone()

    if not user:
        print("Account not found.")
        sys.exit(1)

    print("Account found:", user["name"])

    password = getpass.getpass("New password: ")
    confirm = getpass.getpass("Confirm new password: ")

    if password != confirm:
        print("Passwords do not match.")
        sys.exit(1)

    if len(password) < 12 or len(password) > 128:
        print("Password must contain 12-128 characters.")
        sys.exit(1)

    salt = secrets.token_bytes(16)
    password_hash = hash_password(password, salt)

    db.execute(
        "UPDATE users SET salt = ?, password_hash = ? WHERE id = ?",
        (salt, password_hash, user["id"])
    )

    db.execute(
        "DELETE FROM sessions WHERE user_id = ?",
        (user["id"],)
    )

    db.commit()

print("\nSUCCESS: Password updated.")
print("Your conversations and account role were preserved.")
