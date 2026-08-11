import { FormEvent, useState } from 'react';
import { ApiError, apiClient, type AdminSession, type MFAEnrollment } from '../api/client';

interface Props { onAuthenticated(session: AdminSession): void; }
type Phase = 'password' | 'enroll' | 'mfa' | 'recovery-codes';

export function LoginPage({ onAuthenticated }: Props) {
  const [phase, setPhase] = useState<Phase>('password');
  const [challengeToken, setChallengeToken] = useState('');
  const [enrollment, setEnrollment] = useState<MFAEnrollment | null>(null);
  const [pendingSession, setPendingSession] = useState<AdminSession | null>(null);
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [useRecoveryCode, setUseRecoveryCode] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function submitPassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true); setError('');
    const data = new FormData(event.currentTarget);
    try {
      const login = await apiClient.adminLogin(String(data.get('email') ?? ''), String(data.get('password') ?? ''));
      setChallengeToken(login.challengeToken);
      if (login.enrollmentRequired) {
        const nextEnrollment = await apiClient.beginMFAEnrollment(login.challengeToken);
        setEnrollment(nextEnrollment);
        setPhase('enroll');
      } else {
        setPhase('mfa');
      }
    } catch (caught) { setError(formatError(caught)); }
    finally { setBusy(false); }
  }

  async function submitEnrollment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true); setError('');
    const code = String(new FormData(event.currentTarget).get('code') ?? '');
    try {
      const result = await apiClient.verifyMFAEnrollment(challengeToken, code);
      setPendingSession(result.session);
      setRecoveryCodes(result.recoveryCodes);
      setPhase('recovery-codes');
    } catch (caught) { setError(formatError(caught)); }
    finally { setBusy(false); }
  }

  async function submitMFA(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true); setError('');
    const data = new FormData(event.currentTarget);
    try {
      const session = await apiClient.verifyMFA(
        challengeToken,
        useRecoveryCode ? '' : String(data.get('code') ?? ''),
        useRecoveryCode ? String(data.get('recoveryCode') ?? '') : '',
      );
      onAuthenticated(session);
    } catch (caught) { setError(formatError(caught)); }
    finally { setBusy(false); }
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="brand-mark" aria-hidden="true">DD</div>
        <p className="eyebrow">Administrator security domain</p>
        <h1>DD 管理后台</h1>
        <p className="muted">管理员身份与普通 DD 账号完全隔离。密码通过后仍必须完成 TOTP 或一次性恢复码验证。</p>

        {phase === 'password' ? (
          <form onSubmit={submitPassword} className="stack">
            <label>管理员邮箱<input name="email" type="email" autoComplete="username" required /></label>
            <label>密码<input name="password" type="password" autoComplete="current-password" required /></label>
            <button type="submit" disabled={busy}>{busy ? '验证中…' : '继续'}</button>
          </form>
        ) : null}

        {phase === 'enroll' && enrollment ? (
          <form onSubmit={submitEnrollment} className="stack">
            <div className="security-box">
              <strong>首次登录：绑定 TOTP</strong>
              <p>在密码管理器或验证器中添加下面的密钥，然后输入当前 6 位验证码。</p>
              <code className="secret-code">{enrollment.secret}</code>
              <details><summary>显示 otpauth URI</summary><code className="wrap-code">{enrollment.otpauthUri}</code></details>
            </div>
            <label>6 位验证码<input name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required /></label>
            <button type="submit" disabled={busy}>{busy ? '绑定中…' : '绑定并登录'}</button>
          </form>
        ) : null}

        {phase === 'mfa' ? (
          <form onSubmit={submitMFA} className="stack">
            {useRecoveryCode ? (
              <label>一次性恢复码<input name="recoveryCode" autoComplete="one-time-code" required /></label>
            ) : (
              <label>6 位 TOTP<input name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required /></label>
            )}
            <button type="submit" disabled={busy}>{busy ? '验证中…' : '登录'}</button>
            <button className="secondary-button" type="button" onClick={() => setUseRecoveryCode((value) => !value)}>
              {useRecoveryCode ? '改用 TOTP' : '验证器不可用？使用恢复码'}
            </button>
          </form>
        ) : null}

        {phase === 'recovery-codes' ? (
          <div className="stack">
            <div className="warning-box">
              <strong>只显示一次：保存恢复码</strong>
              <p>每个恢复码只能使用一次。不要截图后留在公共设备。</p>
              <div className="recovery-grid">{recoveryCodes.map((code) => <code key={code}>{code}</code>)}</div>
            </div>
            <button type="button" onClick={() => pendingSession && onAuthenticated(pendingSession)} disabled={!pendingSession}>我已安全保存恢复码</button>
          </div>
        ) : null}

        {error ? <p className="error-box" role="alert">{error}</p> : null}
      </section>
    </main>
  );
}

function formatError(error: unknown): string {
  if (error instanceof ApiError) return `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}`;
  return error instanceof Error ? error.message : '未知网络错误';
}
