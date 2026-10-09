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
