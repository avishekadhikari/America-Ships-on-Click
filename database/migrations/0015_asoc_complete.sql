-- America Ships On Click — complete the data model for the locked spec.
--
-- Migrations 0001–0014 already cover the freight marketplace, Open Books,
-- identity, offers, reputation, disputes, analytics, and the VVIP list.
-- This file adds what those did not: the on-chain index (Phase 1), the
-- holder-reward economics, the USDC driver-payout pipe, and the Phase 2
-- haul-receipt shape so a delivered load can one day write plate + reserve
-- on the same receipt without another redesign.
--
-- Spec (locked 2026-09-10), encoded here as constraints rather than comments:
--
--   * Regular holders: weight 1. Premium app subscribers: weight 5 INSTEAD
--     of 1. Never stacked.
--   * Premium is attested from a paid app membership. No burn.
--   * Buy-in required. No minimum purchase (amount must only be > 0).
--   * 30-day sell/cash-out lock after each buy. Rewards still accrue.
--   * Holder rewards are funded only by 7% of the 10% transaction reserve
--     (0.7% of volume). Claims that exceed the slice are haircut pro-rata.
--   * Driver payouts are a separate pipe: USDC on Base (chain id 8453) only.
--   * Phase 2 public haul ledger: plate, load id, miles, rate, reserve.
--     The table exists; nothing writes it yet.
--
-- The 5% Open Books platform fee is unchanged. Reserve accounting is a
-- parallel pipe, not a rewrite of settlements.

-- ---------------------------------------------------------------------------
-- 0. CONFIG
-- ---------------------------------------------------------------------------

INSERT INTO platform_config (key, value) VALUES
  ('reserve_pct', 0.10),
  ('holder_slice_of_reserve', 0.07),
  ('regular_weight', 1),
  ('premium_weight', 5),
  ('sell_lock_days', 30),
  ('base_chain_id', 8453)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION app_config_num(p_key TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT value FROM platform_config WHERE key = p_key
$$;

CREATE OR REPLACE FUNCTION app_is_webhook() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT app_current_role() IN ('webhook', 'admin')
$$;

GRANT EXECUTE ON FUNCTION app_config_num(TEXT), app_is_webhook() TO asoc_app;

-- ---------------------------------------------------------------------------
-- 1. LANE GEOGRAPHY (Post Load map already geocodes; persist the pins)
-- ---------------------------------------------------------------------------

ALTER TABLE loads ADD COLUMN IF NOT EXISTS origin_lat NUMERIC;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS origin_lng NUMERIC;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS dest_lat   NUMERIC;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS dest_lng   NUMERIC;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_origin_lat_range
    CHECK (origin_lat IS NULL OR origin_lat BETWEEN -90 AND 90);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_origin_lng_range
    CHECK (origin_lng IS NULL OR origin_lng BETWEEN -180 AND 180);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_dest_lat_range
    CHECK (dest_lat IS NULL OR dest_lat BETWEEN -90 AND 90);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_dest_lng_range
    CHECK (dest_lng IS NULL OR dest_lng BETWEEN -180 AND 180);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 2. CHAIN REGISTRY AND WALLETS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chain_contracts (
  id         TEXT PRIMARY KEY,
  chain_id   INTEGER NOT NULL CHECK (chain_id = 8453),
  name       TEXT NOT NULL CHECK (name IN ('asoc_token', 'usdc', 'payout_relayer')),
  address    TEXT NOT NULL CHECK (address ~ '^0x[0-9a-fA-F]{40}$'),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (chain_id, name)
);

-- Known public USDC on Base. The ASOC token address is written when the
-- contract is deployed — do not invent one here.
INSERT INTO chain_contracts (id, chain_id, name, address) VALUES
  ('cc-usdc-base', 8453, 'usdc', '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913')
ON CONFLICT (chain_id, name) DO NOTHING;

CREATE TABLE IF NOT EXISTS wallets (
  id         TEXT PRIMARY KEY,
  user_id    TEXT REFERENCES users(id) ON DELETE RESTRICT,
  chain_id   INTEGER NOT NULL DEFAULT 8453 CHECK (chain_id = 8453),
  address    TEXT NOT NULL CHECK (address ~ '^0x[0-9a-fA-F]{40}$'),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  linked_at  TIMESTAMP WITH TIME ZONE,
  UNIQUE (chain_id, address)
);

CREATE INDEX IF NOT EXISTS idx_wallets_user ON wallets (user_id) WHERE user_id IS NOT NULL;

-- A wallet may exist before an account (on-chain first). Linking it to a
-- user is an authenticated write on that user's own row.
CREATE OR REPLACE FUNCTION wallets_link_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.address IS DISTINCT FROM OLD.address
       OR NEW.chain_id IS DISTINCT FROM OLD.chain_id THEN
      RAISE EXCEPTION 'A wallet address cannot be rewritten'
        USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      IF OLD.user_id IS NOT NULL THEN
        RAISE EXCEPTION 'A linked wallet cannot be reassigned'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NOT app_is_admin()
         AND NEW.user_id IS DISTINCT FROM app_current_user_id() THEN
        RAISE EXCEPTION 'A wallet can only be linked to the signed-in user'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      NEW.linked_at := COALESCE(NEW.linked_at, now());
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS wallets_link_guard_trg ON wallets;
CREATE TRIGGER wallets_link_guard_trg BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION wallets_link_guard();

-- ---------------------------------------------------------------------------
-- 3. WEBHOOK INGEST AND CONTRACT EVENTS (Phase 1)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS webhook_receipts (
  id           TEXT PRIMARY KEY,
  source       TEXT NOT NULL CHECK (char_length(source) BETWEEN 1 AND 40),
  delivery_id  TEXT NOT NULL,
  payload_hash TEXT NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  received_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (source, delivery_id)
);

CREATE TABLE IF NOT EXISTS contract_events (
  id                 TEXT PRIMARY KEY,
  webhook_receipt_id TEXT REFERENCES webhook_receipts(id) ON DELETE RESTRICT,
  chain_id           INTEGER NOT NULL CHECK (chain_id = 8453),
  contract_address   TEXT NOT NULL CHECK (contract_address ~ '^0x[0-9a-fA-F]{40}$'),
  event_name         TEXT NOT NULL CHECK (char_length(event_name) BETWEEN 1 AND 64),
  tx_hash            TEXT NOT NULL CHECK (tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  log_index          INTEGER NOT NULL CHECK (log_index >= 0),
  block_number       BIGINT NOT NULL CHECK (block_number >= 0),
  block_time         TIMESTAMP WITH TIME ZONE NOT NULL,
  wallet_address     TEXT CHECK (wallet_address IS NULL OR wallet_address ~ '^0x[0-9a-fA-F]{40}$'),
  payload            JSONB NOT NULL DEFAULT '{}'::jsonb,
  ingested_at        TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (chain_id, tx_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_contract_events_wallet
  ON contract_events (wallet_address, block_time DESC);
CREATE INDEX IF NOT EXISTS idx_contract_events_name
  ON contract_events (event_name, block_time DESC);

-- ---------------------------------------------------------------------------
-- 4. BUYS, LOCKS, POSITIONS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS token_buys (
  id         TEXT PRIMARY KEY,
  wallet_id  TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  amount     NUMERIC NOT NULL CHECK (amount > 0),
  tx_hash    TEXT NOT NULL CHECK (tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  log_index  INTEGER NOT NULL DEFAULT 0 CHECK (log_index >= 0),
  bought_at  TIMESTAMP WITH TIME ZONE NOT NULL,
  lock_until TIMESTAMP WITH TIME ZONE NOT NULL,
  UNIQUE (tx_hash, log_index),
  CHECK (lock_until = bought_at + INTERVAL '30 days')
);

CREATE INDEX IF NOT EXISTS idx_token_buys_wallet ON token_buys (wallet_id, bought_at DESC);

-- The lock is a property of the buy, not of the caller. Overwrite whatever
-- the application passed so the CHECK cannot be gamed with a shorter window.
CREATE OR REPLACE FUNCTION token_buys_set_lock() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.lock_until := NEW.bought_at + INTERVAL '30 days';
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS token_buys_set_lock_trg ON token_buys;
CREATE TRIGGER token_buys_set_lock_trg BEFORE INSERT ON token_buys
  FOR EACH ROW EXECUTE FUNCTION token_buys_set_lock();

CREATE TABLE IF NOT EXISTS token_positions (
  wallet_id         TEXT PRIMARY KEY REFERENCES wallets(id) ON DELETE RESTRICT,
  staked_balance    NUMERIC NOT NULL DEFAULT 0 CHECK (staked_balance >= 0),
  first_buy_at      TIMESTAMP WITH TIME ZONE,
  sell_locked_until TIMESTAMP WITH TIME ZONE,
  updated_at        TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- Buy-in required: a positive stake cannot exist without a first buy.
  CHECK (staked_balance = 0 OR first_buy_at IS NOT NULL)
);

-- Keep sell_locked_until equal to the latest buy's lock. Rewards accrue
-- regardless; this column only answers "may this wallet cash out".
CREATE OR REPLACE FUNCTION token_buys_apply_lock() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO token_positions (wallet_id, staked_balance, first_buy_at, sell_locked_until)
  VALUES (NEW.wallet_id, 0, NEW.bought_at, NEW.lock_until)
  ON CONFLICT (wallet_id) DO UPDATE SET
    first_buy_at      = LEAST(token_positions.first_buy_at, NEW.bought_at),
    sell_locked_until = GREATEST(token_positions.sell_locked_until, NEW.lock_until),
    updated_at        = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS token_buys_apply_lock_trg ON token_buys;
CREATE TRIGGER token_buys_apply_lock_trg AFTER INSERT ON token_buys
  FOR EACH ROW EXECUTE FUNCTION token_buys_apply_lock();

-- ---------------------------------------------------------------------------
-- 5. PREMIUM MEMBERSHIP AND ATTESTATION (5x INSTEAD of 1x, never stacked)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app_memberships (
  id                         TEXT PRIMARY KEY,
  user_id                    TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  plan                       TEXT NOT NULL CHECK (plan = 'premium'),
  status                     TEXT NOT NULL DEFAULT 'active'
                               CHECK (status IN ('active', 'canceled', 'expired')),
  started_at                 TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at                 TIMESTAMP WITH TIME ZONE,
  canceled_at                TIMESTAMP WITH TIME ZONE,
  processor                  TEXT,
  processor_subscription_id  TEXT,
  CHECK (canceled_at IS NULL OR status IN ('canceled', 'expired')),
  CHECK (expires_at IS NULL OR expires_at > started_at)
);

-- One live premium membership per user. A canceled row can stay; a second
-- active one cannot.
CREATE UNIQUE INDEX IF NOT EXISTS idx_memberships_one_active
  ON app_memberships (user_id) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS premium_attestations (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  membership_id   TEXT NOT NULL REFERENCES app_memberships(id) ON DELETE RESTRICT,
  wallet_id       TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  attested_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  revoked_at      TIMESTAMP WITH TIME ZONE,
  on_chain_tx     TEXT CHECK (on_chain_tx IS NULL OR on_chain_tx ~ '^0x[0-9a-fA-F]{64}$'),
  CHECK (revoked_at IS NULL OR revoked_at >= attested_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_attestations_one_live_wallet
  ON premium_attestations (wallet_id) WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_attestations_user
  ON premium_attestations (user_id, attested_at DESC);

-- Attestation is only valid while the membership is active and the wallet
-- is linked to the same user. No burn path exists on this table.
CREATE OR REPLACE FUNCTION premium_attestations_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  mem app_memberships%ROWTYPE;
  wal wallets%ROWTYPE;
BEGIN
  SELECT * INTO mem FROM app_memberships WHERE id = NEW.membership_id;
  IF NOT FOUND OR mem.status <> 'active' OR mem.user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Premium attestation requires an active membership for this user'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO wal FROM wallets WHERE id = NEW.wallet_id;
  IF NOT FOUND OR wal.user_id IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION 'Premium attestation requires a wallet linked to this user'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS premium_attestations_guard_trg ON premium_attestations;
CREATE TRIGGER premium_attestations_guard_trg BEFORE INSERT ON premium_attestations
  FOR EACH ROW EXECUTE FUNCTION premium_attestations_guard();

-- ---------------------------------------------------------------------------
-- 6. RESERVE CREDITS AND HOURLY EPOCHS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS hourly_epochs (
  id             TEXT PRIMARY KEY,
  epoch_hour     TIMESTAMP WITH TIME ZONE NOT NULL UNIQUE,
  holder_pool    NUMERIC NOT NULL DEFAULT 0 CHECK (holder_pool >= 0),
  total_weight   NUMERIC CHECK (total_weight IS NULL OR total_weight >= 0),
  haircut_ratio  NUMERIC CHECK (haircut_ratio IS NULL OR (haircut_ratio > 0 AND haircut_ratio <= 1)),
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  closed_at      TIMESTAMP WITH TIME ZONE,
  CHECK (
    (status = 'open' AND closed_at IS NULL)
    OR (status = 'closed' AND closed_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS transaction_reserves (
  id              TEXT PRIMARY KEY,
  source          TEXT NOT NULL CHECK (source IN ('settlement', 'on_chain', 'manual')),
  source_id       TEXT,
  volume          NUMERIC NOT NULL CHECK (volume > 0),
  reserve_amount  NUMERIC NOT NULL,
  holder_slice    NUMERIC NOT NULL,
  epoch_id        TEXT NOT NULL REFERENCES hourly_epochs(id) ON DELETE RESTRICT,
  credited_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- 10% of volume into the reserve; 7% of that reserve (0.7% of volume)
  -- is the only money holder rewards may ever draw from.
  CHECK (reserve_amount = volume * 0.10),
  CHECK (holder_slice   = reserve_amount * 0.07)
);

CREATE INDEX IF NOT EXISTS idx_reserves_epoch ON transaction_reserves (epoch_id, credited_at);

CREATE OR REPLACE FUNCTION app_open_epoch(p_at TIMESTAMP WITH TIME ZONE) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  hour_ts TIMESTAMP WITH TIME ZONE := date_trunc('hour', p_at);
  new_id  TEXT;
BEGIN
  SELECT id INTO new_id FROM hourly_epochs WHERE epoch_hour = hour_ts;
  IF FOUND THEN
    RETURN new_id;
  END IF;
  new_id := 'ep-' || to_char(hour_ts AT TIME ZONE 'UTC', 'YYYYMMDDHH24');
  INSERT INTO hourly_epochs (id, epoch_hour) VALUES (new_id, hour_ts)
  ON CONFLICT (epoch_hour) DO NOTHING;
  SELECT id INTO new_id FROM hourly_epochs WHERE epoch_hour = hour_ts;
  RETURN new_id;
END $$;

GRANT EXECUTE ON FUNCTION app_open_epoch(TIMESTAMP WITH TIME ZONE) TO asoc_app;

CREATE OR REPLACE FUNCTION transaction_reserves_credit_pool() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE hourly_epochs
     SET holder_pool = holder_pool + NEW.holder_slice
   WHERE id = NEW.epoch_id AND status = 'open';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cannot credit a closed or missing epoch %', NEW.epoch_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS transaction_reserves_credit_pool_trg ON transaction_reserves;
CREATE TRIGGER transaction_reserves_credit_pool_trg AFTER INSERT ON transaction_reserves
  FOR EACH ROW EXECUTE FUNCTION transaction_reserves_credit_pool();

CREATE TABLE IF NOT EXISTS hourly_claims (
  id                      TEXT PRIMARY KEY,
  epoch_id                TEXT NOT NULL REFERENCES hourly_epochs(id) ON DELETE RESTRICT,
  wallet_id               TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  staked_balance          NUMERIC NOT NULL CHECK (staked_balance > 0),
  weight_multiplier       INTEGER NOT NULL CHECK (weight_multiplier IN (1, 5)),
  weight                  NUMERIC NOT NULL CHECK (weight = staked_balance * weight_multiplier),
  premium_attestation_id  TEXT REFERENCES premium_attestations(id) ON DELETE RESTRICT,
  entitled_before_haircut NUMERIC NOT NULL CHECK (entitled_before_haircut >= 0),
  haircut_ratio           NUMERIC NOT NULL CHECK (haircut_ratio > 0 AND haircut_ratio <= 1),
  paid_amount             NUMERIC NOT NULL CHECK (paid_amount >= 0),
  tx_hash                 TEXT CHECK (tx_hash IS NULL OR tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  claimed_at              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (epoch_id, wallet_id),
  -- Never stack: 5x only with a live attestation snapshot, 1x without one.
  CHECK (
    (weight_multiplier = 5 AND premium_attestation_id IS NOT NULL)
    OR (weight_multiplier = 1 AND premium_attestation_id IS NULL)
  ),
  CHECK (abs(paid_amount - (entitled_before_haircut * haircut_ratio)) < 0.00000001)
);

CREATE INDEX IF NOT EXISTS idx_hourly_claims_wallet
  ON hourly_claims (wallet_id, claimed_at DESC);

-- The contract must never pay more than the holder slice. Two concurrent
-- inserts serialize on the epoch row.
CREATE OR REPLACE FUNCTION hourly_claims_cap() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  pool    NUMERIC;
  already NUMERIC;
BEGIN
  SELECT holder_pool INTO pool FROM hourly_epochs WHERE id = NEW.epoch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Epoch not found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(SUM(paid_amount), 0) INTO already
    FROM hourly_claims WHERE epoch_id = NEW.epoch_id;

  IF already + NEW.paid_amount > pool THEN
    RAISE EXCEPTION 'Hourly claims cannot exceed the holder slice (pool %, already %, next %)',
      pool, already, NEW.paid_amount
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS hourly_claims_cap_trg ON hourly_claims;
CREATE TRIGGER hourly_claims_cap_trg BEFORE INSERT ON hourly_claims
  FOR EACH ROW EXECUTE FUNCTION hourly_claims_cap();

-- ---------------------------------------------------------------------------
-- 7. DRIVER PAYOUTS — USDC on Base, a separate pipe from holder rewards
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS driver_payouts (
  id            TEXT PRIMARY KEY,
  driver_id     TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  settlement_id TEXT NOT NULL UNIQUE REFERENCES settlements(id) ON DELETE RESTRICT,
  wallet_id     TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  chain_id      INTEGER NOT NULL DEFAULT 8453 CHECK (chain_id = 8453),
  token         TEXT NOT NULL DEFAULT 'USDC' CHECK (token = 'USDC'),
  amount        NUMERIC NOT NULL CHECK (amount > 0),
  tx_hash       TEXT UNIQUE CHECK (tx_hash IS NULL OR tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'submitted', 'confirmed', 'failed')),
  created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  confirmed_at  TIMESTAMP WITH TIME ZONE,
  CHECK (status <> 'confirmed' OR (tx_hash IS NOT NULL AND confirmed_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_driver_payouts_driver
  ON driver_payouts (driver_id, created_at DESC);

CREATE OR REPLACE FUNCTION driver_payouts_base_wallet() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE wal wallets%ROWTYPE;
BEGIN
  SELECT * INTO wal FROM wallets WHERE id = NEW.wallet_id;
  IF NOT FOUND OR wal.chain_id <> 8453 THEN
    RAISE EXCEPTION 'Driver payouts are USDC on Base only'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS driver_payouts_base_wallet_trg ON driver_payouts;
CREATE TRIGGER driver_payouts_base_wallet_trg BEFORE INSERT OR UPDATE ON driver_payouts
  FOR EACH ROW EXECUTE FUNCTION driver_payouts_base_wallet();

-- ---------------------------------------------------------------------------
-- 8. PHASE 2 HAUL RECEIPT (schema only — nothing writes this yet)
-- ---------------------------------------------------------------------------
-- On delivered, the same receipt will write plate, load id, miles, rate,
-- and reserve. Messaging and email stay out of this database until Phase 2
-- is opened.

CREATE TABLE IF NOT EXISTS haul_receipts (
  id             TEXT PRIMARY KEY,
  settlement_id  TEXT NOT NULL UNIQUE REFERENCES settlements(id) ON DELETE RESTRICT,
  load_id        TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  plate          TEXT CHECK (plate IS NULL OR char_length(btrim(plate)) BETWEEN 1 AND 12),
  miles          NUMERIC NOT NULL CHECK (miles > 0),
  rate_per_mile  NUMERIC NOT NULL CHECK (rate_per_mile > 0),
  reserve_amount NUMERIC NOT NULL,
  holder_slice   NUMERIC NOT NULL,
  written_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (reserve_amount = (miles * rate_per_mile) * 0.10),
  CHECK (holder_slice   = reserve_amount * 0.07)
);

CREATE OR REPLACE FUNCTION haul_receipts_match_settlement() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE s settlements%ROWTYPE;
BEGIN
  SELECT * INTO s FROM settlements WHERE id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Haul receipt requires a settlement' USING ERRCODE = 'no_data_found';
  END IF;
  IF NEW.load_id IS DISTINCT FROM s.load_id
     OR NEW.miles IS DISTINCT FROM s.miles
     OR NEW.rate_per_mile IS DISTINCT FROM s.rate_per_mile THEN
    RAISE EXCEPTION 'Haul receipt must copy miles, rate, and load from the settlement'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS haul_receipts_match_settlement_trg ON haul_receipts;
CREATE TRIGGER haul_receipts_match_settlement_trg BEFORE INSERT ON haul_receipts
  FOR EACH ROW EXECUTE FUNCTION haul_receipts_match_settlement();

-- ---------------------------------------------------------------------------
-- 9. APPEND-ONLY + AUDIT
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS webhook_receipts_append_only ON webhook_receipts;
CREATE TRIGGER webhook_receipts_append_only BEFORE UPDATE OR DELETE ON webhook_receipts
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS contract_events_append_only ON contract_events;
CREATE TRIGGER contract_events_append_only BEFORE UPDATE OR DELETE ON contract_events
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS token_buys_append_only ON token_buys;
CREATE TRIGGER token_buys_append_only BEFORE UPDATE OR DELETE ON token_buys
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS transaction_reserves_append_only ON transaction_reserves;
CREATE TRIGGER transaction_reserves_append_only BEFORE UPDATE OR DELETE ON transaction_reserves
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS hourly_claims_append_only ON hourly_claims;
CREATE TRIGGER hourly_claims_append_only BEFORE UPDATE OR DELETE ON hourly_claims
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS haul_receipts_append_only ON haul_receipts;
CREATE TRIGGER haul_receipts_append_only BEFORE UPDATE OR DELETE ON haul_receipts
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS audit_wallets ON wallets;
CREATE TRIGGER audit_wallets AFTER INSERT OR UPDATE OR DELETE ON wallets
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_token_buys ON token_buys;
CREATE TRIGGER audit_token_buys AFTER INSERT OR UPDATE OR DELETE ON token_buys
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_token_positions ON token_positions;
CREATE TRIGGER audit_token_positions AFTER INSERT OR UPDATE OR DELETE ON token_positions
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_memberships ON app_memberships;
CREATE TRIGGER audit_memberships AFTER INSERT OR UPDATE OR DELETE ON app_memberships
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_attestations ON premium_attestations;
CREATE TRIGGER audit_attestations AFTER INSERT OR UPDATE OR DELETE ON premium_attestations
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_reserves ON transaction_reserves;
CREATE TRIGGER audit_reserves AFTER INSERT OR UPDATE OR DELETE ON transaction_reserves
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_hourly_claims ON hourly_claims;
CREATE TRIGGER audit_hourly_claims AFTER INSERT OR UPDATE OR DELETE ON hourly_claims
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_driver_payouts ON driver_payouts;
CREATE TRIGGER audit_driver_payouts AFTER INSERT OR UPDATE OR DELETE ON driver_payouts
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- ---------------------------------------------------------------------------
-- 10. READ MODELS
-- ---------------------------------------------------------------------------

-- Holder slice vs what has actually been claimed, per hour. A ratio above 1
-- is impossible: the cap trigger refuses it.
CREATE OR REPLACE VIEW hourly_epoch_view AS
SELECT
  e.id,
  e.epoch_hour,
  e.holder_pool,
  e.total_weight,
  e.haircut_ratio,
  e.status,
  e.closed_at,
  COUNT(c.id)::INTEGER                         AS claim_count,
  COALESCE(SUM(c.paid_amount), 0)              AS paid_total,
  e.holder_pool - COALESCE(SUM(c.paid_amount), 0) AS unclaimed
FROM hourly_epochs e
LEFT JOIN hourly_claims c ON c.epoch_id = e.id
GROUP BY e.id, e.epoch_hour, e.holder_pool, e.total_weight,
         e.haircut_ratio, e.status, e.closed_at;

CREATE OR REPLACE VIEW wallet_holder_view AS
SELECT
  w.id                                              AS wallet_id,
  w.address,
  w.chain_id,
  w.user_id,
  p.staked_balance,
  p.first_buy_at,
  p.sell_locked_until,
  (p.sell_locked_until IS NOT NULL AND p.sell_locked_until > now()) AS sell_locked,
  CASE WHEN a.id IS NOT NULL THEN 5 ELSE 1 END      AS weight_multiplier,
  a.id                                              AS live_attestation_id
FROM wallets w
LEFT JOIN token_positions p ON p.wallet_id = w.id
LEFT JOIN premium_attestations a ON a.wallet_id = w.id AND a.revoked_at IS NULL
WHERE app_is_admin() OR app_is_webhook() OR w.user_id = app_current_user_id();

-- ---------------------------------------------------------------------------
-- 11. GRANTS AND RLS
-- ---------------------------------------------------------------------------

GRANT SELECT ON chain_contracts TO asoc_app;
GRANT SELECT, INSERT, UPDATE ON wallets TO asoc_app;
GRANT SELECT, INSERT ON webhook_receipts, contract_events, token_buys,
                         transaction_reserves, hourly_claims, haul_receipts TO asoc_app;
GRANT SELECT, INSERT, UPDATE ON token_positions, app_memberships,
                                premium_attestations, hourly_epochs, driver_payouts TO asoc_app;
GRANT SELECT ON hourly_epoch_view, wallet_holder_view TO asoc_app;

ALTER TABLE chain_contracts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets                ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_receipts       ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE token_buys             ENABLE ROW LEVEL SECURITY;
ALTER TABLE token_positions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_memberships        ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_attestations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE hourly_epochs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_reserves   ENABLE ROW LEVEL SECURITY;
ALTER TABLE hourly_claims          ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_payouts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE haul_receipts          ENABLE ROW LEVEL SECURITY;

-- Chain registry is public reference data (USDC address, later the token).
DROP POLICY IF EXISTS chain_contracts_select ON chain_contracts;
CREATE POLICY chain_contracts_select ON chain_contracts FOR SELECT USING (true);

-- Addresses are on-chain public. user_id is the sensitive half, so the row
-- is visible to the linked user, admins, and the webhook indexer.
DROP POLICY IF EXISTS wallets_select ON wallets;
CREATE POLICY wallets_select ON wallets FOR SELECT USING (
  app_is_admin() OR app_is_webhook()
  OR user_id = app_current_user_id()
  OR user_id IS NULL
);

DROP POLICY IF EXISTS wallets_insert ON wallets;
CREATE POLICY wallets_insert ON wallets FOR INSERT WITH CHECK (
  app_is_admin() OR app_is_webhook()
  OR user_id = app_current_user_id()
);

DROP POLICY IF EXISTS wallets_update ON wallets;
CREATE POLICY wallets_update ON wallets FOR UPDATE USING (
  app_is_admin() OR user_id = app_current_user_id() OR user_id IS NULL
) WITH CHECK (
  app_is_admin() OR user_id = app_current_user_id()
);

-- Webhook receipts and decoded events: indexer writes, admins read.
DROP POLICY IF EXISTS webhook_receipts_insert ON webhook_receipts;
CREATE POLICY webhook_receipts_insert ON webhook_receipts FOR INSERT WITH CHECK (app_is_webhook());
DROP POLICY IF EXISTS webhook_receipts_select ON webhook_receipts;
CREATE POLICY webhook_receipts_select ON webhook_receipts FOR SELECT USING (app_is_admin() OR app_is_webhook());

DROP POLICY IF EXISTS contract_events_insert ON contract_events;
CREATE POLICY contract_events_insert ON contract_events FOR INSERT WITH CHECK (app_is_webhook());
DROP POLICY IF EXISTS contract_events_select ON contract_events;
CREATE POLICY contract_events_select ON contract_events FOR SELECT USING (app_is_admin() OR app_is_webhook());

-- Buys and positions are on-chain facts; the linked user and admins can read.
DROP POLICY IF EXISTS token_buys_select ON token_buys;
CREATE POLICY token_buys_select ON token_buys FOR SELECT USING (
  app_is_admin() OR app_is_webhook()
  OR EXISTS (SELECT 1 FROM wallets w WHERE w.id = token_buys.wallet_id AND w.user_id = app_current_user_id())
);
DROP POLICY IF EXISTS token_buys_insert ON token_buys;
CREATE POLICY token_buys_insert ON token_buys FOR INSERT WITH CHECK (app_is_webhook());

DROP POLICY IF EXISTS token_positions_select ON token_positions;
CREATE POLICY token_positions_select ON token_positions FOR SELECT USING (
  app_is_admin() OR app_is_webhook()
  OR EXISTS (SELECT 1 FROM wallets w WHERE w.id = token_positions.wallet_id AND w.user_id = app_current_user_id())
);
DROP POLICY IF EXISTS token_positions_write ON token_positions;
CREATE POLICY token_positions_write ON token_positions FOR UPDATE USING (app_is_webhook())
  WITH CHECK (app_is_webhook());
DROP POLICY IF EXISTS token_positions_insert ON token_positions;
CREATE POLICY token_positions_insert ON token_positions FOR INSERT WITH CHECK (app_is_webhook());

-- Membership is an app fact, not an on-chain one.
DROP POLICY IF EXISTS app_memberships_select ON app_memberships;
CREATE POLICY app_memberships_select ON app_memberships FOR SELECT USING (
  app_is_admin() OR user_id = app_current_user_id()
);
DROP POLICY IF EXISTS app_memberships_insert ON app_memberships;
CREATE POLICY app_memberships_insert ON app_memberships FOR INSERT WITH CHECK (app_is_admin());
DROP POLICY IF EXISTS app_memberships_update ON app_memberships;
CREATE POLICY app_memberships_update ON app_memberships FOR UPDATE USING (app_is_admin())
  WITH CHECK (app_is_admin());

DROP POLICY IF EXISTS premium_attestations_select ON premium_attestations;
CREATE POLICY premium_attestations_select ON premium_attestations FOR SELECT USING (
  app_is_admin() OR app_is_webhook() OR user_id = app_current_user_id()
);
DROP POLICY IF EXISTS premium_attestations_insert ON premium_attestations;
CREATE POLICY premium_attestations_insert ON premium_attestations FOR INSERT WITH CHECK (
  app_is_admin() OR user_id = app_current_user_id()
);
DROP POLICY IF EXISTS premium_attestations_update ON premium_attestations;
CREATE POLICY premium_attestations_update ON premium_attestations FOR UPDATE USING (
  app_is_admin() OR user_id = app_current_user_id()
) WITH CHECK (
  app_is_admin() OR user_id = app_current_user_id()
);

-- Epochs and reserve credits are public in the same sense as Open Books:
-- the holder pool is how the 0.7% slice is shown to be real.
DROP POLICY IF EXISTS hourly_epochs_select ON hourly_epochs;
CREATE POLICY hourly_epochs_select ON hourly_epochs FOR SELECT USING (true);
DROP POLICY IF EXISTS hourly_epochs_insert ON hourly_epochs;
CREATE POLICY hourly_epochs_insert ON hourly_epochs FOR INSERT WITH CHECK (app_is_webhook());
DROP POLICY IF EXISTS hourly_epochs_update ON hourly_epochs;
CREATE POLICY hourly_epochs_update ON hourly_epochs FOR UPDATE USING (app_is_webhook())
  WITH CHECK (app_is_webhook());

DROP POLICY IF EXISTS transaction_reserves_select ON transaction_reserves;
CREATE POLICY transaction_reserves_select ON transaction_reserves FOR SELECT USING (true);
DROP POLICY IF EXISTS transaction_reserves_insert ON transaction_reserves;
CREATE POLICY transaction_reserves_insert ON transaction_reserves FOR INSERT WITH CHECK (app_is_webhook());

DROP POLICY IF EXISTS hourly_claims_select ON hourly_claims;
CREATE POLICY hourly_claims_select ON hourly_claims FOR SELECT USING (
  app_is_admin() OR app_is_webhook()
  OR EXISTS (SELECT 1 FROM wallets w WHERE w.id = hourly_claims.wallet_id AND w.user_id = app_current_user_id())
);
DROP POLICY IF EXISTS hourly_claims_insert ON hourly_claims;
CREATE POLICY hourly_claims_insert ON hourly_claims FOR INSERT WITH CHECK (app_is_webhook());

DROP POLICY IF EXISTS driver_payouts_select ON driver_payouts;
CREATE POLICY driver_payouts_select ON driver_payouts FOR SELECT USING (
  app_is_admin() OR app_is_webhook() OR driver_id = app_current_driver_id()
);
DROP POLICY IF EXISTS driver_payouts_insert ON driver_payouts;
CREATE POLICY driver_payouts_insert ON driver_payouts FOR INSERT WITH CHECK (app_is_webhook() OR app_is_admin());
DROP POLICY IF EXISTS driver_payouts_update ON driver_payouts;
CREATE POLICY driver_payouts_update ON driver_payouts FOR UPDATE USING (app_is_webhook() OR app_is_admin())
  WITH CHECK (app_is_webhook() OR app_is_admin());

-- Phase 2 receipts become public the way settlements are, once they exist.
DROP POLICY IF EXISTS haul_receipts_select ON haul_receipts;
CREATE POLICY haul_receipts_select ON haul_receipts FOR SELECT USING (true);
DROP POLICY IF EXISTS haul_receipts_insert ON haul_receipts;
CREATE POLICY haul_receipts_insert ON haul_receipts FOR INSERT WITH CHECK (app_is_admin());
