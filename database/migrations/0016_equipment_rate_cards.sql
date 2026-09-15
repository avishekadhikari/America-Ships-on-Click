-- Equipment rate cards, diesel index, accessorials, and accepted-quote log.
--
-- loads.equipment_type was a five-value enum. The quote table is keyed by a
-- richer set (cargo van through permitted heavy haul), so the enum becomes
-- TEXT with a foreign key into this lookup. Existing dry_van / reefer /
-- flatbed / step_deck / power_only rows keep working.
--
-- Quote math (database/quote.ts) reads these rows:
--   linehaul = max(miles × base, distance minimum)
--   + deadhead buffer
--   + diesel-moving fuel surcharge
--   + accessorials (tarp, permits, escort)
--   × demand multiplier
--   × express surcharge when flagged
--   × 1.07 gross
--   then the minimum again, so a short load cannot go negative.
--
-- The 7% is the shipper quote adder. Open Books still takes 5% of posted gross.

INSERT INTO platform_config (key, value) VALUES
  ('quote_gross_pct', 0.07),
  ('diesel_base_ppg', 3.50),
  ('default_demand_multiplier', 1.00),
  ('default_express_surcharge_pct', 0.15)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 1. RATE CARDS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS equipment_rate_cards (
  equipment_key                 TEXT PRIMARY KEY,
  label                         TEXT NOT NULL,
  cdl_required                  BOOLEAN NOT NULL DEFAULT FALSE,
  rate_min_per_mile             NUMERIC NOT NULL CHECK (rate_min_per_mile > 0),
  rate_max_per_mile             NUMERIC NOT NULL CHECK (rate_max_per_mile >= rate_min_per_mile),
  base_rate_per_mile            NUMERIC NOT NULL CHECK (base_rate_per_mile > 0),
  short_haul_under_miles        NUMERIC CHECK (short_haul_under_miles IS NULL OR short_haul_under_miles > 0),
  short_haul_rate_min_per_mile  NUMERIC CHECK (short_haul_rate_min_per_mile IS NULL OR short_haul_rate_min_per_mile > 0),
  short_haul_rate_max_per_mile  NUMERIC CHECK (short_haul_rate_max_per_mile IS NULL OR short_haul_rate_max_per_mile > 0),
  short_haul_base_rate_per_mile NUMERIC CHECK (short_haul_base_rate_per_mile IS NULL OR short_haul_base_rate_per_mile > 0),
  minimum_charge                NUMERIC NOT NULL CHECK (minimum_charge >= 0),
  short_haul_minimum_charge     NUMERIC CHECK (short_haul_minimum_charge IS NULL OR short_haul_minimum_charge >= 0),
  deadhead_buffer_pct           NUMERIC NOT NULL DEFAULT 0.10 CHECK (deadhead_buffer_pct >= 0 AND deadhead_buffer_pct <= 1),
  fuel_mpg                      NUMERIC NOT NULL CHECK (fuel_mpg > 0),
  express_surcharge_pct         NUMERIC NOT NULL DEFAULT 0.15 CHECK (express_surcharge_pct >= 0 AND express_surcharge_pct <= 1),
  sort_order                    INTEGER NOT NULL,
  updated_at                    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    base_rate_per_mile BETWEEN rate_min_per_mile AND rate_max_per_mile
  )
);

INSERT INTO equipment_rate_cards (
  equipment_key, label, cdl_required,
  rate_min_per_mile, rate_max_per_mile, base_rate_per_mile,
  short_haul_under_miles, short_haul_rate_min_per_mile, short_haul_rate_max_per_mile,
  short_haul_base_rate_per_mile, minimum_charge, short_haul_minimum_charge,
  deadhead_buffer_pct, fuel_mpg, express_surcharge_pct, sort_order
) VALUES
  ('cargo_van', 'Cargo van / Sprinter', FALSE,
    1.20, 1.80, 1.50,
    100, NULL, NULL, NULL, 200, 200,
    0.10, 14.0, 0.15, 10),
  ('bumper_pull', 'Bumper pull (non-CDL)', FALSE,
    1.50, 2.25, 1.88,
    NULL, NULL, NULL, NULL, 250, NULL,
    0.10, 12.0, 0.15, 20),
  ('gooseneck_hotshot', 'Gooseneck hotshot (non-CDL)', FALSE,
    1.70, 2.00, 1.85,
    NULL, NULL, NULL, NULL, 300, NULL,
    0.10, 10.0, 0.15, 30),
  ('gooseneck_cdl_40', 'CDL gooseneck 40-foot', TRUE,
    2.20, 2.80, 2.50,
    NULL, NULL, NULL, NULL, 400, NULL,
    0.10, 8.5, 0.15, 40),
  ('gooseneck_specialized', 'Specialized gooseneck', TRUE,
    3.00, 5.00, 4.00,
    NULL, NULL, NULL, NULL, 750, NULL,
    0.12, 7.5, 0.15, 50),
  ('car_carrier', 'Car carrier / auto transport', TRUE,
    0.50, 1.60, 1.05,
    500, 1.00, 1.60, 1.30, 400, 500,
    0.10, 7.0, 0.15, 60),
  ('flatbed', 'Flatbed', TRUE,
    2.50, 3.10, 2.80,
    NULL, NULL, NULL, NULL, 500, NULL,
    0.10, 6.5, 0.15, 70),
  ('oversize_legal', 'Oversize / heavy haul (legal)', TRUE,
    3.50, 8.00, 5.75,
    NULL, NULL, NULL, NULL, 1200, NULL,
    0.15, 5.5, 0.15, 80),
  ('oversize_permitted', 'Oversize / heavy haul (permits & escorts)', TRUE,
    5.00, 15.00, 10.00,
    NULL, NULL, NULL, NULL, 2500, NULL,
    0.20, 5.0, 0.20, 90),
  ('dry_van', 'Dry van semi', TRUE,
    1.85, 2.50, 2.18,
    NULL, NULL, NULL, NULL, 450, NULL,
    0.10, 6.5, 0.15, 100),
  ('reefer', 'Reefer', TRUE,
    2.05, 2.90, 2.48,
    NULL, NULL, NULL, NULL, 500, NULL,
    0.10, 6.2, 0.15, 110),
  ('step_deck', 'Step deck', TRUE,
    2.80, 3.50, 3.15,
    NULL, NULL, NULL, NULL, 600, NULL,
    0.12, 6.3, 0.15, 120),
  ('power_only', 'Power only', TRUE,
    1.70, 2.40, 2.05,
    NULL, NULL, NULL, NULL, 400, NULL,
    0.10, 7.0, 0.15, 130)
ON CONFLICT (equipment_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. SWITCH LOADS / DRIVER EQUIPMENT OFF THE ENUM
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS lane_rate_stats_view;
DROP VIEW IF EXISTS settlement_effective_view;
DROP VIEW IF EXISTS public_ledger_view;

ALTER TABLE loads ALTER COLUMN equipment_type DROP DEFAULT;
ALTER TABLE driver_equipment ALTER COLUMN equipment_type DROP DEFAULT;

ALTER TABLE loads ALTER COLUMN equipment_type TYPE TEXT USING equipment_type::TEXT;
ALTER TABLE driver_equipment ALTER COLUMN equipment_type TYPE TEXT USING equipment_type::TEXT;

ALTER TABLE loads ALTER COLUMN equipment_type SET DEFAULT 'dry_van';
ALTER TABLE driver_equipment ALTER COLUMN equipment_type SET DEFAULT 'dry_van';

ALTER TABLE loads
  ADD CONSTRAINT loads_equipment_fk
  FOREIGN KEY (equipment_type) REFERENCES equipment_rate_cards(equipment_key)
  ON DELETE RESTRICT;

ALTER TABLE driver_equipment
  ADD CONSTRAINT driver_equipment_equipment_fk
  FOREIGN KEY (equipment_type) REFERENCES equipment_rate_cards(equipment_key)
  ON DELETE RESTRICT;

DROP TYPE IF EXISTS equipment_type;

CREATE OR REPLACE VIEW public_ledger_view AS
SELECT
  s.id, s.load_id,
  l.origin_city, l.origin_state, l.dest_city, l.dest_state, l.equipment_type,
  s.miles, s.rate_per_mile, s.fuel_rate_per_mile,
  s.gross_amount, s.fee_amount, s.fee_pct_applied, s.fuel_cost, s.factor_cost,
  s.factored, s.net_amount, s.settled_at
FROM settlements s
JOIN loads l ON s.load_id = l.id
ORDER BY s.settled_at DESC;

CREATE OR REPLACE VIEW settlement_effective_view AS
SELECT
  s.id, s.load_id, s.booking_id,
  l.origin_city, l.origin_state, l.dest_city, l.dest_state, l.equipment_type,
  s.miles, s.rate_per_mile, s.fuel_rate_per_mile,
  s.gross_amount, s.fee_amount, s.fee_pct_applied, s.fuel_cost, s.factor_cost,
  s.factored,
  s.net_amount AS original_net_amount,
  COALESCE(adj.total, 0) AS adjustment_total,
  s.net_amount + COALESCE(adj.total, 0) AS effective_net_amount,
  COALESCE(adj.count, 0)::INTEGER AS adjustment_count,
  COALESCE(dsp.open_count, 0)::INTEGER AS open_dispute_count,
  s.settled_at
FROM settlements s
JOIN loads l ON l.id = s.load_id
LEFT JOIN (
  SELECT settlement_id, SUM(amount) AS total, COUNT(*) AS count
  FROM settlement_adjustments GROUP BY settlement_id
) adj ON adj.settlement_id = s.id
LEFT JOIN (
  SELECT settlement_id, COUNT(*) AS open_count
  FROM settlement_disputes WHERE status IN ('open', 'under_review')
  GROUP BY settlement_id
) dsp ON dsp.settlement_id = s.id;

CREATE OR REPLACE VIEW lane_rate_stats_view AS
SELECT
  l.origin_state, l.dest_state, l.equipment_type,
  COUNT(*)::INTEGER AS settlement_count,
  ROUND(AVG(s.rate_per_mile)::NUMERIC, 4) AS avg_rate_per_mile,
  ROUND(MIN(s.rate_per_mile)::NUMERIC, 4) AS min_rate_per_mile,
  ROUND(MAX(s.rate_per_mile)::NUMERIC, 4) AS max_rate_per_mile,
  ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY s.rate_per_mile)::NUMERIC, 4)
    AS median_rate_per_mile,
  ROUND(AVG(s.miles)::NUMERIC, 1) AS avg_miles,
  ROUND(AVG(s.net_amount)::NUMERIC, 2) AS avg_net_to_carrier,
  MAX(s.settled_at) AS last_settled_at
FROM settlements s
JOIN loads l ON l.id = s.load_id
GROUP BY l.origin_state, l.dest_state, l.equipment_type
HAVING COUNT(*) >= 3;

GRANT SELECT ON public_ledger_view, settlement_effective_view, lane_rate_stats_view TO asoc_app;

-- ---------------------------------------------------------------------------
-- 3. DIESEL INDEX
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS diesel_prices (
  id          TEXT PRIMARY KEY,
  dollars_per_gallon NUMERIC NOT NULL CHECK (dollars_per_gallon > 0 AND dollars_per_gallon < 20),
  source      TEXT NOT NULL DEFAULT 'admin' CHECK (char_length(source) BETWEEN 1 AND 40),
  effective_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  recorded_by TEXT
);

CREATE INDEX IF NOT EXISTS idx_diesel_prices_effective
  ON diesel_prices (effective_at DESC);

INSERT INTO diesel_prices (id, dollars_per_gallon, source, recorded_by)
VALUES ('dsl-seed', 3.82, 'seed', 'seed')
ON CONFLICT DO NOTHING;

DROP TRIGGER IF EXISTS diesel_prices_append_only ON diesel_prices;
CREATE TRIGGER diesel_prices_append_only BEFORE UPDATE OR DELETE ON diesel_prices
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---------------------------------------------------------------------------
-- 4. ACCESSORIALS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS accessorial_fees (
  code        TEXT PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  label       TEXT NOT NULL,
  amount      NUMERIC NOT NULL CHECK (amount >= 0),
  description TEXT,
  updated_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO accessorial_fees (code, label, amount, description) VALUES
  ('tarp', 'Tarping', 75, 'Tarp kit / labor for open equipment'),
  ('permits', 'Permits', 150, 'Oversize or overweight permit packet'),
  ('escort', 'Pilot / escort', 350, 'Escort vehicle once permits kick in')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. ACCEPTED QUOTE LOG
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rate_quotes (
  id                    TEXT PRIMARY KEY,
  equipment_key         TEXT NOT NULL REFERENCES equipment_rate_cards(equipment_key) ON DELETE RESTRICT,
  load_id               TEXT REFERENCES loads(id) ON DELETE RESTRICT,
  miles                 NUMERIC NOT NULL CHECK (miles > 0),
  deadhead_miles        NUMERIC NOT NULL DEFAULT 0 CHECK (deadhead_miles >= 0),
  demand_multiplier     NUMERIC NOT NULL CHECK (demand_multiplier > 0),
  express               BOOLEAN NOT NULL DEFAULT FALSE,
  diesel_ppg            NUMERIC NOT NULL,
  breakdown             JSONB NOT NULL,
  quoted_total          NUMERIC NOT NULL CHECK (quoted_total >= 0),
  quoted_rate_per_mile  NUMERIC NOT NULL CHECK (quoted_rate_per_mile > 0),
  overridden            BOOLEAN NOT NULL DEFAULT FALSE,
  posted_rate_per_mile  NUMERIC NOT NULL CHECK (posted_rate_per_mile > 0),
  actor_id              TEXT,
  created_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_rate_quotes_created ON rate_quotes (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rate_quotes_equipment ON rate_quotes (equipment_key, created_at DESC);

DROP TRIGGER IF EXISTS rate_quotes_append_only ON rate_quotes;
CREATE TRIGGER rate_quotes_append_only BEFORE UPDATE OR DELETE ON rate_quotes
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS audit_equipment_rate_cards ON equipment_rate_cards;
CREATE TRIGGER audit_equipment_rate_cards AFTER INSERT OR UPDATE OR DELETE ON equipment_rate_cards
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_accessorial_fees ON accessorial_fees;
CREATE TRIGGER audit_accessorial_fees AFTER INSERT OR UPDATE OR DELETE ON accessorial_fees
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_rate_quotes ON rate_quotes;
CREATE TRIGGER audit_rate_quotes AFTER INSERT OR UPDATE OR DELETE ON rate_quotes
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

CREATE OR REPLACE FUNCTION equipment_rate_cards_touch() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  IF NEW.base_rate_per_mile < NEW.rate_min_per_mile
     OR NEW.base_rate_per_mile > NEW.rate_max_per_mile THEN
    RAISE EXCEPTION 'Base rate must sit inside the published band'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS equipment_rate_cards_touch_trg ON equipment_rate_cards;
CREATE TRIGGER equipment_rate_cards_touch_trg BEFORE UPDATE ON equipment_rate_cards
  FOR EACH ROW EXECUTE FUNCTION equipment_rate_cards_touch();

-- ---------------------------------------------------------------------------
-- 6. GRANTS + RLS
-- ---------------------------------------------------------------------------

GRANT SELECT ON equipment_rate_cards, diesel_prices, accessorial_fees, rate_quotes TO asoc_app;
GRANT UPDATE ON equipment_rate_cards, accessorial_fees TO asoc_app;
GRANT INSERT ON diesel_prices, rate_quotes TO asoc_app;

ALTER TABLE equipment_rate_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE diesel_prices        ENABLE ROW LEVEL SECURITY;
ALTER TABLE accessorial_fees     ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_quotes          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS equipment_rate_cards_select ON equipment_rate_cards;
CREATE POLICY equipment_rate_cards_select ON equipment_rate_cards FOR SELECT USING (true);
DROP POLICY IF EXISTS equipment_rate_cards_update ON equipment_rate_cards;
CREATE POLICY equipment_rate_cards_update ON equipment_rate_cards FOR UPDATE
  USING (app_is_admin()) WITH CHECK (app_is_admin());

DROP POLICY IF EXISTS diesel_prices_select ON diesel_prices;
CREATE POLICY diesel_prices_select ON diesel_prices FOR SELECT USING (true);
DROP POLICY IF EXISTS diesel_prices_insert ON diesel_prices;
CREATE POLICY diesel_prices_insert ON diesel_prices FOR INSERT WITH CHECK (app_is_admin());

DROP POLICY IF EXISTS accessorial_fees_select ON accessorial_fees;
CREATE POLICY accessorial_fees_select ON accessorial_fees FOR SELECT USING (true);
DROP POLICY IF EXISTS accessorial_fees_update ON accessorial_fees;
CREATE POLICY accessorial_fees_update ON accessorial_fees FOR UPDATE
  USING (app_is_admin()) WITH CHECK (app_is_admin());

DROP POLICY IF EXISTS rate_quotes_select ON rate_quotes;
CREATE POLICY rate_quotes_select ON rate_quotes FOR SELECT USING (
  app_is_admin() OR actor_id = app_current_user_id()
);
DROP POLICY IF EXISTS rate_quotes_insert ON rate_quotes;
CREATE POLICY rate_quotes_insert ON rate_quotes FOR INSERT WITH CHECK (
  app_is_admin() OR actor_id = app_current_user_id()
);
