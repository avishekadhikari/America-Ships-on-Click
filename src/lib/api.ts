import {
  PlatformConfig,
  Load,
  Booking,
  PublicLedgerItem,
  SettlementTotals,
  DriverOnboardInput,
  User
} from '../types/api';

const API_BASE = (import.meta as any).env?.VITE_API_BASE_URL || '/api';

function getAuthHeaders(): Record<string, string> {
  const token = localStorage.getItem('americaships_jwt');
  if (token) {
    return { Authorization: `Bearer ${token}` };
  }
  return {};
}

async function handleResponse<T>(res: Response): Promise<T> {
  if (!res.ok) {
    let errorMsg = `API Error ${res.status}`;
    try {
      const data = await res.json();
      if (data.error) errorMsg = data.error;
    } catch {
      // ignore JSON parse error
    }
    throw new Error(errorMsg);
  }
  return res.json();
}

export const api = {
  // Config
  async getConfig(): Promise<PlatformConfig> {
    const res = await fetch(`${API_BASE}/config`);
    return handleResponse<PlatformConfig>(res);
  },

  // Auth
  async login(email: string, password: string): Promise<{ token: string; user: User }> {
    const res = await fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password })
    });
    const data = await handleResponse<{ token: string; user: User }>(res);
    localStorage.setItem('americaships_jwt', data.token);
    return data;
  },

  async signup(data: any): Promise<{ token: string; user: User }> {
    const res = await fetch(`${API_BASE}/auth/signup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    const result = await handleResponse<{ token: string; user: User }>(res);
    localStorage.setItem('americaships_jwt', result.token);
    return result;
  },

  async getMe(): Promise<{ user: User; profile: any }> {
    const res = await fetch(`${API_BASE}/auth/me`, {
      headers: getAuthHeaders()
    });
    return handleResponse<{ user: User; profile: any }>(res);
  },

  logout() {
    localStorage.removeItem('americaships_jwt');
  },

  // Loads
  async getLoads(filters?: { origin?: string; destination?: string; equipment?: string; minRate?: number; status?: string }): Promise<Load[]> {
    const params = new URLSearchParams();
    if (filters?.origin) params.set('origin', filters.origin);
    if (filters?.destination) params.set('destination', filters.destination);
    if (filters?.equipment) params.set('equipment', filters.equipment);
    if (filters?.minRate) params.set('minRate', filters.minRate.toString());
    if (filters?.status) params.set('status', filters.status);

    const res = await fetch(`${API_BASE}/loads?${params.toString()}`);
    const data = await handleResponse<{ loads: Load[] }>(res);
    return data.loads;
  },

  async getLoad(id: string): Promise<Load> {
    const res = await fetch(`${API_BASE}/loads/${id}`);
    return handleResponse<Load>(res);
  },

  async createLoad(loadData: Partial<Load>): Promise<Load> {
    const res = await fetch(`${API_BASE}/loads`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
      body: JSON.stringify(loadData)
    });
    return handleResponse<Load>(res);
  },

  // Bookings
  async bookLoad(load_id: string): Promise<Booking> {
    const res = await fetch(`${API_BASE}/bookings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
      body: JSON.stringify({ load_id })
    });
    return handleResponse<Booking>(res);
  },

  async uploadPod(booking_id: string, pod_url: string): Promise<Booking> {
    const res = await fetch(`${API_BASE}/bookings/${booking_id}/pod`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() },
      body: JSON.stringify({ pod_url })
    });
    return handleResponse<Booking>(res);
  },

  async completeBooking(booking_id: string): Promise<{ message: string; settlement: PublicLedgerItem }> {
    const res = await fetch(`${API_BASE}/bookings/${booking_id}/complete`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', ...getAuthHeaders() }
    });
    return handleResponse<{ message: string; settlement: PublicLedgerItem }>(res);
  },

  // Settlements
  async getSettlements(limit = 50, page = 1): Promise<PublicLedgerItem[]> {
    const res = await fetch(`${API_BASE}/settlements?limit=${limit}&page=${page}`);
    const data = await handleResponse<{ settlements: PublicLedgerItem[] }>(res);
    return data.settlements;
  },

  async getSettlementTotals(): Promise<SettlementTotals> {
    const res = await fetch(`${API_BASE}/settlements/aggregate`);
    return handleResponse<SettlementTotals>(res);
  },

  // Driver Onboarding
  async onboardDriver(data: DriverOnboardInput): Promise<{ message: string; token: string; driverId: string }> {
    const res = await fetch(`${API_BASE}/drivers/onboard`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    const result = await handleResponse<{ message: string; token: string; driverId: string }>(res);
    if (result.token) localStorage.setItem('americaships_jwt', result.token);
    return result;
  },

  // Upload file
  async uploadFile(file: File): Promise<{ file_url: string; filename: string }> {
    const formData = new FormData();
    formData.append('file', file);

    const res = await fetch(`${API_BASE}/uploads/file`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: formData
    });
    return handleResponse<{ file_url: string; filename: string }>(res);
  },

  // Admin
  async getAdminLedger(): Promise<any[]> {
    const res = await fetch(`${API_BASE}/admin/ledger`, {
      headers: getAuthHeaders()
    });
    const data = await handleResponse<{ ledger: any[] }>(res);
    return data.ledger;
  },

  getAdminExportUrl(): string {
    return `${API_BASE}/admin/export`;
  }
};
