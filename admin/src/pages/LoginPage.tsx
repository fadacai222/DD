import { FormEvent, useState } from 'react';
import { Link } from 'react-router-dom';

export function LoginPage() {
  const [notice, setNotice] = useState('');

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setNotice('登录 API 将在 P2 接入；当前页面只验证后台工程壳、路由和主题。');
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="brand-mark" aria-hidden="true">DD</div>
        <p className="eyebrow">Self-hosted administration</p>
        <h1>DD 管理后台</h1>
        <p className="muted">正式认证尚未接入。这个入口不会把演示密码发送到任何服务端。</p>

        <form onSubmit={submit} className="stack">
          <label>
            管理员邮箱
            <input name="email" type="email" autoComplete="username" placeholder="admin@example.com" required />
          </label>
          <label>
            密码
            <input name="password" type="password" autoComplete="current-password" placeholder="••••••••" required />
          </label>
          <button type="submit">登录（P2 接入）</button>
        </form>

        {notice ? <p className="notice" role="status">{notice}</p> : null}
        <Link className="text-link" to="/foundation">查看工程基础状态 →</Link>
      </section>
    </main>
  );
}
