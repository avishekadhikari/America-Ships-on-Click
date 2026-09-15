import React from 'react';
import { User } from '../types/api';
import { Dashboard } from './Dashboard';
import { RateCardsAdmin } from './RateCardsAdmin';

interface AdminProps {
  currentUser: User | null;
  onOpenAuth: () => void;
  onSwitchRole: () => void;
}

/**
 * The /admin entry point.
 *
 * This gate is presentation only — it decides what the browser renders, not
 * what the API returns. Every privileged read is still enforced server-side by
 * `requireRole('admin')` and by the RLS policies behind `app_is_admin()`, so a
 * non-admin who edits their way past this component still gets 403s.
 */
export const Admin: React.FC<AdminProps> = ({ currentUser, onOpenAuth, onSwitchRole }) => {
  if (!currentUser) {
    return (
      <div className="py-16">
        <div className="max-w-160 mx-auto px-6 text-center">
          <div className="p-8 bg-[#FAFAF7] border-2 border-[#E3A008] rounded shadow-md space-y-4">
            <span className="eyebrow block">Platform Administration</span>
            <h2 className="text-2xl font-display-title text-[#14171A]">
              Authentication Required
            </h2>
            <p className="text-[#5B6168] text-sm">
              The admin console exposes the full settlement ledger, carrier identities,
              and CSV export. Sign in with a platform admin account to continue.
            </p>
            <button onClick={onOpenAuth} className="btn amber px-8 py-3 font-mono">
              Sign In or Select Demo Account
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (currentUser.role !== 'admin') {
    return (
      <div className="py-16">
        <div className="max-w-160 mx-auto px-6 text-center">
          <div className="p-8 bg-[#FAFAF7] border-2 border-[#8C2F1B] rounded shadow-md space-y-4">
            <span className="eyebrow block">Access Denied</span>
            <h2 className="text-2xl font-display-title text-[#14171A]">
              Admin Role Required
            </h2>
            <p className="text-[#5B6168] text-sm">
              You are signed in as{' '}
              <b className="font-mono uppercase">{currentUser.role}</b>. The admin
              console is restricted to platform administrators.
            </p>
            <button onClick={onSwitchRole} className="btn amber px-8 py-3 font-mono">
              Switch Account
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      <Dashboard currentUser={currentUser} onOpenAuth={onOpenAuth} onSwitchRole={onSwitchRole} />
      <div className="max-w-[1180px] mx-auto px-6 pb-16">
        <RateCardsAdmin />
      </div>
    </>
  );
};
