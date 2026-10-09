import { useState, type FormEvent } from "react";
import {
  UserRound, ShieldCheck, KeyRound,
  LogOut, Save, CheckCircle2
} from "lucide-react";
import type { VeltrixUser } from "./AuthScreen";

type Props = {
  user: VeltrixUser;
  onUpdate: (user: VeltrixUser) => void;
  onLogout: () => void;
};

async function request(
  path: string,
  method: string,
  body?: object
) {
  const response = await fetch(path, {
    method,
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined
  });

  const result = await response.json();

  if (!response.ok) {
    throw new Error(
      typeof result.detail === "string"
        ? result.detail
        : "Request failed."
    );
  }

  return result;
}

export default function AccountPanel({
  user, onUpdate, onLogout
}: Props) {
  const [name, setName] = useState(user.name);
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function perform(work: () => Promise<void>) {
    setBusy(true);
    setError("");
    setMessage("");

    try {
      await work();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Operation failed."
      );
    } finally {
      setBusy(false);
    }
  }

  function saveProfile(e: FormEvent) {
    e.preventDefault();

    perform(async () => {
      const result = await request(
        "/api/account/profile",
        "PATCH",
        { name: name.trim() }
      );

      onUpdate({ ...user, name: result.name });
      setMessage("Profile updated successfully.");
    });
  }

  function changePassword(e: FormEvent) {
    e.preventDefault();

    if (newPassword !== confirmPassword) {
      setError("The new passwords do not match.");
      return;
    }

    if (newPassword.length < 12) {
      setError("Use at least 12 characters.");
      return;
    }

    perform(async () => {
      await request(
        "/api/account/change-password",
        "POST",
        {
          current_password: currentPassword,
          new_password: newPassword
        }
      );

      setCurrentPassword("");
      setNewPassword("");
      setConfirmPassword("");

      // Changing a password revokes the existing session.
      onLogout();
    });
  }

  function logoutAll() {
    if (!confirm("Sign out all sessions for this account?")) {
      return;
    }

    perform(async () => {
      await request("/api/account/logout-all", "POST");
      onLogout();
    });
  }

  return (
    <div className="page-content">
      <div className="page-heading">
        <UserRound size={28}/>
        <div>
          <h2>My Account</h2>
          <p>Manage your Veltrix AI identity and security.</p>
        </div>
      </div>

      {error && (
        <div className="error-msg" role="alert">{error}</div>
      )}

      {message && (
        <div className="notice" role="status">
          <CheckCircle2 size={16}/> {message}
        </div>
      )}

      <section className="setting-card">
        <h3><UserRound size={19}/> Profile Information</h3>

        <form className="account-form" onSubmit={saveProfile}>
          <label>
            Full name
            <input
              value={name}
              onChange={e => setName(e.target.value)}
              minLength={2}
              maxLength={100}
              required
            />
          </label>

          <label>
            Email address
            <input value={user.email} disabled/>
          </label>

          <label>
            Account role
            <input value={user.role} disabled/>
          </label>

          <button className="enterprise-action" disabled={busy}>
            <Save size={17}/> Save profile
          </button>
        </form>
      </section>

      <section className="setting-card">
        <h3><KeyRound size={19}/> Change Password</h3>

        <form className="account-form" onSubmit={changePassword}>
          <label>
            Current password
            <input
              type="password"
              autoComplete="current-password"
              value={currentPassword}
              onChange={e => setCurrentPassword(e.target.value)}
              required
            />
          </label>

          <label>
            New password
            <input
              type="password"
              autoComplete="new-password"
              value={newPassword}
              onChange={e => setNewPassword(e.target.value)}
              minLength={12}
              maxLength={128}
              required
            />
          </label>

          <label>
            Confirm new password
            <input
              type="password"
              autoComplete="new-password"
              value={confirmPassword}
              onChange={e => setConfirmPassword(e.target.value)}
              required
            />
          </label>

          <p className="notice">
            Changing your password signs out all active sessions.
            You will need to sign in again.
          </p>

          <button className="enterprise-action" disabled={busy}>
            <ShieldCheck size={17}/> Update password
          </button>
        </form>
      </section>

      <section className="setting-card">
        <h3><ShieldCheck size={19}/> Session Security</h3>
        <p>
          Revoke active sessions if you suspect unauthorized
          account access.
        </p>

        <button
          className="danger-btn"
          onClick={logoutAll}
          disabled={busy}
        >
          <LogOut size={17}/> Sign out everywhere
        </button>
      </section>

      <section className="setting-card">
        <h3>Account Protection</h3>
        <p>
          Email verification, authenticator-based MFA,
          password recovery and device-session management
          are not yet available.
        </p>
      </section>
    </div>
  );
}
