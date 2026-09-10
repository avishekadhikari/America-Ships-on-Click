-- Read models for dashboards and market data.
--
-- Aggregates are computed from the settlement rows themselves rather than kept
-- in counter columns, for the same reason the headline stats already are: a
-- counter drifts the first time a write is retried or rolled back, and a
-- ledger whose totals disagree with its rows is not a ledger.
--
-- Two of these views carry per-party money, so they are *self-scoping*: the
-- identity filter lives inside the view definition. A view is owned by the
-- schema owner and reads past Row-Level Security on its base tables, so a view
-- over earnings that did not filter would hand any signed-in carrier every
-- other carrier's income. The filter cannot be dropped by a careless route,
-- because the route never gets to write it.

-- ---------------------------------------------------------------------------
-- 1. CARRIER EARNINGS (self-scoping)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW driver_earnings_view AS
SELECT
  d.id                                              AS driver_id,
  d.full_name,
  COUNT(s.id)::INTEGER                              AS loads_settled,
  COALESCE(SUM(s.miles), 0)                         AS miles,
  COALESCE(SUM(s.gross_amount), 0)                  AS gross,
  COALESCE(SUM(s.fee_amount), 0)                    AS platform_fees,
  COALESCE(SUM(s.fuel_cost), 0)                     AS fuel,
  COALESCE(SUM(s.factor_cost), 0)                   AS quick_pay_cost,
  COALESCE(SUM(s.net_amount), 0)                    AS net,
  COALESCE(SUM(adj.total), 0)                       AS adjustments,
  COALESCE(SUM(s.net_amount), 0) + COALESCE(SUM(adj.total), 0) AS effective_net,
  CASE WHEN COALESCE(SUM(s.miles), 0) > 0
       THEN ROUND((SUM(s.net_amount) / SUM(s.miles))::NUMERIC, 4)
       ELSE 0 END                                   AS net_per_mile,
  CASE WHEN COALESCE(SUM(s.miles), 0) > 0
       THEN ROUND((SUM(s.gross_amount) / SUM(s.miles))::NUMERIC, 4)
       ELSE 0 END                                   AS gross_per_mile,
  MIN(s.settled_at)                                 AS first_settled_at,
  MAX(s.settled_at)                                 AS last_settled_at
FROM driver_profiles d
LEFT JOIN bookings b    ON b.driver_id = d.id AND b.status = 'completed'
LEFT JOIN settlements s ON s.booking_id = b.id
LEFT JOIN (
  SELECT settlement_id, SUM(amount) AS total FROM settlement_adjustments GROUP BY settlement_id
) adj ON adj.settlement_id = s.id
WHERE app_is_admin() OR d.id = app_current_driver_id()
GROUP BY d.id, d.full_name;

-- ---------------------------------------------------------------------------
-- 2. SHIPPER SPEND (self-scoping)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW shipper_spend_view AS
SELECT
  sp.id                                                          AS shipper_id,
  sp.company_name,
  COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'open')::INTEGER      AS loads_open,
  COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'booked')::INTEGER    AS loads_booked,
  COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'in_transit')::INTEGER AS loads_in_transit,
  COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'delivered')::INTEGER  AS loads_delivered,
  COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'cancelled')::INTEGER  AS loads_cancelled,
  COUNT(s.id)::INTEGER                                           AS loads_settled,
  COALESCE(SUM(s.gross_amount), 0)                               AS spend_gross,
  COALESCE(SUM(s.miles), 0)                                      AS miles,
  CASE WHEN COALESCE(SUM(s.miles), 0) > 0
       THEN ROUND((SUM(s.gross_amount) / SUM(s.miles))::NUMERIC, 4)
       ELSE 0 END                                                AS avg_rate_per_mile,
  MAX(s.settled_at)                                              AS last_settled_at
FROM shipper_profiles sp
LEFT JOIN loads l       ON l.shipper_id = sp.id
LEFT JOIN settlements s ON s.load_id = l.id
WHERE app_is_admin() OR sp.id = app_current_shipper_id()
GROUP BY sp.id, sp.company_name;

-- ---------------------------------------------------------------------------
-- 3. MARKET DATA (public)
-- ---------------------------------------------------------------------------
-- Aggregated lane pricing, derived from settled loads. This is the number a
-- carrier actually wants before accepting a rate, and publishing it is the
-- point of an open ledger. No party is identifiable: lanes with fewer than
-- three settlements are withheld, so a single shipper's pricing cannot be
-- reverse-engineered from a thin lane.

CREATE OR REPLACE VIEW lane_rate_stats_view AS
SELECT
  l.origin_state,
  l.dest_state,
  l.equipment_type,
  COUNT(*)::INTEGER                                     AS settlement_count,
  ROUND(AVG(s.rate_per_mile)::NUMERIC, 4)               AS avg_rate_per_mile,
  ROUND(MIN(s.rate_per_mile)::NUMERIC, 4)               AS min_rate_per_mile,
  ROUND(MAX(s.rate_per_mile)::NUMERIC, 4)               AS max_rate_per_mile,
  ROUND(
    percentile_cont(0.5) WITHIN GROUP (ORDER BY s.rate_per_mile)::NUMERIC, 4
  )                                                     AS median_rate_per_mile,
  ROUND(AVG(s.miles)::NUMERIC, 1)                       AS avg_miles,
  ROUND(AVG(s.net_amount)::NUMERIC, 2)                  AS avg_net_to_carrier,
  MAX(s.settled_at)                                     AS last_settled_at
FROM settlements s
JOIN loads l ON l.id = s.load_id
GROUP BY l.origin_state, l.dest_state, l.equipment_type
HAVING COUNT(*) >= 3;

CREATE OR REPLACE VIEW load_board_stats_view AS
SELECT
  COUNT(*) FILTER (WHERE status = 'open')::INTEGER       AS open_loads,
  COUNT(*) FILTER (WHERE status = 'booked')::INTEGER     AS booked_loads,
  COUNT(*) FILTER (WHERE status = 'in_transit')::INTEGER AS in_transit_loads,
  COUNT(*) FILTER (WHERE status = 'delivered')::INTEGER  AS delivered_loads,
  COUNT(*) FILTER (WHERE status = 'cancelled')::INTEGER  AS cancelled_loads,
  COALESCE(ROUND(AVG(rate_per_mile) FILTER (WHERE status = 'open')::NUMERIC, 4), 0)
                                                        AS avg_open_rate_per_mile,
  COALESCE(SUM(miles) FILTER (WHERE status = 'open'), 0) AS open_miles,
  COUNT(DISTINCT shipper_id)::INTEGER                    AS shippers_posting
FROM loads;

-- Delivery performance, computed from the timeline rather than self-reported.
CREATE OR REPLACE VIEW driver_performance_view AS
SELECT
  d.id                                                                  AS driver_id,
  COUNT(b.id)::INTEGER                                                  AS bookings_total,
  COUNT(b.id) FILTER (WHERE b.status = 'completed')::INTEGER            AS bookings_completed,
  COUNT(b.id) FILTER (WHERE b.status = 'cancelled')::INTEGER            AS bookings_cancelled,
  CASE WHEN COUNT(b.id) > 0
       THEN ROUND(
              (COUNT(b.id) FILTER (WHERE b.status = 'completed')::NUMERIC
               / COUNT(b.id)::NUMERIC) * 100, 1)
       ELSE NULL END                                                    AS completion_pct,
  ROUND(AVG(
    EXTRACT(EPOCH FROM (b.delivered_at - b.booked_at)) / 3600.0
  )::NUMERIC, 1)                                                        AS avg_hours_to_deliver
FROM driver_profiles d
LEFT JOIN bookings b ON b.driver_id = d.id
GROUP BY d.id;

GRANT SELECT ON driver_earnings_view, shipper_spend_view, lane_rate_stats_view,
                load_board_stats_view, driver_performance_view TO asoc_app;

-- ---------------------------------------------------------------------------
-- 4. SEARCH INDEXES
-- ---------------------------------------------------------------------------
-- The board filters city names case-insensitively with LIKE. Without a
-- matching functional index every keystroke in the search box is a sequential
-- scan of the whole table.

CREATE INDEX IF NOT EXISTS idx_loads_origin_city_lower ON loads (lower(origin_city));
CREATE INDEX IF NOT EXISTS idx_loads_dest_city_lower   ON loads (lower(dest_city));
CREATE INDEX IF NOT EXISTS idx_loads_rate              ON loads (rate_per_mile);
CREATE INDEX IF NOT EXISTS idx_loads_pickup_date       ON loads (pickup_date);
CREATE INDEX IF NOT EXISTS idx_loads_open_board        ON loads (created_at DESC) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_settlements_load        ON settlements (load_id);
