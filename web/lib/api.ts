const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3001/v1';

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function fetchApi(endpoint: string, options: RequestInit = {}) {
  const url = `${API_URL}${endpoint}`;
  const response = await fetch(url, {
    ...options,
    credentials: 'include', // Send cookies
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ error: 'Unknown error' }));
    const errorMessage = error.error || error.message || 'Request failed';
    console.error('API Error:', { endpoint, status: response.status, error: errorMessage, fullError: error });
    throw new ApiError(response.status, errorMessage);
  }

  return response.json();
}

export const api = {
  auth: {
    register: (email: string, password: string, productName: string) =>
      fetchApi('/auth/register', {
        method: 'POST',
        body: JSON.stringify({ email, password, productName }),
      }),
    login: (email: string, password: string) =>
      fetchApi('/auth/login', {
        method: 'POST',
        body: JSON.stringify({ email, password }),
      }),
    logout: () => fetchApi('/auth/logout', { method: 'POST' }),
    me: () => fetchApi('/auth/me'),
  },
  briefs: {
    enrich: (id: string) => fetchApi(`/briefs/${id}/enrich`, { method: 'POST' }),
  },
  content: {
    list: (status?: string) => fetchApi(`/content-items${status ? `?status=${status}` : ''}`),
    get: (id: string) => fetchApi(`/content-items/${id}`),
    approve: (id: string) => fetchApi(`/content-items/${id}/approve`, { method: 'POST' }),
    reject: (id: string) => fetchApi(`/content-items/${id}/reject`, { method: 'POST' }),
    updateVariant: (id: string, variantId: string, content: string) =>
      fetchApi(`/content-items/${id}/variants/${variantId}`, {
        method: 'PATCH',
        body: JSON.stringify({ content }),
      }),
  },
  calendar: {
    get: () => fetchApi('/calendar'),
    generateDrafts: (calendarDate: string, briefId?: string) =>
      fetchApi('/calendar/generate-drafts', {
        method: 'POST',
        body: JSON.stringify({ calendar_date: calendarDate, brief_id: briefId }),
      }),
  },
  analytics: {
    scoreboard: () => fetchApi('/analytics/scoreboard'),
    generateToken: () => fetchApi('/analytics/token', { method: 'POST' }),
    rotateToken: () => fetchApi('/analytics/token/rotate', { method: 'POST' }),
  },
  settings: {
    get: () => fetchApi('/settings'),
    update: (updates: Record<string, any>) =>
      fetchApi('/settings', {
        method: 'PATCH',
        body: JSON.stringify(updates),
      }),
  },
};

