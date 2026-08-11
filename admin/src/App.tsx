import { useCallback, useEffect, useState } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { ApiError, apiClient, type AdminSession } from './api/client';
import { FoundationPage } from './pages/FoundationPage';
import { GovernancePage } from './pages/GovernancePage';
import { LoginPage } from './pages/LoginPage';

export function App() {
  const [session, setSession] = useState<AdminSession | null>(null);
  const [restoring, setRestoring] = useState(true);

  useEffect(() => {
    const controller = new AbortController();
    apiClient.getAdminSession(controller.signal)
      .then(setSession)
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        if (!(error instanceof ApiError && error.status === 401)) console.error('admin session restore failed', error);
        setSession(null);
      })
      .finally(() => { if (!controller.signal.aborted) setRestoring(false); });
    return () => controller.abort();
  }, []);

  const clearSession = useCallback(() => setSession(null), []);

  if (restoring) {
    return <main className="auth-shell"><section className="auth-card"><div className="brand-mark">DD</div><p className="muted">正在恢复管理员会话…</p></section></main>;
  }

  return (
    <Routes>
      <Route path="/login" element={session ? <Navigate to="/" replace /> : <LoginPage onAuthenticated={setSession} />} />
      <Route path="/foundation" element={<FoundationPage />} />
      <Route path="/" element={session ? <GovernancePage session={session} onSessionLost={clearSession} /> : <Navigate to="/login" replace />} />
      <Route path="*" element={<Navigate to={session ? '/' : '/login'} replace />} />
    </Routes>
  );
}
