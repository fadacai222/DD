import { FormEvent, useEffect, useState } from 'react';
import {
  ApiError,
  apiClient,
  type AdminSession,
  type TelegramBotInfo,
  type TelegramIntegrationStatus,
} from '../api/client';

interface Props {
  session: AdminSession;
  onSessionLost(): void;
}

export function TelegramIntegrationPanel({ session, onSessionLost }: Props) {
  const [status, setStatus] = useState<TelegramIntegrationStatus | null>(null);
  const [bot, setBot] = useState<TelegramBotInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  useEffect(() => {
    let active = true;
    apiClient.getTelegramIntegration()
      .then((value) => { if (active) setStatus(value); })
      .catch((caught: unknown) => {
        if (!active) return;
        if (caught instanceof ApiError && caught.status === 401) onSessionLost();
        setError(formatError(caught));
      })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [onSessionLost]);

  async function saveToken(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const token = String(new FormData(form).get('botToken') ?? '').trim();
    if (!token) return;
    setBusy(true); setError(''); setNotice(''); setBot(null);
    try {
      const result = await apiClient.configureTelegramIntegration(token);
      setStatus(result.status);
      setBot(result.bot);
      setNotice('Telegram Bot Token 已验证、加密保存并在当前 API 进程中热生效。');
      form.reset();
    } catch (caught) {
      if (caught instanceof ApiError && caught.status === 401) onSessionLost();
      setError(formatError(caught));
    } finally {
      setBusy(false);
    }
  }

  async function testCurrent() {
    setBusy(true); setError(''); setNotice(''); setBot(null);
    try {
      const result = await apiClient.testTelegramIntegration();
      setStatus(result.status);
      setBot(result.bot);
      setNotice('Telegram Bot API 连通正常，当前 Token 可用。');
    } catch (caught) {
      if (caught instanceof ApiError && caught.status === 401) onSessionLost();
      setError(formatError(caught));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="panel stack">
      <div className="row-between integration-heading">
        <div>
          <p className="eyebrow">Integration</p>
          <h2>Telegram Sticker Relay</h2>
          <p className="muted">用于 Telegram 表情包服务端 Relay。Bot Token 只在服务端使用，不会返回到浏览器。</p>
        </div>
        <span className={`status-pill ${status?.configured ? 'status-ok' : 'status-off'}`}>
          {loading ? '读取中' : status?.configured ? '已配置' : '未配置'}
        </span>
      </div>

      {error ? <p className="error-box" role="alert">{error}</p> : null}
      {notice ? <p className="notice" role="status">{notice}</p> : null}

      <dl className="definition-grid integration-definition">
        <dt>运行状态</dt><dd>{status?.configured ? '已启用' : '未启用'}</dd>
        <dt>配置来源</dt><dd>{sourceLabel(status?.source)}</dd>
        <dt>最近后台修改</dt><dd>{status?.updatedAt ? new Date(status.updatedAt).toLocaleString() : '—'}</dd>
        <dt>最近验证 Bot</dt><dd>{bot ? `${bot.username ? `@${bot.username}` : 'Telegram Bot'} · ID ${bot.id}` : '—'}</dd>
      </dl>

      <div className="action-row">
        <button type="button" onClick={() => void testCurrent()} disabled={busy || !status?.configured}>测试当前配置</button>
      </div>

      {session.admin.role === 'SUPER_ADMIN' ? (
        <form className="recovery-form integration-form" onSubmit={saveToken}>
          <h2>设置 Bot Token</h2>
          <p className="muted">
            保存前会调用 Telegram <code>getMe</code> 校验。校验成功后才会加密写入数据库，并立即替换当前 Relay Token；页面不会回显原 Token。
          </p>
          <label htmlFor="telegram-bot-token">
            Telegram Bot Token
            <input
              id="telegram-bot-token"
              name="botToken"
              type="password"
              autoComplete="new-password"
              minLength={20}
              maxLength={256}
              placeholder="123456789:AA..."
              required
            />
          </label>
          <button type="submit" disabled={busy}>{busy ? '正在验证…' : '验证并保存'}</button>
        </form>
      ) : (
        <p className="warning-box">当前管理员角色只能查看/测试状态。只有 SUPER_ADMIN 可以修改 Telegram Bot Token。</p>
      )}
    </section>
  );
}

function sourceLabel(source?: TelegramIntegrationStatus['source']): string {
  if (source === 'ADMIN_OVERRIDE') return '后台加密配置';
  if (source === 'ENVIRONMENT') return '服务器环境变量 / Secret 文件';
  return '无';
}

function formatError(error: unknown): string {
  if (error instanceof ApiError) return `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}`;
  return error instanceof Error ? error.message : '未知网络错误';
}
