import React, { useCallback, useEffect, useState } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Navbar } from './components/Navbar';
import { Footer } from './components/Footer';
import { AuthModal } from './components/AuthModal';

import { Home } from './pages/Home';
import { FindLoads } from './pages/FindLoads';
import { OpenBooks } from './pages/OpenBooks';
import { DriveWithUs } from './pages/DriveWithUs';
import { PostLoad } from './pages/PostLoad';
import { Dashboard } from './pages/Dashboard';
import { Admin } from './pages/Admin';

import { api } from './lib/api';
import { User } from './types/api';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5000,
      refetchOnWindowFocus: false,
    },
  },
});

/**
 * Tab-to-URL map. Each view has a real, linkable path so /admin (and the rest)
 * can be typed, bookmarked, and shared. Both the dev Vite middleware
 * (appType: 'spa') and the production catch-all in backend/server.ts serve
 * index.html for these paths, so a cold load lands on the right view.
 */
const TAB_PATHS: Record<string, string> = {
  home: '/',
  loads: '/loads',
  books: '/books',
  driver: '/drive',
  shipper: '/post-load',
  dashboard: '/dashboard',
  admin: '/admin'
};

const PATH_TABS: Record<string, string> = Object.fromEntries(
  Object.entries(TAB_PATHS).map(([tab, path]) => [path, tab])
);

/** Unknown paths fall back to home; trailing slashes are ignored. */
function tabForPath(pathname: string): string {
  const normalized = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname;
  return PATH_TABS[normalized] ?? 'home';
}

export default function App() {
  const [activeTab, setActiveTabState] = useState(() => tabForPath(window.location.pathname));
  const [currentUser, setCurrentUser] = useState<User | null>(null);
  const [authModalOpen, setAuthModalOpen] = useState(false);

  // Navigation writes the URL as well as the tab, so Back/Forward and a
  // pasted link both work.
  const setActiveTab = useCallback((tab: string) => {
    setActiveTabState(tab);
    const path = TAB_PATHS[tab] ?? '/';
    if (window.location.pathname !== path) {
      window.history.pushState({ tab }, '', path);
    }
  }, []);

  // Rewrite the address bar to the canonical path on first load, so an
  // unrecognized or trailing-slash URL does not sit over the home view.
  useEffect(() => {
    const canonical = TAB_PATHS[tabForPath(window.location.pathname)];
    if (canonical && window.location.pathname !== canonical) {
      window.history.replaceState({ tab: activeTab }, '', canonical + window.location.search);
    }
    // Intentionally mount-only: this normalizes the entry URL, nothing later.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Browser Back/Forward moves between views.
  useEffect(() => {
    const onPopState = () => setActiveTabState(tabForPath(window.location.pathname));
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  // Check auth session on mount
  useEffect(() => {
    async function checkAuth() {
      try {
        const data = await api.getMe();
        if (data.user) {
          setCurrentUser(data.user);
        }
      } catch {
        // Token invalid or absent
        setCurrentUser(null);
      }
    }
    checkAuth();
  }, []);

  const handleLogout = () => {
    api.logout();
    setCurrentUser(null);
    // Do not leave a signed-out browser parked on the admin console.
    if (activeTab === 'admin') {
      setActiveTab('home');
    }
  };

  return (
    <QueryClientProvider client={queryClient}>
      <div className="min-h-screen flex flex-col bg-[#F0EAD8] text-[#22262A] font-sans antialiased">
        {/* Navigation Bar */}
        <Navbar
          activeTab={activeTab}
          setActiveTab={setActiveTab}
          currentUser={currentUser}
          onOpenAuth={() => setAuthModalOpen(true)}
          onLogout={handleLogout}
        />

        {/* Page Content */}
        <main className="flex-1">
          {activeTab === 'home' && <Home setActiveTab={setActiveTab} />}
          {activeTab === 'loads' && (
            <FindLoads
              currentUser={currentUser}
              onOpenAuth={() => setAuthModalOpen(true)}
              setActiveTab={setActiveTab}
            />
          )}
          {activeTab === 'books' && <OpenBooks />}
          {activeTab === 'driver' && (
            <DriveWithUs
              onSuccessOnboard={(user) => {
                setCurrentUser(user);
                setActiveTab('loads');
              }}
            />
          )}
          {activeTab === 'shipper' && (
            <PostLoad
              currentUser={currentUser}
              onOpenAuth={() => setAuthModalOpen(true)}
              setActiveTab={setActiveTab}
            />
          )}
          {activeTab === 'dashboard' && (
            <Dashboard
              currentUser={currentUser}
              onOpenAuth={() => setAuthModalOpen(true)}
              onSwitchRole={() => {
                api.logout();
                setCurrentUser(null);
                setAuthModalOpen(true);
              }}
            />
          )}
          {activeTab === 'admin' && (
            <Admin
              currentUser={currentUser}
              onOpenAuth={() => setAuthModalOpen(true)}
              onSwitchRole={() => {
                api.logout();
                setCurrentUser(null);
                setAuthModalOpen(true);
              }}
            />
          )}
        </main>

        {/* Footer */}
        <Footer setActiveTab={setActiveTab} />

        {/* Auth Modal */}
        <AuthModal
          isOpen={authModalOpen}
          onClose={() => setAuthModalOpen(false)}
          onSuccess={(user) => setCurrentUser(user)}
        />
      </div>
    </QueryClientProvider>
  );
}
