import React, { FormEvent, useEffect, useState } from 'react';
import { api } from '../lib/api';
import { VvipRole } from '../types/api';

const PERKS = [
  'Golden badge + priority queue',
  'Live load board + ETA',
  '15–30 min quote window',
  'After-hours white-glove',
  'Invite-only partner rates (platform take capped at 7%)',
  'Dashboard for shipments / invoices / docs'
] as const;

const ROLE_OPTIONS: { value: VvipRole; label: string }[] = [
  { value: 'shipper', label: 'Shipper' },
  { value: 'carrier', label: 'Carrier / owner-operator' },
  { value: 'fleet', label: 'Fleet' },
  { value: 'other', label: 'Other' }
];

const fieldClass =
  'w-full rounded-lg border border-[#3a3320] bg-[#12141c] px-3.5 py-2.5 text-sm text-[#F4EFE2] placeholder:text-[#6B6570] outline-none transition-colors focus:border-[#E3A008]';

const labelClass =
  'mb-1.5 block text-[11px] font-semibold uppercase tracking-[0.14em] text-[#C9B896]';

export const GoldenVvip: React.FC = () => {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [whoYouAre, setWhoYouAre] = useState<VvipRole | ''>('');
  const [location, setLocation] = useState('');
  const [website, setWebsite] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const [alreadyOnList, setAlreadyOnList] = useState(false);

  useEffect(() => {
    const previous = document.title;
    document.title = 'Golden VVIP — America Ships On Click';
    return () => {
      document.title = previous;
    };
  }, []);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrorMsg(null);

    if (!whoYouAre) {
      setErrorMsg('Select who you are.');
      return;
    }

    setSubmitting(true);
    try {
      const result = await api.preregisterVvip({
        name,
        email,
        who_you_are: whoYouAre,
        location,
        website
      });
      setAlreadyOnList(Boolean(result.already_on_list));
      setSubmitted(true);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : 'Could not submit. Try again.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="vvip-page min-h-screen bg-[#07080C] text-[#F4EFE2]">
      <main className="mx-auto flex max-w-[34rem] flex-col px-5 py-10 sm:py-14">
        <p className="mb-4 text-[11px] font-bold uppercase tracking-[0.22em] text-[#E3A008]">
          America Ships On Click
        </p>

        <span className="mb-5 inline-flex w-fit rounded-full bg-[#E8C547] px-3 py-1 text-[10px] font-extrabold uppercase tracking-[0.12em] text-[#14171A]">
          Golden VVIP · ASOC Beta
        </span>

        <h1 className="mb-3 font-serif text-4xl font-black leading-[1.12] tracking-tight text-white sm:text-[2.6rem]">
          America Ships On Click
          <span className="block">
            — <span className="text-[#F0D24A]">Golden VVIP</span>
          </span>
        </h1>

        <p className="mb-6 text-[15px] leading-snug text-[#9AA0A8]">
          Priority freight desk. Named ops. Rates that don&apos;t surprise you.
        </p>

        <div className="mb-6 rounded-xl border border-[#E3A008]/35 bg-gradient-to-r from-[#3a2c08] via-[#2a1814] to-[#3a1220] px-4 py-3.5">
          <p className="text-[13px] leading-snug text-[#F0D24A]">
            <span className="font-semibold">Pre-register VVIP before the public window.</span>{' '}
            <span className="text-[#E8D9A8]">Early list only — interest capture, not an offer of securities.</span>
          </p>
        </div>

        <ul className="mb-6 divide-y divide-[#2a2618] overflow-hidden rounded-xl border border-[#3a3320]">
          {PERKS.map((perk) => (
            <li key={perk} className="flex items-start gap-3 px-4 py-3 text-[14px] text-[#E8E0D0]">
              <span className="mt-0.5 shrink-0 text-[#E8C547]" aria-hidden="true">
                ✦
              </span>
              <span>{perk}</span>
            </li>
          ))}
        </ul>

        <section className="rounded-xl border border-[#3a3320] bg-[#0C0E14] p-5 sm:p-6">
          {submitted ? (
            <div role="status">
              <h2 className="mb-2 font-serif text-2xl font-black text-white">
                {alreadyOnList ? "You're already on the list." : "You're on the list."}
              </h2>
              <p className="text-sm leading-relaxed text-[#9AA0A8]">
                {alreadyOnList
                  ? 'That email is already registered for Golden VVIP. We will reach out from the founder inbox before the public window.'
                  : 'We will reach you from the ASOC founder inbox before the public window. No account was created.'}
              </p>
            </div>
          ) : (
            <form onSubmit={handleSubmit} noValidate className="relative">
              <div className="mb-4">
                <label htmlFor="vvip-name" className={labelClass}>
                  Name
                </label>
                <input
                  id="vvip-name"
                  name="name"
                  type="text"
                  autoComplete="name"
                  required
                  maxLength={80}
                  placeholder="Your name"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className={fieldClass}
                />
              </div>

              <div className="mb-4">
                <label htmlFor="vvip-email" className={labelClass}>
                  Email
                </label>
                <input
                  id="vvip-email"
                  name="email"
                  type="email"
                  autoComplete="email"
                  required
                  maxLength={254}
                  placeholder="you@email.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className={fieldClass}
                />
              </div>

              <div className="mb-4">
                <label htmlFor="vvip-who" className={labelClass}>
                  Who you are
                </label>
                <select
                  id="vvip-who"
                  name="who_you_are"
                  required
                  value={whoYouAre}
                  onChange={(e) => setWhoYouAre(e.target.value as VvipRole | '')}
                  className={`${fieldClass} appearance-none bg-[length:1rem] bg-[right_0.75rem_center] bg-no-repeat pr-10`}
                  style={{
                    backgroundImage:
                      'url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'16\' height=\'16\' fill=\'%23E3A008\' viewBox=\'0 0 16 16\'%3E%3Cpath d=\'M4.5 6.5 8 10l3.5-3.5\'/%3E%3C/svg%3E")'
                  }}
                >
                  <option value="">Select…</option>
                  {ROLE_OPTIONS.map((option) => (
                    <option key={option.value} value={option.value}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </div>

              <div className="mb-5">
                <label htmlFor="vvip-location" className={labelClass}>
                  Location
                </label>
                <input
                  id="vvip-location"
                  name="location"
                  type="text"
                  autoComplete="address-level2"
                  required
                  maxLength={120}
                  placeholder="City, State"
                  value={location}
                  onChange={(e) => setLocation(e.target.value)}
                  className={fieldClass}
                />
              </div>

              <div className="hidden" aria-hidden="true">
                <label htmlFor="vvip-website">Website</label>
                <input
                  id="vvip-website"
                  name="website"
                  type="text"
                  tabIndex={-1}
                  autoComplete="off"
                  value={website}
                  onChange={(e) => setWebsite(e.target.value)}
                />
              </div>

              {errorMsg ? (
                <p className="mb-3 text-sm text-[#E07A5F]" role="alert">
                  {errorMsg}
                </p>
              ) : null}

              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-lg bg-[#F0D24A] px-4 py-3 text-[13px] font-extrabold uppercase tracking-[0.16em] text-[#14171A] transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {submitting ? 'Sending…' : 'Pre-register VVIP'}
              </button>

              <p className="mt-3 text-center text-[11px] leading-relaxed text-[#6B6570]">
                Submissions go straight to the ASOC founder inbox. No accounts. No payments. No
                Web3 on this page. Interest list only — not an offer of securities.
              </p>
            </form>
          )}
        </section>
      </main>
    </div>
  );
};
