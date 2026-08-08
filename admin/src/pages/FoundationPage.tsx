import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ApiError, apiClient, type InstanceInfo } from '../api/client';

function registrationModeLabel(mode: InstanceInfo['features']['registrationMode']): string {
  switch (mode) {
    case 'open': return '开放注册';
    case 'invite': return '邀请码注册';
    case 'approval': return '审批注册';
    case 'closed': return '关闭注册';
  }
}

interface State {
  loading: boolean;
  instance: InstanceInfo | null;
  requestId: string | null;
  error: string | null;
}

export function FoundationPage() {
  const [state, setState] = useState<State>({
    loading: true,
    instance: null,
    requestId: null,
    error: null,
  });

  useEffect(() => {
    const controller = new AbortController();
    apiClient
      .getInstance(controller.signal)
      .then((response) => {
        setState({
          loading: false,
          instance: response.data,
          requestId: response.requestId,
          error: null,
        });
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        if (error instanceof ApiError) {
          setState({
            loading: false,
            instance: null,
            requestId: error.requestId ?? null,
            error: `${error.code}: ${error.message}`,
          });
          return;
        }
        setState({
          loading: false,
          instance: null,
          requestId: null,
          error: error instanceof Error ? error.message : '未知网络错误',
        });
      });
    return () => controller.abort();
  }, []);

  return (
    <main className="page-shell">
      <header className="topbar">
        <div>
          <p className="eyebrow">P1 engineering foundation</p>
          <h1>实例连接状态</h1>
        </div>
        <Link className="text-link" to="/login">返回登录</Link>
      </header>

      <section className="panel">
        {state.loading ? <p>正在读取 <code>/api/v1/instance</code>…</p> : null}
        {state.error ? (
          <div className="error-box">
            <strong>实例发现失败</strong>
            <p>{state.error}</p>
            {state.requestId ? <code>requestId: {state.requestId}</code> : null}
          </div>
        ) : null}
        {state.instance ? (
          <dl className="definition-grid">
            <dt>实例</dt><dd>{state.instance.name}</dd>
            <dt>API</dt><dd><code>{state.instance.apiBaseUrl}</code></dd>
            <dt>Realtime</dt><dd><code>{state.instance.realtimeUrl}</code></dd>
            <dt>LiveKit</dt><dd><code>{state.instance.liveKitUrl}</code></dd>
            <dt>通话</dt><dd>{state.instance.features.calls ? '启用' : '关闭'}</dd>
            <dt>注册策略</dt><dd>{registrationModeLabel(state.instance.features.registrationMode)}</dd>
            <dt>Request ID</dt><dd><code>{state.requestId}</code></dd>
          </dl>
        ) : null}
      </section>
    </main>
  );
}
