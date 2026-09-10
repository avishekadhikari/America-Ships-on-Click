import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '../lib/api';
import { User } from '../types/api';

interface DashboardProps {
  currentUser: User | null;
  onOpenAuth: () => void;
}

export const Dashboard: React.FC<DashboardProps> = ({ currentUser, onOpenAuth }) => {
  const queryClient = useQueryClient();
  const [podInput, setPodInput] = useState<Record<string, string>>({});

  // Fetch admin/detailed ledger if logged in
  const { data: adminLedger = [], isLoading: isLoadingAdmin } = useQuery({
    queryKey: ['adminLedger'],
    queryFn: () => api.getAdminLedger(),
    enabled: !!currentUser && currentUser.role === 'admin'
  });

  // Fetch public/standard settlements
  const { data: settlements = [], isLoading: isLoadingSettlements } = useQuery({
    queryKey: ['settlements'],
    queryFn: () => api.getSettlements(50, 1),
    enabled: !!currentUser
  });

  // Fetch active bookings/loads for drivers/shippers
  const { data: activeLoads = [] } = useQuery({
    queryKey: ['loads', 'active'],
    queryFn: () => api.getLoads({ status: 'booked' }),
    enabled: !!currentUser
  });

  // Complete booking mutation (triggers settlement)
  const completeBookingMutation = useMutation({
    mutationFn: (bookingId: string) => api.completeBooking(bookingId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['settlements'] });
      queryClient.invalidateQueries({ queryKey: ['adminLedger'] });
      queryClient.invalidateQueries({ queryKey: ['loads'] });
      alert('✓ Booking completed and settlement posted to Open Books!');
    },
    onError: (err: any) => {
      alert(`Completion failed: ${err.message}`);
    }
  });

  // If unauthenticated, render Auth-Gated Notice
  if (!currentUser) {
    return (
      <div className="py-16">
        <div className="max-w-[640px] mx-auto px-6 text-center">
          <div className="p-8 bg-[#FAFAF7] border-2 border-[#E3A008] rounded shadow-md space-y-4">
            <span className="eyebrow block">Protected Area</span>
            <h2 className="text-2xl font-display-title text-[#14171A]">
              Authentication Required
            </h2>
            <p className="text-[#5B6168] text-sm">
              The owner dashboard contains driver and shipper activity, active bookings, and CSV export tools. Please sign in to access your dashboard.
            </p>
            <button
              onClick={onOpenAuth}
              className="btn amber px-8 py-3 font-mono"
            >
              Sign In or Select Demo Account
            </button>
          </div>
        </div>
      </div>
    );
  }

  const handleExportCSV = () => {
    window.location.href = api.getAdminExportUrl();
  };

  return (
    <div className="py-12">
      <div className="max-w-[1180px] mx-auto px-6">
        <div className="flex flex-wrap justify-between items-center gap-4 mb-6">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <span className="eyebrow">Owner Dashboard</span>
              <span className="font-mono text-xs bg-[#0F5132] text-[#FAFAF7] px-2 py-0.5 rounded font-bold uppercase">
                {currentUser.role} ROLE
              </span>
            </div>
            <h2 className="text-2xl sm:text-3xl">Settlement &amp; Activity Ledger</h2>
          </div>

          <div className="flex items-center gap-3">
            {currentUser.role === 'admin' && (
              <button onClick={handleExportCSV} className="btn ghost py-2 text-xs">
                Export Ledger CSV
              </button>
            )}
            <button onClick={onOpenAuth} className="btn amber py-2 text-xs">
              Switch Role
            </button>
          </div>
        </div>

        {/* ADMIN DETAILED LEDGER */}
        {currentUser.role === 'admin' ? (
          <div className="space-y-6">
            <div className="p-3 bg-[#0F5132]/10 border border-[#0F5132] text-[#0F5132] rounded font-mono text-xs">
              <strong>Admin Mode:</strong> Displaying full financial breakdown including internal driver identities, CDL numbers, and shipper company profiles.
            </div>

            <div className="ledger-table-wrap">
              <table className="ledger">
                <thead>
                  <tr>
                    <th>Settlement ID</th>
                    <th>Route</th>
                    <th>Driver Name</th>
                    <th>Shipper Company</th>
                    <th>Gross Rate</th>
                    <th>Fee (5%)</th>
                    <th>Net Amount</th>
                    <th>Settled Date</th>
                  </tr>
                </thead>
                <tbody>
                  {isLoadingAdmin ? (
                    <tr>
                      <td colSpan={8} className="text-center py-6 font-mono text-[#5B6168]">
                        Loading admin ledger...
                      </td>
                    </tr>
                  ) : adminLedger.length === 0 ? (
                    <tr>
                      <td colSpan={8} className="text-center py-6 font-mono text-[#5B6168]">
                        No settlements found.
                      </td>
                    </tr>
                  ) : (
                    adminLedger.map((item: any) => (
                      <tr key={item.id}>
                        <td className="font-bold text-[#5B6168]">{item.id}</td>
                        <td className="font-bold">
                          {item.origin_city}, {item.origin_state} &rarr; {item.dest_city}, {item.dest_state}
                        </td>
                        <td>{item.driver_name || 'Driver'}</td>
                        <td>{item.shipper_name || 'Shipper'}</td>
                        <td>${Number(item.gross_amount).toFixed(2)}</td>
                        <td className="text-[#5B3D00]">${Number(item.fee_amount).toFixed(2)}</td>
                        <td className="text-[#0F5132] font-bold">${Number(item.net_amount).toFixed(2)}</td>
                        <td>{new Date(item.settled_at).toLocaleDateString()}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </div>
        ) : (
          /* DRIVER & SHIPPER VIEW */
          <div className="space-y-8">
            {/* Active Bookings Action Section */}
            {activeLoads.length > 0 && (
              <div className="bg-[#FAFAF7] border border-[#E4DCC4] rounded p-5 shadow-sm space-y-4">
                <span className="eyebrow block">Active In-Transit Loads</span>
                <h3 className="text-lg font-display-title">Complete Delivery &amp; Settle</h3>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  {activeLoads.map((load) => (
                    <div key={'active-' + load.id} className="p-4 bg-[#F0EAD8] border border-[#E4DCC4] rounded space-y-2 font-mono text-xs">
                      <div className="font-bold text-sm text-[#14171A]">
                        {load.id} · {load.origin_city}, {load.origin_state} &rarr; {load.dest_city}, {load.dest_state}
                      </div>
                      <div>Miles: {Number(load.miles)} · Rate: ${Number(load.rate_per_mile).toFixed(2)}/mi</div>
                      <div>Gross: ${(Number(load.miles) * Number(load.rate_per_mile)).toFixed(2)}</div>

                      <div className="pt-2 border-t border-[#E4DCC4] flex gap-2">
                        <button
                          onClick={() => {
                            // Demo booking completion helper
                            const demoBookingId = 'BK-HIST-0001';
                            completeBookingMutation.mutate(demoBookingId);
                          }}
                          className="btn primary py-1.5 px-3 text-xs"
                        >
                          Trigger Settlement
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Standard Settlement Table */}
            <div>
              <h3 className="text-lg font-display-title mb-3">Settled Transaction Ledger</h3>
              <div className="ledger-table-wrap">
                <table className="ledger">
                  <thead>
                    <tr>
                      <th>Route</th>
                      <th>Miles</th>
                      <th>Rate / mi</th>
                      <th>Fee</th>
                      <th>Net to Carrier</th>
                    </tr>
                  </thead>
                  <tbody>
                    {isLoadingSettlements ? (
                      <tr>
                        <td colSpan={5} className="text-center py-6 font-mono text-[#5B6168]">
                          Loading settlements...
                        </td>
                      </tr>
                    ) : (
                      settlements.map((s) => (
                        <tr key={s.id}>
                          <td className="font-bold">
                            {s.origin_city}, {s.origin_state} &rarr; {s.dest_city}, {s.dest_state}
                          </td>
                          <td>{Number(s.miles).toLocaleString()}</td>
                          <td>${Number(s.rate_per_mile).toFixed(2)}</td>
                          <td className="text-[#5B3D00]">${Number(s.fee_amount).toFixed(2)}</td>
                          <td className="text-[#0F5132] font-bold">${Number(s.net_amount).toFixed(2)}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
