import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '../lib/api';
import { EquipmentType, User } from '../types/api';

interface PostLoadProps {
  currentUser: User | null;
  onOpenAuth: () => void;
}

export const PostLoad: React.FC<PostLoadProps> = ({ currentUser, onOpenAuth }) => {
  const queryClient = useQueryClient();

  // Fetch single source of truth for platform config
  const { data: config } = useQuery({
    queryKey: ['config'],
    queryFn: () => api.getConfig()
  });

  const feePct = config?.fee_pct ?? 0.05;
  const factorPct = config?.factor_pct ?? 0.03;

  // Form State
  const [originCity, setOriginCity] = useState('');
  const [originState, setOriginState] = useState('');
  const [destCity, setDestCity] = useState('');
  const [destState, setDestState] = useState('');
  const [miles, setMiles] = useState<number>(780);
  const [ratePerMile, setRatePerMile] = useState<number>(2.15);
  const [equipmentType, setEquipmentType] = useState<EquipmentType>('dry_van');
  const [pickupDate, setPickupDate] = useState<string>('2026-08-10');
  const [weightLbs, setWeightLbs] = useState<number>(42000);
  const [sameDayFundingOffered, setSameDayFundingOffered] = useState<boolean>(false);
  const [notes, setNotes] = useState<string>('Palletized freight, clean trailer');

  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  // Live Calculator Math
  const grossAmount = (miles || 0) * (ratePerMile || 0);
  const feeAmount = grossAmount * feePct;
  const factorAmount = sameDayFundingOffered ? grossAmount * factorPct : 0;
  const netTakeHome = grossAmount - feeAmount - factorAmount;

  // Create Load Mutation
  const createLoadMutation = useMutation({
    mutationFn: (data: any) => api.createLoad(data),
    onSuccess: (newLoad) => {
      setSuccessMsg(`✓ Load ${newLoad.id} created successfully and posted to the board!`);
      setErrorMsg(null);
      queryClient.invalidateQueries({ queryKey: ['loads'] });
    },
    onError: (err: any) => {
      setErrorMsg(err.message || 'Failed to post load');
    }
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!currentUser) {
      onOpenAuth();
      return;
    }
    if (currentUser.role !== 'shipper' && currentUser.role !== 'admin') {
      alert('Only shipper or admin accounts can post loads. Please switch account role.');
      return;
    }

    setErrorMsg(null);
    setSuccessMsg(null);

    createLoadMutation.mutate({
      origin_city: originCity,
      origin_state: originState.toUpperCase(),
      dest_city: destCity,
      dest_state: destState.toUpperCase(),
      miles,
      rate_per_mile: ratePerMile,
      equipment_type: equipmentType,
      pickup_date: pickupDate,
      weight_lbs: weightLbs,
      same_day_funding_offered: sameDayFundingOffered,
      notes
    });
  };

  return (
    <div className="py-12">
      <div className="max-w-[1180px] mx-auto px-6">
        <span className="eyebrow block mb-1">Shipper Portal</span>
        <h2 className="text-2xl sm:text-3xl mb-2">Post a New Freight Load</h2>
        <p className="text-[#5B6168] mb-8">
          Enter lane details to calculate exact gross, platform fee, and carrier net take-home before posting.
        </p>

        {errorMsg && (
          <div className="p-3 bg-[#8C2F1B]/10 border border-[#8C2F1B] text-[#8C2F1B] rounded font-mono text-xs mb-6">
            {errorMsg}
          </div>
        )}

        {successMsg && (
          <div className="p-4 bg-[#0F5132]/10 border border-[#0F5132] text-[#0F5132] rounded font-mono text-sm mb-6">
            {successMsg}
          </div>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
          {/* Post Load Form */}
          <form onSubmit={handleSubmit} className="lg:col-span-7 bg-[#FAFAF7] border border-[#E4DCC4] rounded p-6 shadow-sm space-y-4">
            <h3 className="text-lg font-display-title mb-2">Lane Specifications</h3>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Origin City
                </label>
                <input
                  type="text"
                  required
                  placeholder="Dallas"
                  value={originCity}
                  onChange={(e) => setOriginCity(e.target.value)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm"
                />
              </div>
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Origin State (2-letter)
                </label>
                <input
                  type="text"
                  required
                  maxLength={2}
                  placeholder="TX"
                  value={originState}
                  onChange={(e) => setOriginState(e.target.value)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm uppercase"
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Destination City
                </label>
                <input
                  type="text"
                  required
                  placeholder="Atlanta"
                  value={destCity}
                  onChange={(e) => setDestCity(e.target.value)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm"
                />
              </div>
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Destination State (2-letter)
                </label>
                <input
                  type="text"
                  required
                  maxLength={2}
                  placeholder="GA"
                  value={destState}
                  onChange={(e) => setDestState(e.target.value)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm uppercase"
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Miles
                </label>
                <input
                  type="number"
                  required
                  value={miles}
                  onChange={(e) => setMiles(parseFloat(e.target.value) || 0)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm font-mono"
                />
              </div>
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Offered Rate ($ / Mile)
                </label>
                <input
                  type="number"
                  step="0.05"
                  required
                  value={ratePerMile}
                  onChange={(e) => setRatePerMile(parseFloat(e.target.value) || 0)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm font-mono"
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Equipment Needed
                </label>
                <select
                  value={equipmentType}
                  onChange={(e) => setEquipmentType(e.target.value as EquipmentType)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm"
                >
                  <option value="dry_van">Dry Van</option>
                  <option value="reefer">Reefer</option>
                  <option value="flatbed">Flatbed</option>
                  <option value="step_deck">Step Deck</option>
                  <option value="power_only">Power Only</option>
                </select>
              </div>
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Pickup Date
                </label>
                <input
                  type="date"
                  required
                  value={pickupDate}
                  onChange={(e) => setPickupDate(e.target.value)}
                  className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm font-mono"
                />
              </div>
            </div>

            <div>
              <label className="flex items-center gap-2 cursor-pointer font-mono text-xs pt-2">
                <input
                  type="checkbox"
                  checked={sameDayFundingOffered}
                  onChange={(e) => setSameDayFundingOffered(e.target.checked)}
                  className="w-4 h-4 accent-[#0F5132]"
                />
                <span>Offer Same-Day Quick Pay to Motor Carrier (+{(factorPct * 100)}%)</span>
              </label>
            </div>

            <div>
              <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                Commodity &amp; Special Handling Notes
              </label>
              <textarea
                rows={2}
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="26 pallets non-hazmat dry goods"
                className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm"
              />
            </div>

            <button
              type="submit"
              disabled={createLoadMutation.isPending}
              className="btn primary block w-full py-3 mt-4"
            >
              {createLoadMutation.isPending ? 'Publishing Load...' : 'Publish Load to Board'}
            </button>
          </form>

          {/* Live Fee Calculator Card */}
          <div className="lg:col-span-5 bg-[#14171A] text-[#FAFAF7] rounded p-6 shadow-md sticky top-24 border border-[#1E2226]">
            <span className="eyebrow on-dark block mb-1">Live Fee Calculator</span>
            <h3 className="text-xl font-display-title mb-4">Financial Breakdown</h3>

            <div className="space-y-3 font-mono text-xs border-y border-[#FAFAF7]/15 py-4">
              <div className="flex justify-between">
                <span>Gross Load Total ({miles} miles &times; ${ratePerMile}/mi):</span>
                <span className="font-bold">${grossAmount.toFixed(2)}</span>
              </div>
              <div className="flex justify-between text-[#E3A008]">
                <span>Platform Fee ({(feePct * 100).toFixed(0)}%):</span>
                <span>&minus;${feeAmount.toFixed(2)}</span>
              </div>
              {sameDayFundingOffered && (
                <div className="flex justify-between text-[#8C2F1B]">
                  <span>Same-Day Quick Pay ({(factorPct * 100).toFixed(0)}%):</span>
                  <span>&minus;${factorAmount.toFixed(2)}</span>
                </div>
              )}
              <div className="flex justify-between text-[#FAFAF7] font-bold text-sm pt-3 border-t border-dashed border-[#FAFAF7]/20">
                <span>Carrier Net Take-Home:</span>
                <span className="text-[#E3A008] text-base">${netTakeHome.toFixed(2)}</span>
              </div>
            </div>

            <div className="mt-4 text-[0.72rem] font-mono text-[#C9CDD1] leading-relaxed">
              * Rates and fee calculations are fetched directly from <code>/api/config</code>. All settlements publish publicly to Open Books upon delivery completion.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
