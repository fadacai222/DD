import { FormEvent, useCallback, useEffect, useState } from 'react';
import {
  ApiError,
  apiClient,
  type AdminSession,
  type AdminSessionItem,
  type AuditItem,
  type ReportItem,
  type ReportStatus,
  type UserItem,
} from '../api/client';

interface Props {
  session: AdminSession;
  onSessionLost(): void;
}

type Tab = 'reports' | 'users' | 'audit' | 'sessions';

export function GovernancePage({ session, onSessionLost }: Props) {
  const [tab, setTab] = useState<Tab>('reports');
  const [reports, setReports] = useState<ReportItem[]>([]);
  const [users, setUsers] = useState<UserItem[]>([]);
  const [audit, setAudit] = useState<AuditItem[]>([]);
  const [sessions, setSessions] = useState<AdminSessionItem[]>([]);
  const [reportStatus, setReportStatus] = useState('');
  const [userQuery, setUserQuery] = useState('');
  const [userStatus, setUserStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);

  const run = useCallback(async (operation: () => Promise<void>) => {
    setBusy(true); setError('');
    try { await operation(); }
    catch (caught) {
      if (caught instanceof ApiError && caught.status === 401) onSessionLost();
      setError(formatError(caught));
    } finally { setBusy(false); }
  }, [onSessionLost]);

  const loadReports = useCallback(() => run(async () => setReports(await apiClient.listReports(reportStatus))), [reportStatus, run]);
  const loadUsers = useCallback(() => run(async () => setUsers(await apiClient.listUsers(userQuery, userStatus))), [run, userQuery, userStatus]);
  const loadAudit = useCallback(() => run(async () => setAudit(await apiClient.listAudit())), [run]);
  const loadSessions = useCallback(() => run(async () => setSessions(await apiClient.listAdminSessions())), [run]);

  useEffect(() => {
    if (tab === 'reports') void loadReports();
    if (tab === 'users') void loadUsers();
    if (tab === 'audit' && session.admin.role !== 'MODERATOR') void loadAudit();
    if (tab === 'sessions') void loadSessions();
  }, [tab, loadAudit, loadReports, loadSessions, loadUsers, session.admin.role]);

  async function logout() {
    await run(async () => { await apiClient.logoutAdmin(); onSessionLost(); });
  }

  async function transitionReport(report: ReportItem, status: ReportStatus) {
    const reason = requestReason('必须记录本次举报处置原因');
    if (!reason) return;
    await run(async () => {
      const updated = await apiClient.updateReport(report.id, status, reason);
      setReports((items) => items.map((item) => item.id === updated.id ? updated : item));
    });
  }

  async function moderateUser(user: UserItem, action: 'suspend' | 'unsuspend') {
    const reason = requestReason(action === 'suspend' ? '必须记录冻结原因' : '必须记录解冻原因');
    if (!reason) return;
    await run(async () => {
      const updated = await apiClient.moderateUser(user.id, action, reason);
      setUsers((items) => items.map((item) => item.id === updated.id ? updated : item));
    });
  }

  async function revoke(item: AdminSessionItem) {
    if (!window.confirm(item.current ? '撤销当前会话后会立即退出。继续？' : '撤销这个管理员会话？')) return;
    await run(async () => {
      await apiClient.revokeAdminSession(item.id);
      if (item.current) onSessionLost();
      else await loadSessions();
    });
  }

  async function regenerateRecovery(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const code = String(new FormData(event.currentTarget).get('code') ?? '');
    await run(async () => setRecoveryCodes(await apiClient.regenerateRecoveryCodes(code)));
    event.currentTarget.reset();
  }

  return (
    <main className="admin-shell">
      <header className="admin-header">
        <div>
          <p className="eyebrow">P12 governance</p>
          <h1>DD 管理与治理</h1>
          <p className="muted">{session.admin.email} · <strong>{roleLabel(session.admin.role)}</strong></p>
        </div>
        <button className="danger-button" onClick={() => void logout()} disabled={busy}>退出管理员会话</button>
      </header>

      <nav className="tabbar" aria-label="管理后台功能">
        <button className={tab === 'reports' ? 'active' : ''} onClick={() => setTab('reports')}>举报队列</button>
        <button className={tab === 'users' ? 'active' : ''} onClick={() => setTab('users')}>用户治理</button>
        <button className={tab === 'audit' ? 'active' : ''} onClick={() => setTab('audit')}>安全审计</button>
        <button className={tab === 'sessions' ? 'active' : ''} onClick={() => setTab('sessions')}>管理员会话</button>
      </nav>

      {error ? <p className="error-box" role="alert">{error}</p> : null}

      {tab === 'reports' ? (
        <section className="panel stack">
          <div className="toolbar">
            <select value={reportStatus} onChange={(event) => setReportStatus(event.target.value)}>
              <option value="">全部状态</option><option value="PENDING">待处理</option><option value="IN_REVIEW">处理中</option><option value="RESOLVED">已解决</option><option value="DISMISSED">已驳回</option>
            </select>
            <button onClick={() => void loadReports()} disabled={busy}>刷新</button>
          </div>
          <div className="card-list">
            {reports.map((report) => (
              <article className="data-card" key={report.id}>
                <div className="row-between"><strong>{report.category}</strong><span className="status-pill">{report.status}</span></div>
                <p>{report.reason}</p>
                <p className="muted">举报人 @{report.reporterHandle ?? report.reporterUserId} → 被举报 @{report.targetHandle ?? report.targetUserId}</p>
                <small>{formatTime(report.createdAt)}</small>
                {report.resolutionReason ? <p><strong>处置原因：</strong>{report.resolutionReason}</p> : null}
                {session.admin.role !== 'SUPPORT_READ_ONLY' && (report.status === 'PENDING' || report.status === 'IN_REVIEW') ? (
                  <div className="action-row">
                    {report.status === 'PENDING' ? <button onClick={() => void transitionReport(report, 'IN_REVIEW')}>接手</button> : null}
                    <button onClick={() => void transitionReport(report, 'RESOLVED')}>解决</button>
                    <button className="secondary-button" onClick={() => void transitionReport(report, 'DISMISSED')}>驳回</button>
                  </div>
                ) : null}
              </article>
            ))}
            {!busy && reports.length === 0 ? <p className="muted">当前筛选条件下没有举报。</p> : null}
          </div>
        </section>
      ) : null}

      {tab === 'users' ? (
        <section className="panel stack">
          <form className="toolbar" onSubmit={(event) => { event.preventDefault(); void loadUsers(); }}>
            <input value={userQuery} onChange={(event) => setUserQuery(event.target.value)} placeholder="邮箱 / DD ID / 昵称" />
            <select value={userStatus} onChange={(event) => setUserStatus(event.target.value)}><option value="">全部状态</option><option value="ACTIVE">ACTIVE</option><option value="SUSPENDED">SUSPENDED</option></select>
            <button type="submit" disabled={busy}>查询</button>
          </form>
          <div className="card-list">
            {users.map((user) => (
              <article className="data-card" key={user.id}>
                <div className="row-between"><strong>{user.displayName} · @{user.handle}</strong><span className="status-pill">{user.status}</span></div>
                <p className="muted">{user.email}<br /><code>{user.id}</code></p>
                {session.admin.role === 'SUPER_ADMIN' ? (
                  <div className="action-row">
                    {user.status === 'ACTIVE' ? <button className="danger-button" onClick={() => void moderateUser(user, 'suspend')}>冻结账号</button> : null}
                    {user.status === 'SUSPENDED' ? <button onClick={() => void moderateUser(user, 'unsuspend')}>解除冻结</button> : null}
                  </div>
                ) : <p className="muted">当前角色只有读取权限；冻结/解冻仅 SUPER_ADMIN 可执行。</p>}
              </article>
            ))}
          </div>
        </section>
      ) : null}

      {tab === 'audit' ? (
        <section className="panel stack">
          {session.admin.role === 'MODERATOR' ? <p className="warning-box">MODERATOR 无权浏览全量管理员安全审计。</p> : (
            <>
              <div className="toolbar"><button onClick={() => void loadAudit()} disabled={busy}>刷新审计</button></div>
              <div className="card-list">
                {audit.map((item) => <article className="data-card" key={item.id}><div className="row-between"><strong>{item.action}</strong><small>{formatTime(item.createdAt)}</small></div><p>{item.targetType} {item.targetId}</p>{item.reason ? <p><strong>原因：</strong>{item.reason}</p> : null}<p className="muted">角色 {item.actorRole ?? 'SYSTEM'} · IP {item.clientIp || 'unknown'}</p></article>)}
              </div>
            </>
          )}
        </section>
      ) : null}

      {tab === 'sessions' ? (
        <section className="panel stack">
          <div className="toolbar"><button onClick={() => void loadSessions()} disabled={busy}>刷新会话</button></div>
          <div className="card-list">
            {sessions.map((item) => <article className="data-card" key={item.id}><div className="row-between"><strong>{item.current ? '当前会话' : '管理员会话'}</strong><span className="status-pill">{item.revokedAt ? 'REVOKED' : 'ACTIVE'}</span></div><p className="muted">{item.clientIp || 'unknown IP'} · {item.userAgent || 'unknown user agent'}</p><p>最后活动 {formatTime(item.lastSeenAt)} · 绝对过期 {formatTime(item.expiresAt)}</p>{!item.revokedAt ? <button className="danger-button" onClick={() => void revoke(item)}>撤销会话</button> : null}</article>)}
          </div>
          <form className="recovery-form" onSubmit={regenerateRecovery}>
            <h2>重新生成恢复码</h2>
            <p className="muted">需要一个新的、未重放的 TOTP。生成后旧恢复码立即失效。</p>
            <label>当前 TOTP<input name="code" inputMode="numeric" pattern="[0-9]{6}" maxLength={6} required /></label>
            <button type="submit" disabled={busy}>重新生成</button>
          </form>
          {recoveryCodes.length ? <div className="warning-box"><strong>新的恢复码（只显示本次）</strong><div className="recovery-grid">{recoveryCodes.map((code) => <code key={code}>{code}</code>)}</div></div> : null}
        </section>
      ) : null}
    </main>
  );
}

function requestReason(message: string): string | null {
  const value = window.prompt(`${message}（至少 3 个字符）`)?.trim() ?? '';
  return value.length >= 3 ? value : null;
}
function formatTime(value: string): string { return new Date(value).toLocaleString(); }
function roleLabel(role: AdminSession['admin']['role']): string {
  if (role === 'SUPER_ADMIN') return 'Super Admin';
  if (role === 'MODERATOR') return 'Moderator';
  return 'Support / Read only';
}
function formatError(error: unknown): string {
  if (error instanceof ApiError) return `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}`;
  return error instanceof Error ? error.message : '未知网络错误';
}
