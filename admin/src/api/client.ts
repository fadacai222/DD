export interface InstanceInfo {
  name: string;
  apiVersion: string;
  apiBaseUrl: string;
  realtimeUrl: string;
  liveKitUrl: string;
  features: {
    calls: boolean;
    registrationMode: 'open' | 'invite' | 'approval' | 'closed';
  };
}

export type AdminRole = 'SUPER_ADMIN' | 'MODERATOR' | 'SUPPORT_READ_ONLY';
export type ReportStatus = 'PENDING' | 'IN_REVIEW' | 'RESOLVED' | 'DISMISSED';

export interface AdminIdentity { id: string; email: string; role: AdminRole; }
export interface AdminSession {
  admin: AdminIdentity;
  sessionId: string;
  expiresAt: string;
  idleExpiresAt: string;
  csrfToken: string;
}
export interface AdminLoginResult {
  challengeToken: string;
  challengeExpiresAt: string;
  mfaRequired: boolean;
  enrollmentRequired: boolean;
}
export interface MFAEnrollment { secret: string; otpauthUri: string; }
export interface AdminSessionItem {
  id: string;
  createdAt: string;
  lastSeenAt: string;
  idleExpiresAt: string;
  expiresAt: string;
  revokedAt?: string;
  clientIp?: string;
  userAgent: string;
  current: boolean;
}
export interface ReportItem {
  id: string;
  reporterUserId: string;
  reporterHandle?: string;
  targetUserId: string;
  targetHandle?: string;
  category: string;
  reason: string;
  status: ReportStatus;
  assignedAdminId?: string;
  resolutionReason?: string;
  createdAt: string;
  updatedAt: string;
  resolvedAt?: string;
}
export interface UserItem {
  id: string;
  email: string;
  handle: string;
  displayName: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}
export interface AuditItem {
  id: string;
  actorAdminId?: string;
  sessionId?: string;
  actorRole?: AdminRole;
  action: string;
  targetType?: string;
  targetId?: string;
  reason?: string;
  detail: Record<string, unknown>;
  clientIp?: string;
  userAgent: string;
  createdAt: string;
}

interface SuccessEnvelope<T> { data: T; requestId: string; }
interface ErrorEnvelope { error?: { code?: string; message?: string; requestId?: string; }; }

export class ApiError extends Error {
  constructor(message: string, readonly status: number, readonly code: string, readonly requestId?: string) {
    super(message);
    this.name = 'ApiError';
  }
}

export class ApiClient {
  private csrfToken = '';

  constructor(private readonly origin: string) {}

  async getInstance(signal?: AbortSignal): Promise<SuccessEnvelope<InstanceInfo>> {
    return this.request<SuccessEnvelope<InstanceInfo>>('/api/v1/instance', { signal, credentials: 'omit' });
  }

  async adminLogin(email: string, password: string): Promise<AdminLoginResult> {
    const response = await this.request<SuccessEnvelope<AdminLoginResult>>('/api/v1/admin/auth/login', { method: 'POST', body: { email, password } });
    return response.data;
  }

  async beginMFAEnrollment(challengeToken: string): Promise<MFAEnrollment> {
    const response = await this.request<SuccessEnvelope<MFAEnrollment>>('/api/v1/admin/auth/mfa/enroll', { method: 'POST', body: { challengeToken } });
    return response.data;
  }

  async verifyMFAEnrollment(challengeToken: string, code: string): Promise<{ session: AdminSession; recoveryCodes: string[] }> {
    const response = await this.request<SuccessEnvelope<{ session: AdminSession; recoveryCodes: string[] }>>('/api/v1/admin/auth/mfa/enroll/verify', { method: 'POST', body: { challengeToken, code } });
    this.csrfToken = response.data.session.csrfToken;
    return response.data;
  }

  async verifyMFA(challengeToken: string, code: string, recoveryCode: string): Promise<AdminSession> {
    const response = await this.request<SuccessEnvelope<AdminSession>>('/api/v1/admin/auth/mfa/verify', { method: 'POST', body: { challengeToken, code, recoveryCode } });
    this.csrfToken = response.data.csrfToken;
    return response.data;
  }

  async getAdminSession(signal?: AbortSignal): Promise<AdminSession> {
    const response = await this.request<SuccessEnvelope<AdminSession>>('/api/v1/admin/session', { signal });
    this.csrfToken = response.data.csrfToken;
    return response.data;
  }

  async logoutAdmin(): Promise<void> {
    await this.request<SuccessEnvelope<{ revoked: boolean }>>('/api/v1/admin/auth/logout', { method: 'POST', csrf: true });
    this.csrfToken = '';
  }

  async listAdminSessions(): Promise<AdminSessionItem[]> {
    const response = await this.request<SuccessEnvelope<{ items: AdminSessionItem[] }>>('/api/v1/admin/sessions');
    return response.data.items;
  }

  async revokeAdminSession(sessionId: string): Promise<void> {
    await this.request<SuccessEnvelope<{ revoked: boolean }>>(`/api/v1/admin/sessions/${encodeURIComponent(sessionId)}`, { method: 'DELETE', csrf: true });
  }

  async regenerateRecoveryCodes(code: string): Promise<string[]> {
    const response = await this.request<SuccessEnvelope<{ recoveryCodes: string[] }>>('/api/v1/admin/mfa/recovery/regenerate', { method: 'POST', body: { code }, csrf: true });
    return response.data.recoveryCodes;
  }

  async listReports(status = ''): Promise<ReportItem[]> {
    const query = status ? `?status=${encodeURIComponent(status)}` : '';
    const response = await this.request<SuccessEnvelope<{ items: ReportItem[] }>>(`/api/v1/admin/reports${query}`);
    return response.data.items;
  }

  async updateReport(reportId: string, status: ReportStatus, reason: string): Promise<ReportItem> {
    const response = await this.request<SuccessEnvelope<ReportItem>>(`/api/v1/admin/reports/${encodeURIComponent(reportId)}`, { method: 'PATCH', body: { status, reason }, csrf: true });
    return response.data;
  }

  async listUsers(query = '', status = ''): Promise<UserItem[]> {
    const params = new URLSearchParams();
    if (query.trim()) params.set('q', query.trim());
    if (status) params.set('status', status);
    const suffix = params.size ? `?${params.toString()}` : '';
    const response = await this.request<SuccessEnvelope<{ items: UserItem[] }>>(`/api/v1/admin/users${suffix}`);
    return response.data.items;
  }

  async moderateUser(userId: string, action: 'suspend' | 'unsuspend', reason: string): Promise<UserItem> {
    const response = await this.request<SuccessEnvelope<{ user: UserItem }>>(`/api/v1/admin/users/${encodeURIComponent(userId)}/${action}`, { method: 'POST', body: { reason }, csrf: true });
    return response.data.user;
  }

  async listAudit(): Promise<AuditItem[]> {
    const response = await this.request<SuccessEnvelope<{ items: AuditItem[] }>>('/api/v1/admin/audit');
    return response.data.items;
  }

  private async request<T>(path: string, options: { method?: string; body?: unknown; signal?: AbortSignal; csrf?: boolean; credentials?: RequestCredentials } = {}): Promise<T> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (options.body !== undefined) headers['Content-Type'] = 'application/json';
    if (options.csrf) {
      if (!this.csrfToken) throw new ApiError('管理员会话缺少 CSRF 状态，请刷新后重试', 403, 'ADMIN_CSRF_MISSING');
      headers['X-DD-Admin-CSRF'] = this.csrfToken;
    }
    const response = await fetch(new URL(path, this.origin), {
      method: options.method ?? 'GET',
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      credentials: options.credentials ?? 'include',
      signal: options.signal,
    });
    const requestId = response.headers.get('X-Request-ID') ?? undefined;
    if (!response.ok) {
      let body: ErrorEnvelope = {};
      try { body = (await response.json()) as ErrorEnvelope; } catch { /* preserve HTTP status */ }
      throw new ApiError(body.error?.message ?? `HTTP ${response.status}`, response.status, body.error?.code ?? 'HTTP_ERROR', body.error?.requestId ?? requestId);
    }
    return (await response.json()) as T;
  }
}

export const apiClient = new ApiClient(import.meta.env.VITE_API_ORIGIN?.trim() || 'http://127.0.0.1:18473');
