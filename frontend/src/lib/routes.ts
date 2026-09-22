import type { MouseEvent } from 'react';

/** Public, linkable paths. Keep frontend/public/sitemap.xml in step with the indexed ones. */
export const TAB_PATHS: Record<string, string> = {
  home: '/',
  loads: '/loads',
  books: '/books',
  driver: '/drive',
  shipper: '/post-load',
  dashboard: '/dashboard',
  admin: '/admin',
  vvip: '/vvip',
  privacy: '/privacy',
  terms: '/terms'
};

const PATH_TABS: Record<string, string> = Object.fromEntries(
  Object.entries(TAB_PATHS).map(([tab, path]) => [path, tab])
);

/** Unknown paths stay unknown so the address bar can show a real 404. */
export function tabForPath(pathname: string): string {
  const normalized = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname;
  return PATH_TABS[normalized] ?? 'notfound';
}

export function pathFor(tab: string): string {
  return TAB_PATHS[tab] ?? '/';
}

/** In-app navigation for real links. Modified clicks still open a new tab. */
export function followTabLink(event: MouseEvent<HTMLAnchorElement>, go: (tab: string) => void, tab: string) {
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
  event.preventDefault();
  go(tab);
}

export const SITE_NAME = 'America Ships On Click';

export const PAGE_META: Record<string, { title: string; description: string; path: string; robots: string }> = {
  home: {
    title: 'America Ships On Click — Freight Load Board & Open Books Ledger',
    description: 'No-broker freight load board with a public settlement ledger. Shippers post loads, carriers book direct, and the fee is on the books.',
    path: '/',
    robots: 'index,follow'
  },
  loads: {
    title: 'Find Loads — America Ships On Click',
    description: 'Open freight on the America Ships On Click board. Filter by lane and equipment, then book direct with the shipper.',
    path: '/loads',
    robots: 'index,follow'
  },
  books: {
    title: 'Open Books Ledger — America Ships On Click',
    description: 'Public settlement ledger. Every settled load shows miles, rate, the platform fee, and what the carrier was paid.',
    path: '/books',
    robots: 'index,follow'
  },
  driver: {
    title: 'Drive With Us — America Ships On Click',
    description: 'Carrier onboarding. Submit your CDL, operating authority, and insurance, then book loads on the open board.',
    path: '/drive',
    robots: 'index,follow'
  },
  shipper: {
    title: 'Post a Load — America Ships On Click',
    description: 'Post a load with a live lane quote. The platform fee is shown before the load goes on the board.',
    path: '/post-load',
    robots: 'index,follow'
  },
  dashboard: {
    title: 'Dashboard — America Ships On Click',
    description: 'Your loads, bookings, and settlements on America Ships On Click.',
    path: '/dashboard',
    robots: 'noindex,nofollow'
  },
  admin: {
    title: 'Admin — America Ships On Click',
    description: 'Operator console for America Ships On Click.',
    path: '/admin',
    robots: 'noindex,nofollow'
  },
  vvip: {
    title: 'Golden VVIP — America Ships On Click',
    description: 'Join the Golden VVIP interest list before the public window. No account is created.',
    path: '/vvip',
    robots: 'index,follow'
  },
  privacy: {
    title: 'Privacy Policy — America Ships On Click',
    description: 'What America Ships On Click collects, what stays public on the ledger, and how optional page counts work.',
    path: '/privacy',
    robots: 'index,follow'
  },
  terms: {
    title: 'Terms of Use — America Ships On Click',
    description: 'Operating terms for the America Ships On Click load board: accounts, posted loads, fees, and the public ledger.',
    path: '/terms',
    robots: 'index,follow'
  },
  notfound: {
    title: 'Page not found — America Ships On Click',
    description: 'That address is not on America Ships On Click.',
    path: '/',
    robots: 'noindex,nofollow'
  }
};

export function applyPageMeta(tab: string) {
  const meta = PAGE_META[tab] ?? PAGE_META.notfound;
  document.title = meta.title;
  setNamedMeta('description', meta.description);
  setNamedMeta('robots', meta.robots);
  setNamedMeta('og:title', meta.title, 'property');
  setNamedMeta('og:description', meta.description, 'property');
  const origin = window.location.origin;
  const url = tab === 'notfound' ? window.location.href : origin + meta.path;
  setNamedMeta('og:url', url, 'property');
  const canonical = document.querySelector<HTMLLinkElement>('link[rel="canonical"]');
  if (canonical) canonical.href = tab === 'notfound' ? origin + '/' : origin + meta.path;
}

function setNamedMeta(name: string, content: string, attr: 'name' | 'property' = 'name') {
  let el = document.querySelector<HTMLMetaElement>(`meta[${attr}="${name}"]`);
  if (!el) {
    el = document.createElement('meta');
    el.setAttribute(attr, name);
    document.head.appendChild(el);
  }
  el.content = content;
}
