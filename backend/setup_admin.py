import sqlite3
import getpass
import hmac
import time

from auth_routes import hash_password, DATABASE

def main():
    print("\n===== VELTRIX AI ADMIN SETUP =====")

    email = input("Enter your Veltrix AI email: ").strip().lower()
    password = getpass.getpass("Enter your password: ")

    with sqlite3.connect(DATABASE) as conn:
        conn.row_factory = sqlite3.Row

        user = conn.execute(
            "SELECT * FROM users WHERE email = ?",
            (email,)
        ).fetchone()

        if not user:
            print("Account not found.")
            return

        candidate = hash_password(password, user["salt"])

        if not hmac.compare_digest(
            candidate,
            user["password_hash"]
        ):
            print("Incorrect password.")
            return

        print("\nAccount verified:", user["name"])
        print("Current role:", user["role"])

        confirmation = input(
            "Type PROMOTE to become Platform Administrator: "
        ).strip()

        if confirmation != "PROMOTE":
            print("Cancelled.")
            return

        conn.execute("""
            CREATE TABLE IF NOT EXISTS platform_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                actor_id TEXT NOT NULL,
                action TEXT NOT NULL,
                detail TEXT,
                created_at INTEGER NOT NULL
            )
        """)

        conn.execute(
            "UPDATE users SET role = 'admin' WHERE id = ?",
            (user["id"],)
        )

        conn.execute(
            "DELETE FROM sessions WHERE user_id = ?",
            (user["id"],)
        )

        conn.execute("""
            INSERT INTO platform_audit
            (actor_id, action, detail, created_at)
            VALUES (?, ?, ?, ?)
        """, (
            user["id"],
            "local_admin_bootstrap",
            "Platform administrator activated",
            int(time.time())
        ))

        conn.commit()

    print("\nSUCCESS: Platform Administrator activated!")
    print("Please sign in again.")

if __name__ == "__main__":
    main()
