import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { api } from '../lib/api';
import { useRealtimeSettlements } from '../lib/useRealtimeSettlements';

interface HomeProps {
  setActiveTab: (tab: string) => void;
}

export const Home: React.FC<HomeProps> = ({ setActiveTab }) => {
  // Fetch real-time aggregate totals from backend API
  const { data: totals } = useQuery({
    queryKey: ['settlementTotals'],
    queryFn: () => api.getSettlementTotals(),
    refetchInterval: 10000
  });

  // Fetch recent settlements for the hero manifest card
  const { data: recentSettlements = [] } = useQuery({
    queryKey: ['settlements'],
    queryFn: () => api.getSettlements(12, 1)
  });

  // Subscribe to live SSE events
  useRealtimeSettlements();

  const topSettlement = recentSettlements[0] || {
    id: 'ASOC-9982',
    origin_city: 'LAREDO',
    origin_state: 'TX',
    dest_city: 'GARY',
    dest_state: 'IN',
    miles: 1348,
    rate_per_mile: 3.20,
    gross_amount: 4313.60,
    fee_amount: 215.68,
    net_amount: 4097.92
  };

  const loadsCount = totals?.count ?? 14802;
  const milesCount = totals?.miles ?? 4200000;
  const netPaidCount = totals?.net ?? 12400000;

  return (
    <div className="bg-[#F0EAD8] text-[#14171A]">
      {/* MAIN HERO VIEWPORT AREA */}
      <section className="grid grid-cols-1 lg:grid-cols-12 border-b-2 border-[#14171A]">
        
        {/* Left Hero Section: Headline & Stats */}
        <div className="lg:col-span-7 p-8 sm:p-12 flex flex-col justify-between border-b-2 lg:border-b-0 lg:border-r-2 border-[#14171A]">
          <div>
            <h1 className="text-5xl sm:text-6xl xl:text-7xl font-serif font-black uppercase leading-[0.85] tracking-tighter mb-6 text-[#14171A]">
              NO BROKERS.<br />
              NO SECRETS.<br />
              JUST <span className="text-[#0F5132]">FREIGHT.</span>
            </h1>
            <p className="max-w-xl text-lg leading-snug border-l-4 border-[#14171A] pl-4 italic opacity-85 mb-8">
              The first trucking platform with a public settlement ledger. We take 5%. Shippers pay less, drivers make more. Everyone sees the math.
            </p>

            <div className="flex flex-wrap gap-4 mb-10">
              <button
                className="btn primary py-3.5 px-6"
                onClick={() => setActiveTab('loads')}
              >
                Find Loads
              </button>
              <button
                className="btn ghost py-3.5 px-6"
                onClick={() => setActiveTab('books')}
              >
                Open Books Ledger
              </button>
            </div>
          </div>

          {/* Stats Row (DB Aggregates) */}
          <div className="grid grid-cols-3 gap-2 sm:gap-4 border-2 border-[#14171A] p-4 sm:p-5 bg-white/60 shadow-[4px_4px_0px_#14171A] mb-8">
            <div className="flex flex-col">
              <span className="text-[10px] font-mono font-bold uppercase text-[#8C2F1B]">Loads Settled</span>
              <span className="text-2xl sm:text-3xl font-mono font-black tracking-tighter">
                {loadsCount.toLocaleString()}
              </span>
            </div>
            <div className="flex flex-col border-x-2 border-[#14171A] px-2 sm:px-4">
              <span className="text-[10px] font-mono font-bold uppercase text-[#8C2F1B]">Miles Hauled</span>
              <span className="text-2xl sm:text-3xl font-mono font-black tracking-tighter">
                {(milesCount / 1000000).toFixed(1)}M
              </span>
            </div>
            <div className="flex flex-col pl-1 sm:pl-2">
              <span className="text-[10px] font-mono font-bold uppercase text-[#8C2F1B]">Paid To Carriers</span>
              <span className="text-2xl sm:text-3xl font-mono font-black tracking-tighter text-[#0F5132]">
                ${(netPaidCount / 1000000).toFixed(1)}M
              </span>
            </div>
          </div>

          {/* Comparison Module */}
          <div className="flex flex-col gap-2">
            <h3 className="text-xs font-mono font-bold uppercase tracking-widest text-[#14171A]">
              Market Fee Comparison
            </h3>
            <div className="flex flex-col sm:flex-row gap-4">
              <div className="flex-1 bg-[#8C2F1B] text-[#F0EAD8] p-3.5 relative border-2 border-[#14171A]">
                <div className="text-[10px] font-mono font-bold uppercase opacity-80">Traditional Broker</div>
                <div className="text-2xl font-mono font-bold">18-25%</div>
                <div className="absolute top-2 right-2 transform rotate-12 border border-[#F0EAD8] px-1 text-[8px] opacity-80 font-mono font-bold uppercase">
                  HIDDEN
                </div>
              </div>
              <div className="flex-1 bg-[#0F5132] text-[#F0EAD8] p-3.5 border-2 border-[#14171A]">
                <div className="text-[10px] font-mono font-bold uppercase opacity-80">Our Platform</div>
                <div className="text-2xl font-mono font-bold">5.0% FLAT</div>
              </div>
            </div>
          </div>
        </div>

        {/* Right Hero Section: Live Manifest Card & Paper Overlay */}
        <div className="lg:col-span-5 p-8 sm:p-12 bg-[#E8E2CF] flex flex-col items-center justify-center relative overflow-hidden">
          {/* Subtle Grain Overlay */}
          <div
            className="absolute inset-0 opacity-10 pointer-events-none mix-blend-multiply"
            style={{
              backgroundImage: 'radial-gradient(#000 0.5px, transparent 0.5px)',
              backgroundSize: '3px 3px'
            }}
          />

          {/* Manifest Card Container */}
          <div className="w-full max-w-md bg-[#FAFAF7] p-6 shadow-[10px_10px_0px_rgba(20,23,26,0.15)] border-2 border-[#14171A] relative rotate-1">
            {/* Punch Holes on the Left */}
            <div className="punch-holes-left">
              <div className="punch-hole" />
              <div className="punch-hole" />
              <div className="punch-hole" />
              <div className="punch-hole" />
              <div className="punch-hole" />
            </div>

            <div className="flex justify-between items-start border-b-2 border-[#14171A] pb-4 mb-4">
              <div>
                <div className="text-[10px] font-mono font-bold leading-none uppercase text-[#5B6168]">
                  MANIFEST #{topSettlement.id}
                </div>
                <div className="text-xl font-serif font-black uppercase tracking-tight text-[#14171A]">
                  Settlement Detail
                </div>
              </div>
              <div className="text-right">
                <div className="text-[8px] font-mono opacity-60 uppercase font-bold">Status</div>
                <div className="text-[10px] font-mono text-[#0F5132] font-bold">LIVE SETTLED</div>
              </div>
            </div>

            <div className="space-y-2.5 font-mono text-xs">
              <div className="flex justify-between border-b border-dashed border-[#14171A]/20 py-1">
                <span>ROUTE:</span>
                <span className="font-bold text-[#14171A]">
                  {topSettlement.origin_city}, {topSettlement.origin_state} &rarr; {topSettlement.dest_city}, {topSettlement.dest_state}
                </span>
              </div>
              <div className="flex justify-between border-b border-dashed border-[#14171A]/20 py-1">
                <span>MILES:</span>
                <span>{Number(topSettlement.miles).toLocaleString()}</span>
              </div>
              <div className="flex justify-between border-b border-dashed border-[#14171A]/20 py-1">
                <span>GROSS RATE:</span>
                <span className="font-bold">${Number(topSettlement.gross_amount || 0).toFixed(2)}</span>
              </div>
              <div className="flex justify-between border-b border-dashed border-[#14171A]/20 py-1 text-[#8C2F1B]">
                <span>PLATFORM FEE (5%):</span>
                <span>&minus; ${Number(topSettlement.fee_amount || 0).toFixed(2)}</span>
              </div>
              <div className="flex justify-between border-b border-dashed border-[#14171A]/20 py-1 opacity-70">
                <span>FUEL SURCHARGE:</span>
                <span>$0.42 / MILE</span>
              </div>

              <div className="pt-4">
                <div className="flex justify-between items-end">
                  <div className="flex flex-col">
                    <span className="text-[8px] uppercase font-mono font-bold text-[#5B6168]">
                      Final Net Payment
                    </span>
                    <span className="text-3xl font-black font-mono text-[#0F5132]">
                      ${Number(topSettlement.net_amount || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </span>
                  </div>
                  <div className="border-4 border-[#0F5132] text-[#0F5132] px-3 py-1 font-mono font-black transform -rotate-12 uppercase tracking-tighter text-xs">
                    PAID VIA ACH
                  </div>
                </div>
              </div>
            </div>
          </div>

          <button
            onClick={() => setActiveTab('books')}
            className="mt-8 bg-[#E3A008] text-[#14171A] border-2 border-[#14171A] px-8 py-3.5 font-mono font-black uppercase tracking-widest text-xs shadow-[6px_6px_0px_#14171A] hover:translate-x-0.5 hover:translate-y-0.5 transition-transform"
          >
            View Full Public Ledger
          </button>
        </div>
      </section>

      {/* BROKER VS PLATFORM RECEIPT COMPARISON */}
      <section className="py-16 border-b-2 border-[#14171A] bg-[#FAFAF7]">
        <div className="max-w-[1180px] mx-auto px-6">
          <div className="max-w-2xl mx-auto text-center mb-10">
            <span className="eyebrow block mb-1">The Financial Math</span>
            <h2 className="text-3xl sm:text-4xl mb-3">Same load. Two ways to get paid.</h2>
            <p className="text-[#5B6168] font-mono text-xs sm:text-sm">
              A dry van load: Dallas, TX to Atlanta, GA. 780 miles at $2.15/mile. Here's where the money actually goes.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-8 max-w-4xl mx-auto">
            {/* Traditional Broker Receipt */}
            <div className="receipt">
              <span className="receipt-tag">Traditional Broker</span>
              <div className="receipt-line">
                <span>Shipper pays</span>
                <span>$1,677.00</span>
              </div>
              <div className="receipt-line">
                <span>Broker keeps (20%)</span>
                <span className="text-[#8C2F1B]">&minus;$335.40</span>
              </div>
              <div className="receipt-line text-[#5B6168]">
                <span>Hidden margin</span>
                <span>Unlisted</span>
              </div>
              <div className="receipt-line total">
                <span>Carrier receives</span>
                <span>$1,341.60</span>
              </div>
            </div>

            {/* America Ships On Click Receipt */}
            <div className="receipt us">
              <span className="receipt-tag">America Ships On Click</span>
              <div className="receipt-line">
                <span>Shipper pays</span>
                <span>$1,677.00</span>
              </div>
              <div className="receipt-line">
                <span>Platform fee (5%)</span>
                <span className="text-[#8C2F1B]">&minus;$83.85</span>
              </div>
              <div className="receipt-line font-bold text-[#0F5132]">
                <span>Posted to Open Books</span>
                <span>✓ Public</span>
              </div>
              <div className="receipt-line total text-[#0F5132]">
                <span>Carrier receives</span>
                <span className="text-xl font-bold">$1,593.15</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* THREE STEPS */}
      <section className="py-16 bg-[#F0EAD8]">
        <div className="max-w-[1180px] mx-auto px-6">
          <div className="max-w-2xl mx-auto text-center mb-10">
            <span className="eyebrow block mb-1">How It Works</span>
            <h2 className="text-3xl sm:text-4xl">Three steps. No dispatcher in the middle.</h2>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8 max-w-5xl mx-auto">
            <div className="bg-[#FAFAF7] border-2 border-[#14171A] p-6 shadow-[4px_4px_0px_#14171A]">
              <div className="font-mono text-xs text-[#0F5132] font-bold tracking-wider mb-2">
                01 / POST OR FIND
              </div>
              <h3 className="text-xl mb-2">List it or book it</h3>
              <p className="text-[#5B6168] text-sm">
                Shippers post a lane and a rate. Carriers browse the board and book direct — no calls to a broker to "check availability."
              </p>
            </div>
            <div className="bg-[#FAFAF7] border-2 border-[#14171A] p-6 shadow-[4px_4px_0px_#14171A]">
              <div className="font-mono text-xs text-[#0F5132] font-bold tracking-wider mb-2">
                02 / HAUL IT
              </div>
              <h3 className="text-xl mb-2">Run the lane</h3>
              <p className="text-[#5B6168] text-sm">
                Pick up, deliver, upload the POD. Equipment, weight, and pickup window are locked in before you roll.
              </p>
            </div>
            <div className="bg-[#FAFAF7] border-2 border-[#14171A] p-6 shadow-[4px_4px_0px_#14171A]">
              <div className="font-mono text-xs text-[#0F5132] font-bold tracking-wider mb-2">
                03 / GET PAID
              </div>
              <h3 className="text-xl mb-2">Settle same day</h3>
              <p className="text-[#5B6168] text-sm">
                Funds move and the transaction posts to Open Books automatically. No "check's in the mail."
              </p>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
};

