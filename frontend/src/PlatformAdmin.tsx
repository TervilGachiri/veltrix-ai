import { useEffect, useState } from "react";
import {
  ShieldCheck, Users, Building2,
  MessagesSquare, Activity, RefreshCw
} from "lucide-react";

type Overview = {
  users: number;
  conversations: number;
  organizations: number;
  memberships: number;
  active_sessions: number;
  administrator: string;
};

type PlatformUser = {
  id: string;
  name: string;
  email: string;
  role: string;
};

export default function PlatformAdmin() {
  const [overview, setOverview] = useState<Overview | null>(null);
  const [users, setUsers] = useState<PlatformUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  async function load() {
    setLoading(true);
    setError("");

    try {
      const [overviewResponse, usersResponse] = await Promise.all([
        fetch("/api/platform/overview", {
          credentials: "same-origin"
        }),
        fetch("/api/platform/users", {
          credentials: "same-origin"
        })
      ]);

      if (!overviewResponse.ok || !usersResponse.ok) {
        throw new Error(
          "Unable to load administration data. Verify administrator permissions."
        );
      }

      const summary = await overviewResponse.json();
      const people = await usersResponse.json();

      setOverview(summary);
      setUsers(people.users || []);
    } catch (e) {
      setError(
        e instanceof Error ? e.message : "Dashboard unavailable."
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <div className="page-content">
      <div className="page-heading">
        <ShieldCheck size={28}/>
        <div>
          <h2>Veltrix Administration</h2>
          <p>Platform management and security overview.</p>
        </div>
      </div>

      {error && <div className="error-msg" role="alert">{error}</div>}

      <button className="outline-btn" onClick={load}>
        <RefreshCw size={16}/> Refresh dashboard
      </button>

      {loading && <p>Loading administration data...</p>}

      {overview && !loading && (
        <>
          <div className="admin-stats">
            {[
              ["Registered users", overview.users, Users],
              ["Conversations", overview.conversations, MessagesSquare],
              ["Organizations", overview.organizations, Building2],
              ["Active sessions", overview.active_sessions, Activity]
            ].map(([label, value, Icon]) => {
              const Symbol = Icon as typeof Users;
              return (
                <div className="feature-card" key={String(label)}>
                  <Symbol size={22}/>
                  <h3>{String(value)}</h3>
                  <p>{String(label)}</p>
                </div>
              );
            })}
          </div>

          <section className="setting-card">
            <h3><Users size={19}/> Registered users</h3>
            <p>Showing up to 100 registered accounts.</p>

            <div className="admin-user-list">
              {users.map(user => (
                <div className="enterprise-member" key={user.id}>
                  <div>
                    <strong>{user.name}</strong>
                    <small>{user.email}</small>
                  </div>
                  <span>{user.role}</span>
                </div>
              ))}
            </div>
          </section>

          <section className="setting-card">
            <h3><ShieldCheck size={19}/> Privacy and access</h3>
            <p>
              This dashboard shows account information and aggregated
              conversation counts. It does not expose private
              conversation contents.
            </p>
            <p className="notice">
              Authorized conversation review, retention policies,
              incident response, and enterprise data controls require
              additional security and privacy implementation.
            </p>
          </section>
        </>
      )}
    </div>
  );
}
