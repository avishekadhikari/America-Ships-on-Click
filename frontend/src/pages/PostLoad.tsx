import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '../lib/api';
import { EquipmentType, GeoPlace, User } from '../types/api';
import { pctLabel, settlementPreview, usd } from '../lib/settlementPreview';
import { LaneMap } from '../components/LaneMap';

interface PostLoadProps {
  currentUser: User | null;
  onOpenAuth: () => void;
  setActiveTab: (tab: string) => void;
}

function localISODate(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export const PostLoad: React.FC<PostLoadProps> = ({ currentUser, onOpenAuth, setActiveTab }) => {
  const queryClient = useQueryClient();

  const { data: config } = useQuery({
    queryKey: ['config'],
    queryFn: () => api.getConfig()
  });

  const [origin, setOrigin] = useState<GeoPlace | null>(null);
  const [dest, setDest] = useState<GeoPlace | null>(null);
  const [miles, setMiles] = useState<number>(0);
  const [ratePerMile, setRatePerMile] = useState<number>(2.15);
  const [equipmentType, setEquipmentType] = useState<EquipmentType>('dry_van');
  const [pickupDate, setPickupDate] = useState<string>(localISODate);
  const [weightLbs, setWeightLbs] = useState<number>(42000);
  const [sameDayFundingOffered, setSameDayFundingOffered] = useState<boolean>(false);
  const [notes, setNotes] = useState<string>('Palletized freight, clean trailer');

  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  const preview = settlementPreview(miles, ratePerMile, config, {
    factored: sameDayFundingOffered
  });

  const createLoadMutation = useMutation({
    mutationFn: (data: Parameters<typeof api.createLoad>[0]) => api.createLoad(data),
    onSuccess: (newLoad) => {
      setSuccessMsg(`Load ${newLoad.id} posted to the board.`);
      setErrorMsg(null);
      queryClient.invalidateQueries({ queryKey: ['loads'] });
      setTimeout(() => setActiveTab('dashboard'), 700);
    },
    onError: (err: Error) => {
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

    if (!origin || !dest) {
      setErrorMsg('Drop pickup and destination on the map, or search both cities.');
      return;
    }
    if (!miles || miles < 1) {
      setErrorMsg('Need a lane distance before posting.');
      return;
    }

    setErrorMsg(null);
    setSuccessMsg(null);

    createLoadMutation.mutate({
      origin_city: origin.city,
      origin_state: origin.state.toUpperCase(),
      dest_city: dest.city,
      dest_state: dest.state.toUpperCase(),
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
          Drop pickup and destination on the map. Miles come from the driving route; the calculator uses the same gross, fee, modeled fuel, and ledger net Open Books will publish.
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
          <form onSubmit={handleSubmit} className="lg:col-span-7 bg-[#FAFAF7] border border-[#E4DCC4] rounded p-6 shadow-sm space-y-4">
            <h3 className="text-lg font-display-title mb-2">Lane Specifications</h3>

            <LaneMap
              origin={origin}
              dest={dest}
              onOriginChange={setOrigin}
              onDestChange={setDest}
              onMilesChange={setMiles}
            />

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                  Miles
                </label>
                <input
                  type="number"
                  required
                  min={1}
                  value={miles || ''}
                  onChange={(e) => setMiles(parseFloat(e.target.value) || 0)}
                  placeholder="From map"
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
              <label className="block text-xs font-mono font-bold uppercase text-[#5B6168] mb-1">
                Weight (lbs)
              </label>
              <input
                type="number"
                min={1}
                value={weightLbs}
                onChange={(e) => setWeightLbs(parseFloat(e.target.value) || 0)}
                className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm font-mono"
              />
            </div>

            <div>
              <label className="flex items-center gap-2 cursor-pointer font-mono text-xs pt-2">
                <input
                  type="checkbox"
                  checked={sameDayFundingOffered}
                  onChange={(e) => setSameDayFundingOffered(e.target.checked)}
                  className="w-4 h-4 accent-[#0F5132]"
                />
                <span>Offer Same-Day Quick Pay to Motor Carrier (+{pctLabel(preview.factorPct)})</span>
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

          <div className="lg:col-span-5 bg-[#14171A] text-[#FAFAF7] rounded p-6 shadow-md sticky top-24 border border-[#1E2226]">
            <span className="eyebrow on-dark block mb-1">Live Fee Calculator</span>
            <h3 className="text-xl font-display-title mb-4">Financial Breakdown</h3>

            <div className="space-y-3 font-mono text-xs border-y border-[#FAFAF7]/15 py-4">
              <div className="flex justify-between">
                <span>Gross ({preview.miles} mi &times; ${preview.ratePerMile}/mi):</span>
                <span className="font-bold">{usd(preview.gross)}</span>
              </div>
              <div className="flex justify-between text-[#E3A008]">
                <span>Platform fee ({pctLabel(preview.feePct)}):</span>
                <span>&minus;{usd(preview.fee)}</span>
              </div>
              <div className="flex justify-between text-[#C9CDD1]">
                <span>Modeled fuel (${preview.fuelRate.toFixed(2)}/mi):</span>
                <span>&minus;{usd(preview.fuel)}</span>
              </div>
              {sameDayFundingOffered && (
                <div className="flex justify-between text-[#8C2F1B]">
                  <span>Same-day quick pay ({pctLabel(preview.factorPct)}):</span>
                  <span>&minus;{usd(preview.factor)}</span>
                </div>
              )}
              <div className="flex justify-between text-[#FAFAF7] font-bold text-sm pt-3 border-t border-dashed border-[#FAFAF7]/20">
                <span>Ledger net:</span>
                <span className="text-[#E3A008] text-base">{usd(preview.net)}</span>
              </div>
            </div>

            <div className="mt-4 text-[0.78rem] font-mono text-[#C9CDD1] leading-relaxed">
              Same arithmetic as settlement. Fuel is a modeled lane cost at the platform rate, copied onto the ledger row when the haul completes.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
