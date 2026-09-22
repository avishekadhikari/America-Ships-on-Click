import React, { useState } from 'react';
import { Consent, getConsent, setConsent } from '../lib/analytics';
import { followTabLink } from '../lib/routes';

interface CookieConsentProps {
  onChoose: (value: Consent) => void;
  onNavigate: (tab: string) => void;
}

export const CookieConsent: React.FC<CookieConsentProps> = ({ onChoose, onNavigate }) => {
  const [choice, setChoice] = useState<Consent | null>(() => getConsent());
  if (choice) return null;

  const choose = (value: Consent) => {
    setConsent(value);
    setChoice(value);
    onChoose(value);
  };

  return (
    <div className="fixed inset-x-0 bottom-0 z-40 p-3 sm:p-4" role="dialog" aria-labelledby="cookie-title">
      <div className="mx-auto flex max-w-3xl flex-col gap-3 border-2 border-[#14171A] bg-[#14171A] p-4 text-[#F0EAD8] shadow-[4px_4px_0px_#E3A008] sm:flex-row sm:items-end sm:justify-between">
        <div className="max-w-xl">
          <p id="cookie-title" className="font-mono text-xs font-bold uppercase tracking-widest text-[#E3A008]">
            This browser
          </p>
          <p className="mt-1 text-sm leading-snug text-[#F0EAD8]">
            Sign-in stays in local storage on this device. We do not set advertising cookies.
            Optional analytics records the page path only.
          </p>
          <p className="mt-2 font-mono text-xs">
            <a
              href="/privacy"
              className="text-[#E3A008] underline underline-offset-2"
              onClick={(e) => followTabLink(e, onNavigate, 'privacy')}
            >
              Privacy
            </a>
            <span className="px-2 text-[#C4BEB0]" aria-hidden="true">·</span>
            <a
              href="/terms"
              className="text-[#E3A008] underline underline-offset-2"
              onClick={(e) => followTabLink(e, onNavigate, 'terms')}
            >
              Terms
            </a>
          </p>
        </div>
        <div className="flex shrink-0 gap-2">
          <button type="button" className="btn ghost py-2 px-3 text-xs" onClick={() => choose('essential')}>
            Essential only
          </button>
          <button type="button" className="btn amber py-2 px-3 text-xs" onClick={() => choose('analytics')}>
            Allow analytics
          </button>
        </div>
      </div>
    </div>
  );
};
