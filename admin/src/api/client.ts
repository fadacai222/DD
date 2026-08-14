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
export interface UserPushEndpoint {
  provider: string;
  environment: string;
  status: string;
  failureCount: number;
  lastSuccessAt?: string;
  lastFailureAt?: string;
  lastFailureCode?: string;
}
export interface UserDeviceDetail {
  id: string;
  name: string;
  platform: string;
  appVersion: string;
  isVerified: boolean;
  createdAt: string;
  lastSeenAt: string;
  revokedAt?: string;
  push: UserPushEndpoint[];
}
export interface UserDetail extends UserItem {
  bio: string;
  avatarMediaId?: string;
  emailVerifiedAt: string;
  deletedAt?: string;
  counts: { contacts: number; groups: number; messages: number; moments: number; activeSessions: number };
  devices: UserDeviceDetail[];
}
export interface DashboardSummary {
  totalUsers: number;
  todayRegistrations: number;
  onlineUsers: number;
  activeDevices24h: number;
  totalMessages: number;
  todayMessages: number;
  totalGroups: number;
  totalMoments: number;
  todayMoments: number;
  totalCalls: number;
  todayCalls: number;
  activeCalls: number;
  mediaObjects: number;
  mediaBytes: number;
  pendingPushJobs: number;
  pendingVoiceTranscriptions: number;
  pendingOutboxEvents: number;
}
export interface DashboardSnapshot {
  generatedAt: string;
  presenceDefinition: string;
  summary: DashboardSummary;
  trend: Array<{ date: string; registrations: number; messages: number; calls: number; moments: number }>;
}
export interface GroupItem {
  conversationId: string;
  name: string;
  announcement: string;
  joinMode: string;
  status: string;
  createdByUserId: string;
  createdByHandle: string;
  memberCount: number;
  createdAt: string;
  updatedAt: string;
  dissolvedAt?: string;
}
export interface MomentItem {
  id: string;
  authorUserId: string;
  authorHandle: string;
  authorDisplayName: string;
  text: string;
  visibility: string;
  status: string;
  mediaCount: number;
  likeCount: number;
  commentCount: number;
  createdAt: string;
  deletedAt?: string;
}
export interface ServiceHealthItem {
  name: string;
  status: 'UP' | 'DOWN' | 'CONFIGURED' | 'NOT_CONFIGURED' | 'UNKNOWN';
  detail?: string;
  checkedAt?: string;
}
export interface StorageSnapshot {
  generatedAt: string;
  readyObjects: number;
  readyBytes: number;
  uploadingObjects: number;
  failedObjects: number;
  quarantinedObjects: number;
  deletedObjects: number;
  expiredIncompleteUploads: number;
  byPurpose: Array<{ purpose: string; objectCount: number; bytes: number }>;
}
export interface PushSnapshot {
  generatedAt: string;
  pendingJobs: number;
  retryingJobs: number;
  sentJobs24h: number;
  droppedJobs24h: number;
  endpointFailures24h: number;
  oldestPendingAt?: string;
  endpoints: Array<{ provider: string; status: string; count: number }>;
}
export interface RTCSnapshot {
  generatedAt: string;
  directCallsToday: number;
  activeDirectCalls: number;
  acceptedDirectCalls24h: number;
  averageDirectSeconds24h: number;
  groupCallsToday: number;
  activeGroupCalls: number;
  activeGroupParticipants: number;
}
export interface SystemSettings {
  registrationMode: 'open' | 'invite' | 'approval' | 'closed';
  persistedRegistrationMode?: string;
  registrationOpenAvailable: boolean;
  source: 'ENVIRONMENT' | 'ADMIN_OVERRIDE';
  updatedAt?: string;
}
export interface AdminAccountItem {
  id: string;
  email: string;
  role: AdminRole;
  status: 'ACTIVE' | 'DISABLED';
  mfaEnabled: boolean;
  createdAt: string;
  updatedAt: string;
  lastLoginAt?: string;
  activeSessions: number;
}
export type TelegramIntegrationSource = 'NONE' | 'ENVIRONMENT' | 'ADMIN_OVERRIDE';
export interface TelegramIntegrationStatus {
  configured: boolean;
  source: TelegramIntegrationSource;
  updatedAt?: string;
}
export interface TelegramBotInfo { id: number; username?: string; }

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

  async getDashboard(): Promise<DashboardSnapshot> {
    const response = await this.request<SuccessEnvelope<DashboardSnapshot>>('/api/v1/admin/dashboard');
    return response.data;
  }

  async getUser(userId: string): Promise<UserDetail> {
    const response = await this.request<SuccessEnvelope<UserDetail>>(`/api/v1/admin/users/${encodeURIComponent(userId)}`);
    return response.data;
  }

  async listGroups(query = '', status = ''): Promise<GroupItem[]> {
    const params = new URLSearchParams();
    if (query.trim()) params.set('q', query.trim());
    if (status) params.set('status', status);
    const suffix = params.size ? `?${params.toString()}` : '';
    const response = await this.request<SuccessEnvelope<{ items: GroupItem[] }>>(`/api/v1/admin/groups${suffix}`);
    return response.data.items;
  }

  async listMoments(query = '', status = ''): Promise<MomentItem[]> {
    const params = new URLSearchParams();
    if (query.trim()) params.set('q', query.trim());
    if (status) params.set('status', status);
    const suffix = params.size ? `?${params.toString()}` : '';
    const response = await this.request<SuccessEnvelope<{ items: MomentItem[] }>>(`/api/v1/admin/moments${suffix}`);
    return response.data.items;
  }

  async getStorageSnapshot(): Promise<StorageSnapshot> {
    const response = await this.request<SuccessEnvelope<StorageSnapshot>>('/api/v1/admin/storage');
    return response.data;
  }

  async getPushSnapshot(): Promise<PushSnapshot> {
    const response = await this.request<SuccessEnvelope<PushSnapshot>>('/api/v1/admin/push');
    return response.data;
  }

  async getRTCSnapshot(): Promise<RTCSnapshot> {
    const response = await this.request<SuccessEnvelope<RTCSnapshot>>('/api/v1/admin/rtc');
    return response.data;
  }

  async getSystemSettings(): Promise<SystemSettings> {
    const response = await this.request<SuccessEnvelope<SystemSettings>>('/api/v1/admin/settings');
    return response.data;
  }

  async setRegistrationMode(mode: 'open' | 'closed', reason: string): Promise<SystemSettings> {
    const response = await this.request<SuccessEnvelope<SystemSettings>>('/api/v1/admin/settings/registration', { method: 'PUT', body: { mode, reason }, csrf: true });
    return response.data;
  }

  async listAdminAccounts(): Promise<AdminAccountItem[]> {
    const response = await this.request<SuccessEnvelope<{ items: AdminAccountItem[] }>>('/api/v1/admin/admins');
    return response.data.items;
  }

  async createAdminAccount(email: string, password: string, role: AdminRole): Promise<AdminAccountItem> {
    const response = await this.request<SuccessEnvelope<AdminAccountItem>>('/api/v1/admin/admins', { method: 'POST', body: { email, password, role }, csrf: true });
    return response.data;
  }

  async updateAdminAccount(id: string, role: AdminRole, status: 'ACTIVE' | 'DISABLED', reason: string): Promise<AdminAccountItem> {
    const response = await this.request<SuccessEnvelope<AdminAccountItem>>(`/api/v1/admin/admins/${encodeURIComponent(id)}`, { method: 'PATCH', body: { role, status, reason }, csrf: true });
    return response.data;
  }

  async resetAdminMFA(id: string, reason: string): Promise<void> {
    await this.request<SuccessEnvelope<{ reset: boolean }>>(`/api/v1/admin/admins/${encodeURIComponent(id)}/mfa-reset`, { method: 'POST', body: { reason }, csrf: true });
  }

  async getServiceHealth(): Promise<{ items: ServiceHealthItem[]; generatedAt: string }> {
    const response = await this.request<SuccessEnvelope<{ items: ServiceHealthItem[]; generatedAt: string }>>('/api/v1/admin/services/health');
    return response.data;
  }

  async moderateUser(userId: string, action: 'suspend' | 'unsuspend', reason: string): Promise<UserItem> {
    const response = await this.request<SuccessEnvelope<{ user: UserItem }>>(`/api/v1/admin/users/${encodeURIComponent(userId)}/${action}`, { method: 'POST', body: { reason }, csrf: true });
    return response.data.user;
  }

  async listAudit(filters: { action?: string; targetType?: string; actorAdminId?: string } = {}): Promise<AuditItem[]> {
    const params = new URLSearchParams();
    if (filters.action?.trim()) params.set('action', filters.action.trim());
    if (filters.targetType?.trim()) params.set('targetType', filters.targetType.trim());
    if (filters.actorAdminId?.trim()) params.set('actorAdminId', filters.actorAdminId.trim());
    const suffix = params.size ? `?${params.toString()}` : '';
    const response = await this.request<SuccessEnvelope<{ items: AuditItem[] }>>(`/api/v1/admin/audit${suffix}`);
    return response.data.items;
  }

  async getTelegramIntegration(): Promise<TelegramIntegrationStatus> {
    const response = await this.request<SuccessEnvelope<TelegramIntegrationStatus>>('/api/v1/admin/integrations/telegram-sticker');
    return response.data;
  }

  async configureTelegramIntegration(botToken: string): Promise<{ status: TelegramIntegrationStatus; bot: TelegramBotInfo }> {
    const response = await this.request<SuccessEnvelope<{ status: TelegramIntegrationStatus; bot: TelegramBotInfo }>>('/api/v1/admin/integrations/telegram-sticker', {
      method: 'PUT',
      body: { botToken },
      csrf: true,
    });
    return response.data;
  }

  async testTelegramIntegration(): Promise<{ ok: boolean; status: TelegramIntegrationStatus; bot: TelegramBotInfo }> {
    const response = await this.request<SuccessEnvelope<{ ok: boolean; status: TelegramIntegrationStatus; bot: TelegramBotInfo }>>('/api/v1/admin/integrations/telegram-sticker/test', {
      method: 'POST',
      csrf: true,
    });
    return response.data;
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

const defaultApiOrigin = typeof window === 'undefined' ? 'http://127.0.0.1:18473' : window.location.origin;
export const apiClient = new ApiClient(import.meta.env.VITE_API_ORIGIN?.trim() || defaultApiOrigin);
