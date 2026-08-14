import { Refine } from '@refinedev/core';
import routerProvider from '@refinedev/react-router';
import { lazy, Suspense, useCallback, useEffect, useState } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { Spin } from 'antd';
import { ApiError, apiClient, type AdminSession } from './api/client';
import { ControlPlaneLayout } from './layout/ControlPlaneLayout';
import { FoundationPage } from './pages/FoundationPage';
import { LoginPage } from './pages/LoginPage';

const DashboardPage = lazy(() => import('./pages/DashboardPage').then((module) => ({ default: module.DashboardPage })));
const UsersPage = lazy(() => import('./pages/UsersPage').then((module) => ({ default: module.UsersPage })));
const GroupsPage = lazy(() => import('./pages/CommunityPages').then((module) => ({ default: module.GroupsPage })));
const MomentsPage = lazy(() => import('./pages/CommunityPages').then((module) => ({ default: module.MomentsPage })));
const ReportsPage = lazy(() => import('./pages/GovernancePages').then((module) => ({ default: module.ReportsPage })));
const AuditPage = lazy(() => import('./pages/GovernancePages').then((module) => ({ default: module.AuditPage })));
const AdminSessionsPage = lazy(() => import('./pages/GovernancePages').then((module) => ({ default: module.AdminSessionsPage })));
const AdminAccountsPage = lazy(() => import('./pages/AdminAccountsPage').then((module) => ({ default: module.AdminAccountsPage })));
const ServiceHealthPage = lazy(() => import('./pages/ServiceHealthPage').then((module) => ({ default: module.ServiceHealthPage })));
const StoragePage = lazy(() => import('./pages/OpsPages').then((module) => ({ default: module.StoragePage })));
const PushPage = lazy(() => import('./pages/OpsPages').then((module) => ({ default: module.PushPage })));
const RTCPage = lazy(() => import('./pages/OpsPages').then((module) => ({ default: module.RTCPage })));
const TelegramIntegrationPanel = lazy(() => import('./pages/TelegramIntegrationPanel').then((module) => ({ default: module.TelegramIntegrationPanel })));
const SettingsPage = lazy(() => import('./pages/SettingsPage').then((module) => ({ default: module.SettingsPage })));

const resources = [
  { name: 'dashboard', list: '/', meta: { label: '运营总览' } },
  { name: 'users', list: '/users', show: '/users/:id', meta: { label: '用户管理' } },
  { name: 'groups', list: '/groups', meta: { label: '群组管理' } },
  { name: 'moments', list: '/moments', meta: { label: '朋友圈' } },
  { name: 'reports', list: '/reports', meta: { label: '举报治理' } },
  { name: 'storage', list: '/storage', meta: { label: '媒体与存储' } },
  { name: 'push', list: '/push', meta: { label: 'Push 运营' } },
  { name: 'rtc', list: '/rtc', meta: { label: 'LiveKit / RTC' } },
  { name: 'services', list: '/services', meta: { label: '服务健康' } },
  { name: 'audit', list: '/audit', meta: { label: '安全审计' } },
  { name: 'admins', list: '/admins', meta: { label: '管理员账号' } },
  { name: 'sessions', list: '/sessions', meta: { label: '管理员会话' } },
  { name: 'integrations', list: '/integrations', meta: { label: '集成服务' } },
  { name: 'settings', list: '/settings', meta: { label: '系统设置' } },
];

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
    <Refine routerProvider={routerProvider} resources={resources} options={{ syncWithLocation: true }}>
      <Suspense fallback={<div className="route-loading"><Spin size="large" /></div>}>
      <Routes>
        <Route path="/login" element={session ? <Navigate to="/" replace /> : <LoginPage onAuthenticated={setSession} />} />
        <Route path="/foundation" element={<FoundationPage />} />
        <Route path="/" element={session ? <ControlPlaneLayout session={session} onSessionLost={clearSession} /> : <Navigate to="/login" replace />}>
          <Route index element={<DashboardPage />} />
          <Route path="users" element={<UsersPage session={session!} onSessionLost={clearSession} />} />
          <Route path="groups" element={<GroupsPage />} />
          <Route path="moments" element={<MomentsPage />} />
          <Route path="reports" element={<ReportsPage session={session!} onSessionLost={clearSession} />} />
          <Route path="storage" element={<StoragePage />} />
          <Route path="push" element={<PushPage />} />
          <Route path="rtc" element={<RTCPage />} />
          <Route path="services" element={<ServiceHealthPage />} />
          <Route path="audit" element={<AuditPage session={session!} onSessionLost={clearSession} />} />
          <Route path="admins" element={<AdminAccountsPage session={session!} onSessionLost={clearSession} />} />
          <Route path="sessions" element={<AdminSessionsPage session={session!} onSessionLost={clearSession} />} />
          <Route path="integrations" element={<TelegramIntegrationPanel session={session!} onSessionLost={clearSession} />} />
          <Route path="settings" element={<SettingsPage session={session!} onSessionLost={clearSession} />} />
        </Route>
        <Route path="*" element={<Navigate to={session ? '/' : '/login'} replace />} />
      </Routes>
      </Suspense>
    </Refine>
  );
}
