import MediaTools from "./MediaTools";
import { useEffect, useRef, useState } from "react";
import {
  BrainCircuit, Plus, MessageSquare, Settings,
  UserRound, Building2, ShieldCheck, Menu, X,
  Send, Sun, Moon, Monitor, Search, Trash2,
  Download, LayoutDashboard, Sparkles,
  ArrowUpRight, Copy, Pencil, ChevronDown,
  Globe, LockKeyhole, Check, LogOut
} from "lucide-react";
import "./styles.css";
import AccountPanel from "./AccountPanel";
import PlatformAdmin from "./PlatformAdmin";
import EnterprisePanel from "./EnterprisePanel";
import AuthScreen, { type VeltrixUser } from "./AuthScreen";

type Theme = "light" | "dark" | "system";
type Workspace = "personal" | "business";
type Page = "chat" | "settings" | "account" | "enterprise" | "admin";
type Message = { role: "user" | "assistant"; content: string };
type Thread = {
  id: string;
  title: string;
  workspace: Workspace;
  messages: Message[];
};

function stored<T>(key: string, fallback: T): T {
  try {
    const value = localStorage.getItem(key);
    return value ? JSON.parse(value) as T : fallback;
  } catch {
    return fallback;
  }
}

export default function App() {
  const [authenticatedUser, setAuthenticatedUser] =
    useState<VeltrixUser | null>(null);
  const [authChecking, setAuthChecking] = useState(true);

  useEffect(() => {
    fetch("/api/auth/me", { credentials: "same-origin" })
      .then(async response => {
        if (!response.ok) return null;
        const data = await response.json();
        return data.user as VeltrixUser;
      })
      .then(setAuthenticatedUser)
      .catch(() => setAuthenticatedUser(null))
      .finally(() => setAuthChecking(false));
  }, []);

  async function signOut() {
    try {
      const response = await fetch("/api/auth/logout", {
        method: "POST",
        credentials: "same-origin"
      });
      if (!response.ok) throw new Error("Logout failed");
      localStorage.removeItem("veltrix-threads");
      setThreads([]);
      setActiveId(null);
      setAuthenticatedUser(null);
      setPage("chat");
    } catch {
      alert("Unable to sign out. Please try again.");
    }
  }

  const [theme, setTheme] = useState<Theme>(
    () => stored("veltrix-theme", "system")
  );
  const [modelMode, setModelMode] = useState<
    "fast" | "smart" | "auto"
  >(() => {
    const saved = stored("veltrix-model-mode", "fast");
    return ["fast", "smart", "auto"].includes(saved)
      ? saved as "fast" | "smart" | "auto"
      : "fast";
  });

  useEffect(() => {
    localStorage.setItem(
      "veltrix-model-mode",
      JSON.stringify(modelMode)
    );
  }, [modelMode]);

  const [workspace, setWorkspace] = useState<Workspace>(
    () => stored("veltrix-workspace", "personal")
  );
  const [page, setPage] = useState<Page>("chat");
  const [threads, setThreads] = useState<Thread[]>(
    () => []
  );
  const [activeId, setActiveId] = useState<string | null>(null);
  const [input, setInput] = useState("");
  const [search, setSearch] = useState("");
  const [language, setLanguage] = useState(
    () => stored("veltrix-language", "English")
  );

  const [mobileMenu, setMobileMenu] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState("");

  const [historyReady, setHistoryReady] = useState(false);
  const [historyError, setHistoryError] = useState("");
  const [historyRevision, setHistoryRevision] = useState(0);

  const historySaveQueue = useRef<Promise<unknown>>(
    Promise.resolve()
  );

  // Load conversations only after the session is verified.
  useEffect(() => {
    let cancelled = false;
    setHistoryReady(false);
    setHistoryError("");

    if (!authenticatedUser) {
      setThreads([]);
      return () => { cancelled = true; };
    }

    fetch("/api/conversations", {
      credentials: "same-origin"
    })
      .then(async response => {
        if (!response.ok) {
          throw new Error(
            "Could not load your saved conversations."
          );
        }
        const result = await response.json();
        return result.threads as Thread[];
      })
      .then(savedThreads => {
        if (cancelled) return;
        setThreads(savedThreads);
        setActiveId(null);
        localStorage.removeItem("veltrix-threads");
        setHistoryReady(true);
      })
      .catch(err => {
        if (!cancelled) {
          setHistoryError(
            err instanceof Error
              ? err.message
              : "Unable to load conversations."
          );
        }
      });

    return () => { cancelled = true; };
  }, [authenticatedUser?.id, historyRevision]);

  // Save changes after editing, and serialize writes to avoid
  // older requests overwriting newer conversations.
  useEffect(() => {
    if (!authenticatedUser || !historyReady) return;

    const ownerId = authenticatedUser.id;

    const timer = window.setTimeout(() => {
      const snapshot = JSON.stringify({ threads });

      historySaveQueue.current = historySaveQueue.current
        .catch(() => undefined)
        .then(async () => {
          const response = await fetch(
            "/api/conversations/sync",
            {
              method: "PUT",
              credentials: "same-origin",
              headers: {
                "Content-Type": "application/json"
              },
              body: snapshot
            }
          );

          if (!response.ok) {
            throw new Error(
              "Saving conversations failed. Please keep this page open."
            );
          }

          if (ownerId === authenticatedUser.id) {
            setHistoryError("");
          }
        })
        .catch(err => {
          setHistoryError(
            err instanceof Error
              ? err.message
              : "History synchronization failed."
          );
        });
    }, 600);

    return () => window.clearTimeout(timer);
  }, [threads, authenticatedUser?.id, historyReady]);




  const active = threads.find(t => t.id === activeId);
  const messages = active?.messages || [];

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    function updateTheme() {
      document.documentElement.dataset.theme =
        theme === "system"
          ? (media.matches ? "dark" : "light")
          : theme;
    }
    updateTheme();
    media.addEventListener("change", updateTheme);
    localStorage.setItem("veltrix-theme", JSON.stringify(theme));
    return () => media.removeEventListener("change", updateTheme);
  }, [theme]);

  useEffect(() => {
    localStorage.setItem("veltrix-workspace", JSON.stringify(workspace));
    localStorage.setItem("veltrix-language", JSON.stringify(language));
    


  }, [workspace, language]);

  function navigate(target: Page) {
    setPage(target);
    setMobileMenu(false);
  }

  function newChat() {
    setActiveId(null);
    setInput("");
    setError("");
    navigate("chat");
  }

  function switchWorkspace(next: Workspace) {
    setWorkspace(next);
    newChat();
  }

  function deleteThread(id: string) {
    if (!confirm("Delete this saved conversation?")) return;
    setThreads(previous => previous.filter(t => t.id !== id));
    if (activeId === id) setActiveId(null);
  }

  function renameThread(id: string) {
    const item = threads.find(t => t.id === id);
    if (!item) return;
    const title = prompt("Conversation name", item.title)?.trim();
    if (!title) return;
    setThreads(previous => previous.map(t =>
      t.id === id ? { ...t, title: title.slice(0, 80) } : t
    ));
  }

  function exportChats() {
    const blob = new Blob(
      [JSON.stringify(threads, null, 2)],
      { type: "application/json" }
    );
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "veltrix-conversations.json";
    link.click();
    URL.revokeObjectURL(url);
  }

  async function sendMessage(value?: string) {
    const text = (value ?? input).trim();
    if (!text || sending) return;

    const id = active?.id || crypto.randomUUID();
    const next: Message[] = [
      ...messages,
      { role: "user", content: text }
    ];

    if (active) {
      setThreads(previous => previous.map(t =>
        t.id === id ? { ...t, messages: next } : t
      ));
    } else {
      setThreads(previous => [{
        id,
        title: text.slice(0, 50),
        workspace,
        messages: next
      }, ...previous]);
    }

    setActiveId(id);
    setInput("");
    setError("");
    setSending(true);
    setPage("chat");

    try {
      const response = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          messages: next.slice(-25),
          model_mode: modelMode,
          mode: active?.workspace || workspace
        })
      });

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.detail || "AI request failed.");
      }

      setThreads(previous => previous.map(t =>
        t.id === id
          ? {
              ...t,
              messages: [
                ...next,
                { role: "assistant", content: data.reply }
              ]
            }
          : t
      ));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Connection failed.");
    } finally {
      setSending(false);
    }
  }

  const suggestions = workspace === "personal"
    ? [
        "Help me learn Python programming",
        "Explain artificial intelligence",
        "Help me write a professional email",
        "Give me creative project ideas"
      ]
    : [
        "Help me analyze business operations",
        "Create an inventory report structure",
        "Draft a professional proposal",
        "Explain business performance metrics"
      ];

  const filtered = threads.filter(t =>
    t.workspace === workspace &&
    (t.title + " " + t.messages.map(m => m.content).join(" "))
      .toLowerCase().includes(search.toLowerCase())
  );

  if (authChecking) {
    return (
      <div className="auth-form-side">
        <div>Loading Veltrix AI...</div>
      </div>
    );
  }

  if (!authenticatedUser) {
    return (
      <AuthScreen
        onAuthenticated={user => {
          localStorage.removeItem("veltrix-threads");
          setThreads([]);
          setActiveId(null);
          setAuthenticatedUser(user);
        }}
      />
    );
  }

  if (!historyReady) {
    return (
      <div className="auth-form-side">
        <div className="auth-form-box">
          <h2>Veltrix AI</h2>
          {historyError ? (
            <>
              <p role="alert">{historyError}</p>
              <button
                className="auth-submit"
                onClick={() => setHistoryRevision(v => v + 1)}
              >
                Retry loading
              </button>
              <button
                className="outline-btn"
                onClick={signOut}
              >
                Sign out
              </button>
            </>
          ) : (
            <p>Loading your conversations...</p>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="app">
      {mobileMenu && (
        <div className="overlay" onClick={() => setMobileMenu(false)} />
      )}

      <aside className={`sidebar ${mobileMenu ? "open" : ""}`}>
        <div className="logo">
          <div className="logo-icon"><BrainCircuit size={24}/></div>
          <span>VELTRIX <b>AI</b></span>
          <button className="mobile-close" onClick={() => setMobileMenu(false)}>
            <X size={20}/>
          </button>
        </div>

        <button className="primary-btn" onClick={newChat}>
          <Plus size={18}/> New conversation
        </button>

        <div className="nav-label">WORKSPACES</div>

        <button
          className={`nav-btn ${workspace === "personal" && page === "chat" ? "active" : ""}`}
          onClick={() => switchWorkspace("personal")}
        >
          <UserRound size={18}/> Personal AI
        </button>

        <button
          className={`nav-btn ${workspace === "business" && page === "chat" ? "active" : ""}`}
          onClick={() => switchWorkspace("business")}
        >
          <Building2 size={18}/> Business AI
        </button>

        <button className="nav-btn" onClick={() => navigate("enterprise")}>
          <Globe size={18}/> Enterprise
        </button>

        <div className="nav-label">CONVERSATIONS</div>

        <div className="search-box">
          <Search size={16}/>
          <input
            placeholder="Search chats..."
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>

        <div className="chat-list">
          {filtered.map(t => (
            <div className={`chat-entry ${activeId === t.id ? "selected" : ""}`} key={t.id}>
              <button onClick={() => {
                setActiveId(t.id);
                navigate("chat");
              }}>
                <MessageSquare size={15}/>
                <span>{t.title}</span>
              </button>
              <button className="small-icon" onClick={() => renameThread(t.id)} title="Rename">
                <Pencil size={13}/>
              </button>
              <button className="small-icon" onClick={() => deleteThread(t.id)} title="Delete">
                <Trash2 size={13}/>
              </button>
            </div>
          ))}
          {filtered.length === 0 && (
            <p className="empty-chat">No conversations found.</p>
          )}
        </div>

        <div className="sidebar-bottom">
          {authenticatedUser.role === "admin" && (
            <button className="nav-btn" onClick={() => navigate("admin")}>
              <LayoutDashboard size={18}/> Administration
            </button>
          )}
          <button className="nav-btn" onClick={() => navigate("settings")}>
            <Settings size={18}/> Settings
          </button>
          <button className="nav-btn" onClick={() => navigate("account")}>
            <UserRound size={18}/> {authenticatedUser.name}
          </button>
          <button className="nav-btn" onClick={signOut}>
            <LogOut size={18}/> Sign out
          </button>
          <div className="privacy-label">
            <ShieldCheck size={15}/> Local development interface
          </div>
        </div>
      </aside>

      <main className="main">
        <header className="header">
          <div className="header-left">
            <button className="menu-button" onClick={() => setMobileMenu(true)}>
              <Menu size={22}/>
            </button>
            <div className="workspace-chip">
              {workspace === "personal" ? <UserRound size={16}/> : <Building2 size={16}/>}
              {workspace === "personal" ? "Personal" : "Business"}
              <ChevronDown size={14}/>
            </div>
          </div>
          <div className="header-right">
            <span className="version">VELTRIX AI</span>
            <button className="header-icon" onClick={() => navigate("settings")} aria-label="Settings">
              <Settings size={20}/>
            </button>
            <button className="user-avatar" onClick={() => navigate("account")} aria-label="Account">
              <UserRound size={18}/>
            </button>
          </div>
        </header>

        {page === "chat" && (
          <div className="chat-page">
            <div className="chat-body">
              {messages.length === 0 ? (
                <div className="welcome">
                  <div className="hero-icon"><BrainCircuit size={35}/></div>
                  <div className="eyebrow">WELCOME TO VELTRIX AI</div>
                  <h1>Intelligence Beyond <span>Limits.</span></h1>
                  <p>
                    {workspace === "personal"
                      ? "Your intelligent companion for learning, creativity, research, and everyday questions."
                      : "Your intelligent workspace for business ideas, productivity, and better decisions."}
                  </p>
                  <div className="suggestions">
                    {suggestions.map(s => (
                      <button key={s} onClick={() => sendMessage(s)}>
                        {s}<ArrowUpRight size={18}/>
                      </button>
                    ))}
                  </div>
                </div>
              ) : (
                <div className="messages">
                  {messages.map((m, i) => (
                    <div className={`message ${m.role}`} key={i}>
                      <div className="message-avatar">
                        {m.role === "assistant" ? <Sparkles size={17}/> : <UserRound size={17}/>}
                      </div>
                      <div className="message-text">
                        <strong>{m.role === "assistant" ? "Veltrix AI" : "You"}</strong>
                        <p>{m.content}</p>
                        <button className="copy-btn" onClick={() => navigator.clipboard.writeText(m.content)}>
                          <Copy size={13}/> Copy
                        </button>
                      </div>
                    </div>
                  ))}
                  {sending && <p className="status-text">Veltrix AI is thinking...</p>}
                </div>
              )}
            </div>

            <div className="composer-area">
              <MediaTools
                latestAnswer={
                  [...messages]
                    .reverse()
                    .find(m => m.role === "assistant")
                    ?.content || ""
                }
                onInsert={(text) => {
                  setInput(previous =>
                    previous.trim()
                      ? previous + "\\n\\n" + text
                      : text
                  );
                }}
              />

              {error && <div className="error-msg">{error}</div>}
              <form className="composer" onSubmit={e => {
                e.preventDefault();
                sendMessage();
              }}>
                <textarea
                  value={input}
                  onChange={e => setInput(e.target.value)}
                  placeholder="Ask Veltrix AI anything..."
                  rows={2}
                  onKeyDown={e => {
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      sendMessage();
                    }
                  }}
                />
                <div className="composer-bottom">
                  <span>Enter to send · Shift + Enter for new line</span>
                  <button disabled={!input.trim() || sending} aria-label="Send">
                    <Send size={18}/>
                  </button>
                </div>
              </form>
              <small>Veltrix AI can make mistakes. Verify important information.</small>
            </div>
          </div>
        )}

        {page === "settings" && (
          <div className="page-content">
            <div className="page-heading">
              <Settings size={27}/>
              <div><h2>Settings</h2><p>Customize your Veltrix AI experience.</p></div>
            </div>

            <section className="setting-card">
              <h3><BrainCircuit size={19}/> AI Model Selection</h3>
              <p>Choose how Veltrix AI processes your questions.</p>

              <div className="theme-grid">
                {([
                  ["fast", "Fast", "Qwen3 1.7B"],
                  ["smart", "Smart", "Qwen3 4B"],
                  ["auto", "Auto", "Automatic"]
                ] as const).map(([value, label, description]) => (
                  <button
                    key={value}
                    className={modelMode === value ? "chosen" : ""}
                    onClick={() => setModelMode(value)}
                    type="button"
                    style={{
                      flexDirection: "column",
                      gap: "7px"
                    }}
                  >
                    <strong>{label}</strong>
                    <span style={{fontSize: 11}}>
                      {description}
                    </span>
                    {modelMode === value && <Check size={16}/>}
                  </button>
                ))}
              </div>

              <p className="notice">
                Fast mode prioritizes speed. Smart mode uses a larger
                model. Auto mode selects between them using simple
                task rules. Your choice applies to new messages.
              </p>
            </section>

            <section className="setting-card">
              <h3><Sun size={19}/> Appearance</h3>
              <p>Choose your preferred application theme.</p>
              <div className="theme-grid">
                {([
                  ["light", Sun, "Light"],
                  ["dark", Moon, "Dark"],
                  ["system", Monitor, "System"]
                ] as const).map(([value, Icon, label]) => (
                  <button
                    key={value}
                    className={theme === value ? "chosen" : ""}
                    onClick={() => setTheme(value)}
                  >
                    <Icon size={21}/>
                    {label}
                    {theme === value && <Check size={15}/>}
                  </button>
                ))}
              </div>
            </section>

            <section className="setting-card">
              <h3><Globe size={19}/> Language</h3>
              <p>Preferred language. Full interface translation will be added later.</p>
              <select value={language} onChange={e => setLanguage(e.target.value)}>
                <option>English</option>
                <option>Swahili</option>
              </select>
            </section>

            <section className="setting-card">
              <h3><LockKeyhole size={19}/> Privacy & History</h3>
              <p>Conversations are associated with your Veltrix AI account.</p>
              <p className="notice">
                Your conversations are saved to your signed-in
                Veltrix AI account on the local development server.
                They are not stored in browser localStorage.
                Chat messages are processed by the configured AI
                provider. Production encryption, retention controls,
                and account recovery are still being developed.
              </p>
              <button className="outline-btn" onClick={exportChats}>
                <Download size={17}/> Export conversations
              </button>
              <button className="danger-btn" onClick={() => {
                if (confirm("Permanently delete all saved conversations from your account?")) {
                  setThreads([]);
                  setActiveId(null);
                }
              }}>
                <Trash2 size={17}/> Delete local conversations
              </button>
            </section>

            <section className="setting-card">
              <h3><ShieldCheck size={19}/> Security</h3>
              <p>
                Account security, multi-factor authentication, encrypted server storage,
                session management, and enterprise permissions will be connected
                during backend development.
              </p>
            </section>
          </div>
        )}

        {page === "account" && (
          <AccountPanel
            user={authenticatedUser}
            onUpdate={setAuthenticatedUser}
            onLogout={() => {
              setAuthenticatedUser(null);
              setThreads([]);
              setActiveId(null);
              setPage("chat");
            }}
          />
        )}

        {page === "enterprise" && <EnterprisePanel />}

        {page === "admin" &&
          authenticatedUser.role === "admin" &&
          <PlatformAdmin />
        }
      </main>
    </div>
  );
}
