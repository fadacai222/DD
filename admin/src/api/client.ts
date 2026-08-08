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

interface SuccessEnvelope<T> {
  data: T;
  requestId: string;
}

interface ErrorEnvelope {
  error?: {
    code?: string;
    message?: string;
    requestId?: string;
  };
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code: string,
    readonly requestId?: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export class ApiClient {
  constructor(private readonly origin: string) {}

  async getInstance(signal?: AbortSignal): Promise<SuccessEnvelope<InstanceInfo>> {
    return this.request<SuccessEnvelope<InstanceInfo>>('/api/v1/instance', signal);
  }

  private async request<T>(path: string, signal?: AbortSignal): Promise<T> {
    const response = await fetch(new URL(path, this.origin), {
      method: 'GET',
      headers: { Accept: 'application/json' },
      credentials: 'omit',
      signal,
    });

    const requestId = response.headers.get('X-Request-ID') ?? undefined;
    if (!response.ok) {
      let body: ErrorEnvelope = {};
      try {
        body = (await response.json()) as ErrorEnvelope;
      } catch {
        // Do not replace the useful HTTP status with a JSON parsing error.
      }
      throw new ApiError(
        body.error?.message ?? `HTTP ${response.status}`,
        response.status,
        body.error?.code ?? 'HTTP_ERROR',
        body.error?.requestId ?? requestId,
      );
    }
    return (await response.json()) as T;
  }
}

export const apiClient = new ApiClient(
  import.meta.env.VITE_API_ORIGIN?.trim() || 'http://127.0.0.1:18473',
);
