import React, { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { api } from '../lib/api';
import { User } from '../types/api';

interface NavbarProps {
  activeTab: string;
  setActiveTab: (tab: string) => void;
  currentUser: User | null;
  onOpenAuth: () => void;
  onLogout: () => void;
}

export const Navbar: React.FC<NavbarProps> = ({
  activeTab,
  setActiveTab,
  currentUser,
  onOpenAuth,
  onLogout
}) => {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  // Fetch recent settlements for the live ticker
  const { data: tickerSettlements = [] } = useQuery({
    queryKey: ['settlements'],
    queryFn: () => api.getSettlements(6, 1),
    refetchInterval: 12000
  });

  const navItems = [
    { id: 'home', label: 'Home' },
    { id: 'loads', label: 'Find Loads' },
    { id: 'books', label: 'Open Books' },
    { id: 'driver', label: 'Drive With Us' },
    { id: 'shipper', label: 'Post Load' },
    { id: 'dashboard', label: 'Dashboard' }
  ];

  return (
    <header className="sticky top-0 z-50 flex flex-col border-b-2 border-[#14171A]">
      {/* Top Navigation Bar */}
      <div className="bg-[#14171A] text-[#F0EAD8] px-6 py-3.5 flex items-center justify-between gap-4">
        {/* Brand Logo */}
        <button
          onClick={() => setActiveTab('home')}
          className="flex items-center gap-3 text-left bg-transparent border-none cursor-pointer p-0 group"
          aria-label="America Ships On Click — Home"
        >
          <div className="w-9 h-9 bg-[#E3A008] text-[#14171A] font-black font-mono text-xl flex items-center justify-center border-2 border-[#F0EAD8] shadow-[2px_2px_0px_#F0EAD8] group-hover:translate-x-0.5 transition-transform">
            A
          </div>
          <span className="font-serif font-black text-xl tracking-tight uppercase leading-none text-[#F0EAD8]">
            America Ships On Click
            <small className="block font-mono text-[#E3A008] text-[0.62rem] font-bold tracking-widest mt-1">
              NO BROKERS · OPEN BOOKS LEDGER
            </small>
          </span>
        </button>

        {/* Mobile Hamburger Toggle */}
        <button
          className="md:hidden flex flex-col gap-1.5 p-2 bg-transparent border-none cursor-pointer"
          onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
          aria-label="Toggle Navigation Menu"
          aria-expanded={mobileMenuOpen}
        >
          <span className="w-6 h-0.5 bg-[#F0EAD8]"></span>
          <span className="w-6 h-0.5 bg-[#F0EAD8]"></span>
          <span className="w-6 h-0.5 bg-[#F0EAD8]"></span>
        </button>

        {/* Desktop Nav Links */}
        <nav className={`
          md:flex items-center gap-6 list-none m-0 p-0
          ${mobileMenuOpen ? 'flex flex-col absolute top-full left-0 right-0 bg-[#14171A] p-6 border-b-2 border-[#14171A] shadow-2xl z-50' : 'hidden md:flex'}
        `}>
          {navItems.map((item) => {
            const isActive = activeTab === item.id;
            return (
              <button
                key={item.id}
                onClick={() => {
                  setActiveTab(item.id);
                  setMobileMenuOpen(false);
                }}
                className={`
                  text-left text-xs font-mono font-bold uppercase tracking-widest transition-all bg-transparent border-none cursor-pointer py-1.5 px-1
                  ${isActive 
                    ? 'text-[#E3A008] underline underline-offset-8 decoration-2' 
                    : 'text-[#F0EAD8]/80 hover:text-[#F0EAD8] hover:underline hover:underline-offset-4'}
                `}
              >
                {item.label}
              </button>
            );
          })}

          {/* User Auth Action */}
          <div className="pt-3 md:pt-0 border-t md:border-t-0 border-[#F0EAD8]/20 flex items-center gap-3">
            {currentUser ? (
              <div className="flex items-center gap-2 font-mono text-xs">
                <span className="bg-[#0F5132] text-[#F0EAD8] border border-[#F0EAD8]/40 px-2 py-0.5 font-bold uppercase text-[0.68rem]">
                  {currentUser.role}
                </span>
                <button
                  onClick={onLogout}
                  className="text-[#F0EAD8]/70 hover:text-[#F0EAD8] underline bg-transparent border-none cursor-pointer p-0"
                >
                  Sign Out
                </button>
              </div>
            ) : (
              <button
                onClick={onOpenAuth}
                className="btn amber py-1.5 px-3 text-[0.72rem]"
              >
                Sign In
              </button>
            )}
          </div>
        </nav>
      </div>

      {/* Live Ticker Bar */}
      <div className="bg-[#E3A008] text-[#14171A] py-1.5 border-t border-[#14171A] overflow-hidden whitespace-nowrap flex items-center">
        <div className="flex animate-none px-4 text-[10px] font-mono font-bold uppercase gap-8 overflow-x-auto no-scrollbar w-full">
          {tickerSettlements.length > 0 ? (
            tickerSettlements.map((s, i) => (
              <span key={'ticker-' + s.id + '-' + i} className="flex-none flex items-center gap-2">
                <span className="w-1.5 h-1.5 rounded-full bg-[#8C2F1B]"></span>
                <span>LATEST SETTLEMENT:</span>
                <span className="font-extrabold">{s.origin_city}, {s.origin_state} &rarr; {s.dest_city}, {s.dest_state}</span>
                <span>• ${Number(s.rate_per_mile).toFixed(2)}/MILE</span>
                <span>• CARRIER NET: <b className="text-[#0F5132]">${Math.round(Number(s.net_amount)).toLocaleString()}</b></span>
              </span>
            ))
          ) : (
            <span>LATEST SETTLEMENT: CHICAGO, IL &rarr; DENVER, CO • $3.42/MILE • CARRIER NET: $2,840.10</span>
          )}
        </div>
      </div>
    </header>
  );
};

