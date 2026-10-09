#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="backups/teams-$STAMP"
mkdir -p "$BACKUP"

cp frontend/src/main.tsx "$BACKUP/main.tsx"

for file in TeamWorkspace.tsx team-workspace.css; do
  if [ -f "frontend/src/$file" ]; then
    cp "frontend/src/$file" "$BACKUP/$file"
  fi
done

echo "===== INSTALLING VELTRIX TEAM WORKSPACES ====="

cat > frontend/src/TeamWorkspace.tsx <<'TSX'
import { useCallback, useEffect, useState } from 'react';
import {
  Users, Building2, Plus, X, Copy, Send,
  FolderKanban, ArrowLeft, UserPlus, RefreshCw,
  ShieldCheck, Loader2, LogIn
} from 'lucide-react';
import './team-workspace.css';

type Org = {
  id: string;
  name: string;
  role: string;
};
type Member = {
  id: string;
  name: string;
  email: string;
  role: string;
};
type Project = {
  id: string;
  name: string;
  description: string;
};
type Post = {
  id: string;
  author: string;
  content: string;
  created_at: number;
};

async function api<T>(
  path: string,
  method = 'GET',
  data?: unknown
): Promise<T> {
  const response = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers: data === undefined
      ? undefined
      : { 'Content-Type': 'application/json' },
    body: data === undefined
      ? undefined
      : JSON.stringify(data)
  });

  if (!response.ok) {
    let detail = `Request failed: HTTP ${response.status}`;
    try {
      const body = await response.json();
      if (typeof body.detail === 'string') detail = body.detail;
    } catch {
      // Keep HTTP error.
    }
    throw new Error(detail);
  }

  return response.json() as Promise<T>;
}

export default function TeamWorkspace() {
  const [open, setOpen] = useState(false);
  const [orgs, setOrgs] = useState<Org[]>([]);
  const [org, setOrg] = useState<Org | null>(null);
  const [projects, setProjects] = useState<Project[]>([]);
  const [project, setProject] = useState<Project | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [posts, setPosts] = useState<Post[]>([]);
  const [companyName, setCompanyName] = useState('');
  const [joinCode, setJoinCode] = useState('');
  const [projectName, setProjectName] = useState('');
  const [description, setDescription] = useState('');
  const [message, setMessage] = useState('');
  const [invite, setInvite] = useState('');
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [busy, setBusy] = useState(false);

  const orgPath = org
    ? `/api/v2/organizations/${encodeURIComponent(org.id)}/projects`
    : '';

  const refreshOrganizations = useCallback(async () => {
    const result = await api<{ organizations: Org[] }>(
      '/api/enterprise/organizations'
    );
    setOrgs(result.organizations);
  }, []);

  const refreshWorkspace = useCallback(async (selected: Org) => {
    const id = encodeURIComponent(selected.id);
    const [projectResult, memberResult] = await Promise.all([
      api<{ projects: Project[] }>(
        `/api/v2/organizations/${id}/projects`
      ),
      api<{ members: Member[] }>(
        `/api/enterprise/organizations/${id}/members`
      )
    ]);
    setProjects(projectResult.projects);
    setMembers(memberResult.members);
  }, []);

  const refreshPosts = useCallback(async (
    selectedOrg: Org,
    selectedProject: Project
  ) => {
    const id = encodeURIComponent(selectedOrg.id);
    const pid = encodeURIComponent(selectedProject.id);
    const result = await api<{ messages: Post[] }>(
      `/api/v2/organizations/${id}/projects/${pid}/messages`
    );
    setPosts(result.messages);
  }, []);

  useEffect(() => {
    if (!open) return;
    setError('');
    void refreshOrganizations().catch(e => {
      setError(e instanceof Error ? e.message : 'Cannot load teams.');
    });
  }, [open, refreshOrganizations]);

  async function run(action: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError('');
    setInfo('');
    try {
      await action();
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : 'Request failed.'
      );
    } finally {
      setBusy(false);
    }
  }

  function selectOrg(selected: Org) {
    setOrg(selected);
    setProject(null);
    setPosts([]);
    setInvite('');
    void run(() => refreshWorkspace(selected));
  }

  function selectProject(selected: Project) {
    if (!org) return;
    setProject(selected);
    setPosts([]);
    void run(() => refreshPosts(org, selected));
  }

  async function createOrg() {
    if (!companyName.trim()) return;
    await run(async () => {
      const created = await api<Org>(
        '/api/enterprise/organizations',
        'POST',
        { name: companyName.trim() }
      );
      setCompanyName('');
      await refreshOrganizations();
      selectOrg(created);
    });
  }

  async function joinOrg() {
    if (!joinCode.trim()) return;
    await run(async () => {
      await api(
        '/api/enterprise/join',
        'POST',
        { code: joinCode.trim() }
      );
      setJoinCode('');
      setInfo('You have joined the organization.');
      await refreshOrganizations();
    });
  }

  async function createProject() {
    if (!org || !projectName.trim()) return;
    await run(async () => {
      await api(orgPath, 'POST', {
        name: projectName.trim(),
        description: description.trim()
      });
      setProjectName('');
      setDescription('');
      await refreshWorkspace(org);
      setInfo('Project created.');
    });
  }

  async function generateInvite() {
    if (!org) return;
    await run(async () => {
      const result = await api<{ code: string }>(
        `/api/enterprise/organizations/${encodeURIComponent(org.id)}/invites`,
        'POST'
      );
      setInvite(result.code);
      setInfo('One-use invitation generated. Expires in 24 hours.');
    });
  }

  async function sendPost() {
    if (!org || !project || !message.trim()) return;
    await run(async () => {
      const id = encodeURIComponent(org.id);
      const pid = encodeURIComponent(project.id);
      await api(
        `/api/v2/organizations/${id}/projects/${pid}/messages`,
        'POST',
        { content: message.trim() }
      );
      setMessage('');
      await refreshPosts(org, project);
    });
  }

  return (
    <>
      <button
        className="vt-launch"
        onClick={() => setOpen(true)}
        title="Team Workspaces"
      >
        <Users size={18} /> Teams
      </button>

      {open && (
        <div className="vt-overlay" onMouseDown={e => {
          if (e.target === e.currentTarget) setOpen(false);
        }}>
          <section className="vt-panel" role="dialog"
            aria-modal="true" aria-label="Veltrix Team Workspaces">

            <header className="vt-header">
              <div>
                <small>VELTRIX AI BUSINESS</small>
                <h2>Team Workspaces</h2>
                <p>Collaborate securely within your organization.</p>
              </div>
              <button className="vt-icon" onClick={() => setOpen(false)}
                aria-label="Close"><X size={21}/></button>
            </header>

            {error && <div className="vt-error" role="alert">{error}</div>}
            {info && <div className="vt-info">{info}</div>}
            {busy && <div className="vt-loading">
              <Loader2 size={16} className="vt-spin"/> Working…
            </div>}

            <div className="vt-body">
              {!org && (
                <>
                  <h3><Building2 size={19}/> Your organizations</h3>
                  <div className="vt-cards">
                    {orgs.map(item => (
                      <button key={item.id} className="vt-org"
                        onClick={() => selectOrg(item)}>
                        <Building2 size={20}/>
                        <span><strong>{item.name}</strong>
                          <small>{item.role}</small></span>
                        <span>→</span>
                      </button>
                    ))}
                    {orgs.length === 0 && (
                      <p className="vt-muted">
                        Create a workspace or join an existing team.
                      </p>
                    )}
                  </div>

                  <div className="vt-grid">
                    <div className="vt-card">
                      <h3><Plus size={18}/> Create organization</h3>
                      <input placeholder="Company name" value={companyName}
                        onChange={e => setCompanyName(e.target.value)}/>
                      <button onClick={() => void createOrg()}
                        disabled={busy || companyName.trim().length < 2}>
                        Create workspace
                      </button>
                    </div>
                    <div className="vt-card">
                      <h3><LogIn size={18}/> Join a team</h3>
                      <input placeholder="Paste invitation code"
                        value={joinCode}
                        onChange={e => setJoinCode(e.target.value)}/>
                      <button onClick={() => void joinOrg()}
                        disabled={busy || !joinCode.trim()}>
                        Join organization
                      </button>
                    </div>
                  </div>
                </>
              )}

              {org && !project && (
                <>
                  <button className="vt-back"
                    onClick={() => {setOrg(null);setProject(null);}}>
                    <ArrowLeft size={16}/> All organizations
                  </button>
                  <h3><Building2 size={19}/>{org.name}</h3>
                  <p className="vt-muted">
                    Your role: <strong>{org.role}</strong>
                  </p>

                  {(org.role === 'owner' || org.role === 'admin') && (
                    <div className="vt-card">
                      <h3><UserPlus size={18}/> Invite a colleague</h3>
                      <button onClick={() => void generateInvite()}
                        disabled={busy}>Generate invitation code</button>
                      {invite && <div className="vt-invite">
                        <code>{invite}</code>
                        <button onClick={() =>
                          void navigator.clipboard.writeText(invite)}>
                          <Copy size={16}/> Copy
                        </button>
                      </div>}
                      <p className="vt-muted">
                        Share the code privately. It works once and
                        expires after 24 hours.
                      </p>
                    </div>
                  )}

                  <div className="vt-card">
                    <h3><FolderKanban size={18}/> Shared projects</h3>
                    <div className="vt-cards">
                      {projects.map(item => (
                        <button key={item.id} className="vt-org"
                          onClick={() => selectProject(item)}>
                          <FolderKanban size={19}/>
                          <span><strong>{item.name}</strong>
                            <small>{item.description || 'Team project'}</small>
                          </span><span>→</span>
                        </button>
                      ))}
                      {projects.length === 0 &&
                        <p className="vt-muted">No projects created yet.</p>}
                    </div>
                    <input placeholder="New project name"
                      value={projectName}
                      onChange={e => setProjectName(e.target.value)}/>
                    <input placeholder="Project description (optional)"
                      value={description}
                      onChange={e => setDescription(e.target.value)}/>
                    <button disabled={busy || projectName.trim().length < 2}
                      onClick={() => void createProject()}>
                      <Plus size={16}/> Create project
                    </button>
                  </div>

                  <div className="vt-card">
                    <h3><Users size={18}/> Team members ({members.length})</h3>
                    {members.map(member => (
                      <div className="vt-member" key={member.id}>
                        <span>
                          <strong>{member.name}</strong>
                          <small>{member.email}</small>
                        </span>
                        <span className="vt-role">{member.role}</span>
                      </div>
                    ))}
                  </div>
                </>
              )}

              {org && project && (
                <>
                  <button className="vt-back"
                    onClick={() => {setProject(null);setPosts([]);}}>
                    <ArrowLeft size={16}/> {org.name}
                  </button>
                  <h3><FolderKanban size={19}/>{project.name}</h3>
                  <p className="vt-muted">{project.description}</p>

                  <div className="vt-posts">
                    {posts.map(post => (
                      <div key={post.id} className="vt-post">
                        <div><strong>{post.author}</strong>
                          <small>{new Date(
                            post.created_at * 1000
                          ).toLocaleString()}</small>
                        </div>
                        <p>{post.content}</p>
                      </div>
                    ))}
                    {posts.length === 0 &&
                      <p className="vt-muted">
                        Start the team discussion.
                      </p>}
                  </div>

                  <div className="vt-card">
                    <textarea rows={3}
                      placeholder="Write a message to your team…"
                      value={message}
                      onChange={e => setMessage(e.target.value)}/>
                    <div className="vt-actions">
                      <button onClick={() =>
                        void run(() => refreshPosts(org, project))}
                        disabled={busy}>
                        <RefreshCw size={16}/> Refresh
                      </button>
                      <button onClick={() => void sendPost()}
                        disabled={busy || !message.trim()}>
                        <Send size={16}/> Send message
                      </button>
                    </div>
                  </div>
                </>
              )}
            </div>

            <footer className="vt-footer">
              <ShieldCheck size={16}/>
              Workspace access is checked against your organization membership.
            </footer>
          </section>
        </div>
      )}
    </>
  );
}
TSX

cat > frontend/src/team-workspace.css <<'CSS'
.vt-launch{
position:fixed;right:20px;bottom:134px;z-index:89;
display:flex;align-items:center;gap:9px;padding:13px 18px;
border:0;border-radius:15px;background:#126c6b;color:white;
font-weight:700;box-shadow:0 8px 26px #113b3b44}
.vt-overlay{
position:fixed;inset:0;z-index:120;background:#070c1bbb;
display:flex;align-items:center;justify-content:center;padding:15px}
.vt-panel{
width:min(780px,100%);max-height:94vh;
display:flex;flex-direction:column;overflow:hidden;
background:var(--panel,#fff);color:var(--text,#19233d);
border:1px solid var(--line,#ddd);border-radius:22px;
box-shadow:0 30px 90px #0005}
.vt-header{
padding:23px 26px 17px;display:flex;
justify-content:space-between;gap:15px;
border-bottom:1px solid var(--line,#ddd)}
.vt-header small{font-size:10px;letter-spacing:1.5px;
font-weight:800;color:#159b8c}
.vt-header h2{margin:6px 0;font-size:24px}
.vt-header p,.vt-muted{
font-size:12px;line-height:1.6;
color:var(--muted,#75809a)}
.vt-icon,.vt-back{background:transparent;border:0;color:inherit}
.vt-body{overflow:auto;padding:24px 26px;flex:1}
.vt-body h3{display:flex;align-items:center;gap:9px;
font-size:16px;margin:0 0 15px}
.vt-cards{display:grid;gap:9px;margin:12px 0 19px}
.vt-org{
display:flex;align-items:center;gap:12px;width:100%;
border:1px solid var(--line,#ddd);border-radius:12px;
padding:15px;background:var(--bg,#f8f9fc);
color:var(--text,#19233d);text-align:left}
.vt-org>span:nth-child(2){flex:1;min-width:0}
.vt-org strong,.vt-member strong{display:block;font-size:13px}
.vt-org small,.vt-member small{
display:block;font-size:11px;margin-top:5px;
color:var(--muted,#75809a);overflow-wrap:anywhere}
.vt-grid{display:grid;grid-template-columns:1fr 1fr;gap:15px}
.vt-card{
border:1px solid var(--line,#ddd);
border-radius:15px;padding:18px;margin-bottom:17px;
background:var(--bg,#f8f9fc)}
.vt-card input,.vt-card textarea{
width:100%;border:1px solid var(--line,#ddd);
border-radius:10px;padding:12px;margin:6px 0 10px;
background:var(--panel,#fff);color:var(--text,#19233d);
font:inherit;font-size:13px}
.vt-card button,.vt-invite button{
display:inline-flex;align-items:center;gap:8px;
border:0;border-radius:10px;padding:11px 14px;
background:#126c6b;color:white;font-weight:700;font-size:12px}
.vt-card button:disabled{opacity:.45;cursor:default}
.vt-back{display:flex;align-items:center;gap:8px;
padding:0;margin-bottom:22px;font-size:12px;font-weight:700}
.vt-member{display:flex;justify-content:space-between;
align-items:center;border-bottom:1px solid var(--line,#ddd);
padding:11px 0;gap:10px}
.vt-role{font-size:11px;color:#159b8c;font-weight:700}
.vt-invite{display:flex;flex-wrap:wrap;gap:9px;margin-top:12px}
.vt-invite code{flex:1;overflow-wrap:anywhere;font-size:12px;
background:var(--panel,#fff);padding:10px;border-radius:9px}
.vt-posts{min-height:170px;max-height:350px;overflow:auto;
border:1px solid var(--line,#ddd);border-radius:13px;
padding:15px;margin-bottom:15px}
.vt-post{padding:12px 0;border-bottom:1px solid var(--line,#ddd)}
.vt-post>div{display:flex;justify-content:space-between;gap:10px}
.vt-post strong{font-size:12px}.vt-post small{font-size:10px;
color:var(--muted,#75809a)}
.vt-post p{white-space:pre-wrap;overflow-wrap:anywhere;
font-size:13px;line-height:1.6}
.vt-actions{display:flex;justify-content:space-between;gap:10px}
.vt-footer{padding:13px 26px;border-top:1px solid var(--line,#ddd);
display:flex;align-items:center;gap:8px;
font-size:11px;color:var(--muted,#75809a)}
.vt-error,.vt-info,.vt-loading{
padding:12px 26px;font-size:12px}
.vt-error{background:#ffe7eb;color:#b72b43}
.vt-info{background:#ddf8ed;color:#136847}
.vt-loading{display:flex;align-items:center;gap:8px}
.vt-spin{animation:vt-spin 1s linear infinite}
@keyframes vt-spin{to{transform:rotate(360deg)}}
@media(max-width:600px){
.vt-launch{right:12px;bottom:120px;padding:11px 13px}
.vt-grid{grid-template-columns:1fr}
.vt-header,.vt-body{padding:17px}
}
CSS

echo "===== CONNECTING TEAM WORKSPACES ====="

python3 - <<'PY'
from pathlib import Path
import re

p = Path("frontend/src/main.tsx")
source = p.read_text()

if "import TeamWorkspace from " not in source:
    source = (
        "import TeamWorkspace from './TeamWorkspace';\n"
        + source
    )

if "<TeamWorkspace" not in source:
    source, count = re.subn(
        r"<App\s*/>",
        "<App /><TeamWorkspace />",
        source,
        count=1
    )
    if count != 1:
        raise SystemExit("Cannot safely locate App in main.tsx.")

p.write_text(source)
print("Team Workspace connected.")
PY

echo "===== VERIFYING BUILD ====="

if (cd frontend && npm run build); then
  echo "React build passed."
else
  echo "Build failed — restoring previous files."
  cp "$BACKUP/main.tsx" frontend/src/main.tsx

  for file in TeamWorkspace.tsx team-workspace.css; do
    if [ -f "$BACKUP/$file" ]; then
      cp "$BACKUP/$file" "frontend/src/$file"
    else
      rm -f "frontend/src/$file"
    fi
  done

  exit 1
fi

echo "===== VERIFYING BACKEND ====="

curl -sS -o /dev/null \
  -w "Backend HTTP %{http_code}\n" \
  http://127.0.0.1:8001/api/health

echo ""
echo "=========================================="
echo " VELTRIX TEAM WORKSPACES UI INSTALLED"
echo "=========================================="
echo "Organizations: Connected"
echo "Invitations: Connected"
echo "Members: Connected"
echo "Shared projects: Connected"
echo "Project messages: Connected"
echo "Existing chat: Unchanged"
echo "Document Intelligence: Unchanged"
echo "Live AI: Unchanged"
echo "Database: No destructive migration"
echo "Backup: $BACKUP"
echo "=========================================="
