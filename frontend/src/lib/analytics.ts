const CONSENT_KEY = 'asoc_consent';

export type Consent = 'essential' | 'analytics';

const TRACKED_PATHS = new Set([
  '/',
  '/loads',
  '/books',
  '/drive',
  '/post-load',
  '/vvip',
  '/privacy',
  '/terms'
]);

export function getConsent(): Consent | null {
  try {
    const value = localStorage.getItem(CONSENT_KEY);
    return value === 'essential' || value === 'analytics' ? value : null;
  } catch {
    return null;
  }
}

export function setConsent(value: Consent) {
  localStorage.setItem(CONSENT_KEY, value);
}

/** Page path only, and only after the visitor allows analytics. */
export function trackPage(path: string) {
  if (getConsent() !== 'analytics') return;
  if (!TRACKED_PATHS.has(path)) return;
  const body = JSON.stringify({ path });
  fetch('/api/analytics/page', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
    keepalive: true
  }).catch(() => {});
}
