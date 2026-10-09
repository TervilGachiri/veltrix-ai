import { useState, type FormEvent } from "react";
import { BrainCircuit, ArrowRight, ShieldCheck } from "lucide-react";

export type VeltrixUser = {
  id: string;
  name: string;
  email: string;
  role: string;
};

type Props = {
  onAuthenticated: (user: VeltrixUser) => void;
};

export default function AuthScreen({ onAuthenticated }: Props) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (loading) return;

    setLoading(true);
    setError("");

    try {
      const response = await fetch(`/api/auth/${mode}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(
          mode === "register"
            ? { name, email, password }
            : { email, password }
        ),
      });

      const result = await response.json();

      if (!response.ok) {
        throw new Error(result.detail || "Authentication failed.");
      }

      onAuthenticated(result.user);
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "Unable to connect to the server."
      );
    } finally {
      setLoading(false);
    }
  }

  function changeMode() {
    setMode(mode === "login" ? "register" : "login");
    setError("");
    setPassword("");
  }

  return (
    <div className="auth-layout">
      <div className="auth-brand">
        <div className="auth-logo">
          <BrainCircuit size={32} />
          <span>VELTRIX <b>AI</b></span>
        </div>

        <div className="auth-brand-content">
          <div className="auth-eyebrow">YOUR INTELLIGENT WORLD</div>
          <h1>
            Intelligence <br />
            Beyond <span>Limits.</span>
          </h1>
          <p>
            One intelligent platform for ideas, knowledge,
            productivity, and business.
          </p>
          <div className="auth-trust">
            <ShieldCheck size={19} />
            Secure account access
          </div>
        </div>

        <small>© Veltrix AI</small>
      </div>

      <div className="auth-form-side">
        <div className="auth-form-box">
          <div className="auth-mobile-brand">
            <BrainCircuit size={29} />
            <strong>VELTRIX AI</strong>
          </div>

          <div className="auth-eyebrow">WELCOME TO VELTRIX</div>

          <h2>
            {mode === "login"
              ? "Welcome back"
              : "Create your account"}
          </h2>

          <p className="auth-description">
            {mode === "login"
              ? "Sign in to continue your AI experience."
              : "Join Veltrix AI and start exploring."}
          </p>

          <form onSubmit={submit} className="auth-form">
            {mode === "register" && (
              <label>
                Full name
                <input
                  required
                  minLength={2}
                  maxLength={100}
                  autoComplete="name"
                  placeholder="Enter your name"
                  value={name}
                  onChange={e => setName(e.target.value)}
                />
              </label>
            )}

            <label>
              Email address
              <input
                required
                type="email"
                autoComplete="email"
                placeholder="you@example.com"
                value={email}
                onChange={e => setEmail(e.target.value)}
              />
            </label>

            <label>
              Password
              <input
                required
                type="password"
                minLength={mode === "register" ? 12 : undefined}
                maxLength={128}
                autoComplete={
                  mode === "login"
                    ? "current-password"
                    : "new-password"
                }
                placeholder="Enter your password"
                value={password}
                onChange={e => setPassword(e.target.value)}
              />
            </label>

            {mode === "register" && (
              <p className="auth-hint">
                Use at least 12 characters. Never reuse an important password.
              </p>
            )}

            {error && (
              <div className="auth-error" role="alert">
                {error}
              </div>
            )}

            <button
              className="auth-submit"
              type="submit"
              disabled={loading}
            >
              {loading
                ? "Please wait..."
                : mode === "login"
                  ? "Sign in"
                  : "Create account"}
              <ArrowRight size={18} />
            </button>
          </form>

          <div className="auth-switch">
            {mode === "login"
              ? "New to Veltrix AI?"
              : "Already have an account?"}
            <button onClick={changeMode}>
              {mode === "login" ? "Create account" : "Sign in"}
            </button>
          </div>

          <div className="auth-footer">
            Account credentials are handled by our local
            development authentication server.
          </div>
        </div>
      </div>
    </div>
  );
}
