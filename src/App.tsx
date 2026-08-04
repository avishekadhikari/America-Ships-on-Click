import React, { useState, useEffect } from 'react';
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

export default function App() {
  const [activeTab, setActiveTab] = useState('home');
  const [currentUser, setCurrentUser] = useState<User | null>(null);
  const [authModalOpen, setAuthModalOpen] = useState(false);

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
            />
          )}
          {activeTab === 'dashboard' && (
            <Dashboard
              currentUser={currentUser}
              onOpenAuth={() => setAuthModalOpen(true)}
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
