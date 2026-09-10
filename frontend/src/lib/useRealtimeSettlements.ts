import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { PublicLedgerItem } from '../types/api';

export function useRealtimeSettlements() {
  const queryClient = useQueryClient();
  const [latestEvent, setLatestEvent] = useState<PublicLedgerItem | null>(null);
  const [isConnected, setIsConnected] = useState(false);

  useEffect(() => {
    const eventSource = new EventSource('/api/realtime/stream');

    eventSource.onopen = () => {
      setIsConnected(true);
    };

    eventSource.onmessage = (event) => {
      try {
        const payload = JSON.parse(event.data);
        if (payload.type === 'settlement_created' && payload.data) {
          const newSettlement: PublicLedgerItem = payload.data;
          setLatestEvent(newSettlement);

          // Update TanStack Query cache for settlements & aggregates automatically
          queryClient.setQueryData<PublicLedgerItem[]>(['settlements'], (old = []) => {
            return [newSettlement, ...old];
          });

          queryClient.invalidateQueries({ queryKey: ['settlementTotals'] });
        }
      } catch (err) {
        console.error('SSE Message Error:', err);
      }
    };

    eventSource.onerror = () => {
      setIsConnected(false);
    };

    return () => {
      eventSource.close();
    };
  }, [queryClient]);

  return { latestEvent, isConnected };
}
