import { useCallback, useEffect, useState } from "react";
import {
  Building2, Plus, Users, ShieldCheck,
  Copy, RefreshCw, UserPlus, Trash2
} from "lucide-react";

type Organization = {
  id: string;
  name: string;
  role: "owner" | "admin" | "member";
};

type Member = {
  id: string;
  name: string;
  email: string;
  role: string;
};

async function api<T>(
  path: string,
  options?: RequestInit
): Promise<T> {
  const response = await fetch(path, {
    ...options,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });

  const result = await response.json();

  if (!response.ok) {
    throw new Error(
      typeof result.detail === "string"
        ? result.detail
        : "Request failed."
    );
  }

  return result as T;
}

export default function EnterprisePanel() {
  const [organizations, setOrganizations] =
    useState<Organization[]>([]);
  const [selected, setSelected] =
    useState<Organization | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [name, setName] = useState("");
  const [invite, setInvite] = useState("");
  const [joinCode, setJoinCode] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  const loadOrganizations = useCallback(async () => {
    const result = await api<{
      organizations: Organization[];
    }>("/api/enterprise/organizations");

    setOrganizations(result.organizations);

    setSelected(previous =>
      result.organizations.find(
        org => org.id === previous?.id
      ) || result.organizations[0] || null
    );
  }, []);

  const loadMembers = useCallback(async (id: string) => {
    const result = await api<{ members: Member[] }>(
      `/api/enterprise/organizations/${encodeURIComponent(id)}/members`
    );
    setMembers(result.members);
  }, []);

  useEffect(() => {
    loadOrganizations().catch(e => setError(e.message));
  }, [loadOrganizations]);

  useEffect(() => {
    if (selected) {
      loadMembers(selected.id).catch(e => setError(e.message));
    } else {
      setMembers([]);
    }
  }, [selected?.id, loadMembers]);

  async function perform(action: () => Promise<void>) {
    setBusy(true);
    setError("");
    setNotice("");

    try {
      await action();
    } catch (e) {
      setError(
        e instanceof Error ? e.message : "Operation failed."
      );
    } finally {
      setBusy(false);
    }
  }

  const manager =
    selected?.role === "owner" ||
    selected?.role === "admin";

  return (
    <div className="page-content enterprise-panel">
      <div className="page-heading">
        <Building2 size={29} />
        <div>
          <h2>Veltrix Enterprise</h2>
          <p>Manage your company's AI workspace and staff.</p>
        </div>
      </div>

      {error && (
        <div className="error-msg" role="alert">{error}</div>
      )}

      {notice && (
        <div className="notice" role="status">{notice}</div>
      )}

      <div className="setting-card">
        <h3><Plus size={19}/> Create organization</h3>
        <p>Set up a new company workspace.</p>
        <form
          className="enterprise-form"
          onSubmit={event => {
            event.preventDefault();
            perform(async () => {
              const result = await api<Organization>(
                "/api/enterprise/organizations",
                {
                  method: "POST",
                  body: JSON.stringify({ name }),
                }
              );
              setName("");
              await loadOrganizations();
              setSelected(result);
              setNotice("Organization created successfully.");
            });
          }}
        >
          <input
            aria-label="Company name"
            placeholder="Company or organization name"
            value={name}
            onChange={event => setName(event.target.value)}
            minLength={2}
            maxLength={100}
            required
          />
          <button
            className="enterprise-action"
            type="submit"
            disabled={busy}
          >
            <Plus size={17}/> Create
          </button>
        </form>
      </div>

      <div className="setting-card">
        <h3><UserPlus size={19}/> Join an organization</h3>
        <p>Enter an invitation code provided by a company administrator.</p>
        <form
          className="enterprise-form"
          onSubmit={event => {
            event.preventDefault();
            perform(async () => {
              await api("/api/enterprise/join", {
                method: "POST",
                body: JSON.stringify({ code: joinCode.trim() }),
              });
              setJoinCode("");
              await loadOrganizations();
              setNotice("You joined the organization.");
            });
          }}
        >
          <input
            aria-label="Invitation code"
            placeholder="Paste invitation code"
            value={joinCode}
            onChange={event => setJoinCode(event.target.value)}
            required
          />
          <button
            className="enterprise-action"
            type="submit"
            disabled={busy}
          >
            Join
          </button>
        </form>
      </div>

      <div className="setting-card">
        <h3><Building2 size={19}/> Your organizations</h3>

        {organizations.length === 0 ? (
          <p>No organizations yet. Create one above or join with an invitation.</p>
        ) : (
          <div className="enterprise-organizations">
            {organizations.map(org => (
              <button
                key={org.id}
                className={
                  selected?.id === org.id ? "chosen" : ""
                }
                onClick={() => setSelected(org)}
              >
                <Building2 size={18}/>
                <span>{org.name}</span>
                <small>{org.role}</small>
              </button>
            ))}
          </div>
        )}
      </div>

      {selected && (
        <div className="setting-card">
          <h3><Users size={19}/> {selected.name} — Staff</h3>
          <p>Your role: <strong>{selected.role}</strong></p>

          <button
            className="outline-btn"
            onClick={() =>
              perform(async () => loadMembers(selected.id))
            }
          >
            <RefreshCw size={16}/> Refresh members
          </button>

          {manager && (
            <>
              <button
                className="enterprise-action"
                disabled={busy}
                onClick={() => perform(async () => {
                  const result = await api<{
                    code: string;
                  }>(
                    `/api/enterprise/organizations/${selected.id}/invites`,
                    { method: "POST" }
                  );
                  setInvite(result.code);
                  setNotice(
                    "A one-use invitation was created. It expires in 24 hours."
                  );
                })}
              >
                <UserPlus size={16}/> Generate staff invitation
              </button>

              {invite && (
                <div className="enterprise-invite">
                  <code>{invite}</code>
                  <button
                    className="outline-btn"
                    onClick={() =>
                      navigator.clipboard.writeText(invite)
                    }
                  >
                    <Copy size={15}/> Copy invitation
                  </button>
                </div>
              )}
            </>
          )}

          <div className="enterprise-members">
            {members.map(member => (
              <div className="enterprise-member" key={member.id}>
                <div>
                  <strong>{member.name}</strong>
                  <small>{member.email}</small>
                </div>
                <span>{member.role}</span>

                {manager &&
                  member.role !== "owner" &&
                  (member.role !== "admin" ||
                    selected.role === "owner") && (
                    <button
                      className="small-icon"
                      aria-label={`Remove ${member.name}`}
                      disabled={busy}
                      onClick={() => {
                        if (!confirm(
                          `Remove ${member.name} from this organization?`
                        )) return;

                        perform(async () => {
                          await api(
                            `/api/enterprise/organizations/${selected.id}/members/${member.id}`,
                            { method: "DELETE" }
                          );
                          await loadMembers(selected.id);
                          setNotice("Member removed.");
                        });
                      }}
                    >
                      <Trash2 size={16}/>
                    </button>
                  )}
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="setting-card">
        <h3><ShieldCheck size={19}/> Enterprise security</h3>
        <p>
          Organization membership is checked by the backend.
          Invitation codes are one-use and expire after 24 hours.
        </p>
        <p className="notice">
          Company knowledge, company-specific conversation storage,
          verified business ownership, billing, and deployment
          isolation are not active yet. Do not upload confidential
          business information during development.
        </p>
      </div>
    </div>
  );
}
