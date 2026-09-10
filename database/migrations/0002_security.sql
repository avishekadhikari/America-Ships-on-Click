-- America Ships On Click: Database security hardening
--
-- Defense in depth, enforced by the database rather than by application code:
--
--   1. Least-privilege role      — the app connects as a role that cannot run
--                                  DDL, delete rows, or touch its own audit log.
--   2. Row-Level Security        — every row a request can read or write is
--                                  decided by the database from the request's
--                                  identity, not by the query that asks.
--   3. Integrity constraints     — settlement math, money signs, bcrypt-only
--                                  password columns, no raw bank numbers.
--   4. Append-only ledger        — settlements and audit rows cannot be
--                                  updated or deleted by anyone, including the
--                                  table owner.
--   5. Audit trail               — who changed what, written by a trigger the
--                                  application cannot bypass or edit.
--   6. Login throttling          — failed attempts recorded and locked out in
--                                  the database, so it survives app restarts
--                                  and applies across every server instance.
--
-- Identity is carried per transaction in `app.*` session settings (see
-- src/db/client.ts). Superusers and the table owner bypass RLS by design, so
-- migrations, seeding, and backups keep working; only the runtime role is
-- constrained.

-- ---------------------------------------------------------------------------
-- 1. RUNTIME ROLE (least privilege)
-- ---------------------------------------------------------------------------

-- Created without a password and without LOGIN: the provisioning step grants
-- login and sets a secret (scripts/postgres-dev.sh, or your cloud provider).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'asoc_app') THEN
    CREATE ROLE asoc_app NOLOGIN;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE EXCEPTION 'Cannot create the asoc_app role. Run this migration as a role '
    'with CREATEROLE, or create asoc_app yourself and re-run.'
    USING ERRCODE = 'insufficient_privilege';
END $$;

-- Nothing is granted to PUBLIC; every privilege below is explicit.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO asoc_app;

-- Read-only reference data.
GRANT SELECT ON platform_config, schema_migrations TO asoc_app;

-- Identity tables: no UPDATE (no route changes a user row), no DELETE anywhere.
GRANT SELECT, INSERT                 ON users                    TO asoc_app;
GRANT SELECT, INSERT, UPDATE         ON driver_profiles          TO asoc_app;
GRANT SELECT, INSERT, UPDATE         ON driver_equipment         TO asoc_app;
GRANT SELECT, INSERT, UPDATE         ON driver_payment_accounts  TO asoc_app;
GRANT SELECT, INSERT                 ON driver_documents         TO asoc_app;
GRANT SELECT, INSERT                 ON shipper_profiles         TO asoc_app;

-- Operational tables.
GRANT SELECT, INSERT, UPDATE         ON loads                    TO asoc_app;
GRANT SELECT, INSERT, UPDATE         ON bookings                 TO asoc_app;

-- The ledger is append-only: INSERT but never UPDATE or DELETE.
GRANT SELECT, INSERT                 ON settlements              TO asoc_app;

-- Public read models.
GRANT SELECT ON public_ledger_view, settlement_totals_view TO asoc_app;

-- ---------------------------------------------------------------------------
-- 2. REQUEST IDENTITY HELPERS
-- ---------------------------------------------------------------------------
-- The app sets these per transaction with set_config(..., true), so they are
-- scoped to that transaction and cannot leak between pooled requests.

CREATE OR REPLACE FUNCTION app_current_user_id() RETURNS TEXT
  LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.user_id', true), '') $$;

CREATE OR REPLACE FUNCTION app_current_role() RETURNS TEXT
  LANGUAGE sql STABLE AS $$ SELECT COALESCE(NULLIF(current_setting('app.user_role', true), ''), 'anon') $$;

CREATE OR REPLACE FUNCTION app_current_driver_id() RETURNS TEXT
  LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.driver_id', true), '') $$;

CREATE OR REPLACE FUNCTION app_current_shipper_id() RETURNS TEXT
  LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.shipper_id', true), '') $$;

CREATE OR REPLACE FUNCTION app_is_admin() RETURNS BOOLEAN
  LANGUAGE sql STABLE AS $$ SELECT app_current_role() = 'admin' $$;

GRANT EXECUTE ON FUNCTION app_current_user_id(), app_current_role(),
  app_current_driver_id(), app_current_shipper_id(), app_is_admin() TO asoc_app;

-- ---------------------------------------------------------------------------
-- 3. INTEGRITY CONSTRAINTS
-- ---------------------------------------------------------------------------
-- Constraints are the last line of defense: even a fully compromised
-- application cannot write a settlement whose arithmetic does not add up.

DO $$
BEGIN
  -- Passwords must be bcrypt digests. A plaintext password can never be
  -- stored by accident, whatever the application does.
  ALTER TABLE users ADD CONSTRAINT users_password_is_bcrypt
    CHECK (password_hash ~ '^\$2[aby]?\$[0-9]{2}\$' AND length(password_hash) >= 55);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  ALTER TABLE users ADD CONSTRAINT users_email_shape
    CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  -- Bank routing/account numbers must never reach this column; only opaque
  -- processor tokens. A bare digit string is rejected outright.
  ALTER TABLE driver_payment_accounts ADD CONSTRAINT payment_account_is_tokenized
    CHECK (processor_account_id !~ '^[0-9-]{6,}$' AND length(processor_account_id) >= 8);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_positive_amounts
    CHECK (miles > 0 AND rate_per_mile > 0 AND (weight_lbs IS NULL OR weight_lbs >= 0));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  ALTER TABLE settlements ADD CONSTRAINT settlements_non_negative
    CHECK (miles > 0 AND rate_per_mile > 0 AND gross_amount >= 0 AND fee_amount >= 0
           AND fuel_cost >= 0 AND factor_cost >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  ALTER TABLE settlements ADD CONSTRAINT settlements_fee_pct_sane
    CHECK (fee_pct_applied >= 0 AND fee_pct_applied <= 0.5);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  -- The Open Books guarantee, enforced by the database: net is exactly
  -- gross - fee - fuel - factor, and gross is exactly miles x rate.
  ALTER TABLE settlements ADD CONSTRAINT settlements_math_balances
    CHECK (
      abs(net_amount - (gross_amount - fee_amount - fuel_cost - factor_cost)) < 0.01
      AND abs(gross_amount - (miles * rate_per_mile)) < 0.01
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$
BEGIN
  ALTER TABLE platform_config ADD CONSTRAINT platform_config_non_negative
    CHECK (value >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 4. AUDIT TRAIL
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS audit_log (
  id          BIGSERIAL PRIMARY KEY,
  table_name  TEXT NOT NULL,
  operation   TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
  row_id      TEXT,
  actor_id    TEXT,
  actor_role  TEXT,
  old_data    JSONB,
  new_data    JSONB,
  changed_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_audit_log_table_time ON audit_log (table_name, changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON audit_log (actor_id, changed_at DESC);

-- SECURITY DEFINER: the trigger writes as the table owner, so the application
-- role can neither read, forge, nor suppress its own audit trail.
CREATE OR REPLACE FUNCTION audit_row_change() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  redacted_old JSONB;
  redacted_new JSONB;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    redacted_old := to_jsonb(OLD) - 'password_hash' - 'processor_account_id';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    redacted_new := to_jsonb(NEW) - 'password_hash' - 'processor_account_id';
  END IF;

  INSERT INTO audit_log (table_name, operation, row_id, actor_id, actor_role, old_data, new_data)
  VALUES (
    TG_TABLE_NAME,
    TG_OP,
    COALESCE(redacted_new ->> 'id', redacted_old ->> 'id',
             redacted_new ->> 'key', redacted_old ->> 'key'),
    app_current_user_id(),
    app_current_role(),
    redacted_old,
    redacted_new
  );

  RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS audit_users ON users;
CREATE TRIGGER audit_users AFTER INSERT OR UPDATE OR DELETE ON users
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_payment_accounts ON driver_payment_accounts;
CREATE TRIGGER audit_payment_accounts AFTER INSERT OR UPDATE OR DELETE ON driver_payment_accounts
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_bookings ON bookings;
CREATE TRIGGER audit_bookings AFTER INSERT OR UPDATE OR DELETE ON bookings
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_settlements ON settlements;
CREATE TRIGGER audit_settlements AFTER INSERT OR UPDATE OR DELETE ON settlements
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_loads ON loads;
CREATE TRIGGER audit_loads AFTER INSERT OR UPDATE OR DELETE ON loads
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_platform_config ON platform_config;
CREATE TRIGGER audit_platform_config AFTER INSERT OR UPDATE OR DELETE ON platform_config
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- ---------------------------------------------------------------------------
-- 5. APPEND-ONLY ENFORCEMENT
-- ---------------------------------------------------------------------------
-- Grants stop the application role. These triggers stop everyone, including
-- the owner: a settled row and an audit row are permanent facts.

CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not permitted', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END $$;

DROP TRIGGER IF EXISTS settlements_append_only ON settlements;
CREATE TRIGGER settlements_append_only BEFORE UPDATE OR DELETE ON settlements
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS audit_log_append_only ON audit_log;
CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---------------------------------------------------------------------------
-- 6. LOGIN THROTTLING
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS auth_login_attempts (
  id           BIGSERIAL PRIMARY KEY,
  email        TEXT NOT NULL,
  ip_address   TEXT,
  succeeded    BOOLEAN NOT NULL,
  attempted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_email_time
  ON auth_login_attempts (lower(email), attempted_at DESC);

-- Recorded and evaluated inside the database, so throttling holds across
-- restarts and across every server instance behind a load balancer.
CREATE OR REPLACE FUNCTION app_record_login_attempt(p_email TEXT, p_ip TEXT, p_ok BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO auth_login_attempts (email, ip_address, succeeded)
  VALUES (lower(p_email), p_ip, p_ok);

  -- On success, clear the failure streak for that account.
  IF p_ok THEN
    DELETE FROM auth_login_attempts
    WHERE lower(email) = lower(p_email) AND NOT succeeded;
  END IF;

  -- Keep the table bounded.
  DELETE FROM auth_login_attempts WHERE attempted_at < now() - INTERVAL '7 days';
END $$;

-- Returns seconds remaining in the lockout, or 0 when the account may try.
CREATE OR REPLACE FUNCTION app_login_lockout_seconds(p_email TEXT)
RETURNS INTEGER LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  max_failures CONSTANT INTEGER := 5;
  window_secs  CONSTANT INTEGER := 900;   -- 15 minutes
  failures     INTEGER;
  newest       TIMESTAMP WITH TIME ZONE;
BEGIN
  SELECT count(*), max(attempted_at) INTO failures, newest
  FROM auth_login_attempts
  WHERE lower(email) = lower(p_email)
    AND NOT succeeded
    AND attempted_at > now() - make_interval(secs => window_secs);

  IF failures >= max_failures THEN
    RETURN GREATEST(0, window_secs - EXTRACT(EPOCH FROM (now() - newest))::INTEGER);
  END IF;
  RETURN 0;
END $$;

GRANT EXECUTE ON FUNCTION app_record_login_attempt(TEXT, TEXT, BOOLEAN) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_login_lockout_seconds(TEXT) TO asoc_app;

-- ---------------------------------------------------------------------------
-- 7. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------------
-- Read/write scope is decided by the database from the request identity, so a
-- flaw in any route cannot reach another driver's payment details.
--
-- Contexts: 'anon' (public), 'auth' (credential check), 'enrollment' (signup /
-- onboarding), 'driver', 'shipper', 'admin'.

ALTER TABLE users                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_equipment        ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_documents        ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_payment_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipper_profiles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE loads                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings                ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlements             ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_config         ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log               ENABLE ROW LEVEL SECURITY;

-- users ---------------------------------------------------------------------
DROP POLICY IF EXISTS users_select ON users;
CREATE POLICY users_select ON users FOR SELECT USING (
  app_is_admin()
  OR id = app_current_user_id()
  -- Credential check and duplicate-email check happen before an identity exists.
  OR app_current_role() IN ('auth', 'enrollment')
);

DROP POLICY IF EXISTS users_insert ON users;
CREATE POLICY users_insert ON users FOR INSERT WITH CHECK (
  app_is_admin() OR app_current_role() = 'enrollment'
);

-- driver_profiles -----------------------------------------------------------
DROP POLICY IF EXISTS driver_profiles_select ON driver_profiles;
CREATE POLICY driver_profiles_select ON driver_profiles FOR SELECT USING (
  app_is_admin()
  OR user_id = app_current_user_id()
  OR id = app_current_driver_id()
  OR app_current_role() IN ('auth', 'enrollment')
);

DROP POLICY IF EXISTS driver_profiles_insert ON driver_profiles;
CREATE POLICY driver_profiles_insert ON driver_profiles FOR INSERT WITH CHECK (
  app_is_admin() OR app_current_role() = 'enrollment'
);

DROP POLICY IF EXISTS driver_profiles_update ON driver_profiles;
CREATE POLICY driver_profiles_update ON driver_profiles FOR UPDATE USING (
  app_is_admin()
  OR user_id = app_current_user_id()
  OR id = app_current_driver_id()
  -- Onboarding may complete a profile that is not verified yet, never alter one
  -- that has already been approved.
  OR (app_current_role() = 'enrollment' AND verification_status = 'pending')
);

-- driver_equipment ----------------------------------------------------------
DROP POLICY IF EXISTS driver_equipment_rw ON driver_equipment;
CREATE POLICY driver_equipment_rw ON driver_equipment FOR ALL USING (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

-- driver_documents ----------------------------------------------------------
DROP POLICY IF EXISTS driver_documents_rw ON driver_documents;
CREATE POLICY driver_documents_rw ON driver_documents FOR ALL USING (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

-- driver_payment_accounts ---------------------------------------------------
-- The most sensitive table: only the owning driver, an admin, or enrollment.
DROP POLICY IF EXISTS driver_payment_accounts_rw ON driver_payment_accounts;
CREATE POLICY driver_payment_accounts_rw ON driver_payment_accounts FOR ALL USING (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

-- shipper_profiles ----------------------------------------------------------
DROP POLICY IF EXISTS shipper_profiles_select ON shipper_profiles;
CREATE POLICY shipper_profiles_select ON shipper_profiles FOR SELECT USING (
  app_is_admin()
  OR user_id = app_current_user_id()
  OR id = app_current_shipper_id()
  OR app_current_role() IN ('auth', 'enrollment')
);

DROP POLICY IF EXISTS shipper_profiles_insert ON shipper_profiles;
CREATE POLICY shipper_profiles_insert ON shipper_profiles FOR INSERT WITH CHECK (
  app_is_admin() OR app_current_role() = 'enrollment'
);

-- loads ---------------------------------------------------------------------
-- The load board is public by design.
DROP POLICY IF EXISTS loads_select ON loads;
CREATE POLICY loads_select ON loads FOR SELECT USING (true);

DROP POLICY IF EXISTS loads_insert ON loads;
CREATE POLICY loads_insert ON loads FOR INSERT WITH CHECK (
  app_is_admin() OR shipper_id = app_current_shipper_id()
);

DROP POLICY IF EXISTS loads_update ON loads;
CREATE POLICY loads_update ON loads FOR UPDATE USING (
  app_is_admin()
  OR shipper_id = app_current_shipper_id()
  -- A driver may advance only a load they hold a live booking on.
  OR EXISTS (
    SELECT 1 FROM bookings b
    WHERE b.load_id = loads.id
      AND b.driver_id = app_current_driver_id()
      AND b.status <> 'cancelled'
  )
);

-- bookings ------------------------------------------------------------------
DROP POLICY IF EXISTS bookings_select ON bookings;
CREATE POLICY bookings_select ON bookings FOR SELECT USING (
  app_is_admin()
  OR driver_id = app_current_driver_id()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = bookings.load_id AND l.shipper_id = app_current_shipper_id()
  )
);

DROP POLICY IF EXISTS bookings_insert ON bookings;
CREATE POLICY bookings_insert ON bookings FOR INSERT WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id()
);

DROP POLICY IF EXISTS bookings_update ON bookings;
CREATE POLICY bookings_update ON bookings FOR UPDATE USING (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- settlements ---------------------------------------------------------------
-- Public ledger: readable by anyone, writable only by the driver who hauled it
-- (or an admin), and never updatable or deletable by anyone.
DROP POLICY IF EXISTS settlements_select ON settlements;
CREATE POLICY settlements_select ON settlements FOR SELECT USING (true);

DROP POLICY IF EXISTS settlements_insert ON settlements;
CREATE POLICY settlements_insert ON settlements FOR INSERT WITH CHECK (
  app_is_admin()
  OR EXISTS (
    SELECT 1 FROM bookings b
    WHERE b.id = settlements.booking_id AND b.driver_id = app_current_driver_id()
  )
);

-- platform_config -----------------------------------------------------------
-- Fee rates are world-readable and application-immutable; changing them is an
-- operator action performed as the owner role.
DROP POLICY IF EXISTS platform_config_select ON platform_config;
CREATE POLICY platform_config_select ON platform_config FOR SELECT USING (true);

-- audit_log -----------------------------------------------------------------
-- Not granted to the app role at all; this policy only scopes owner-level reads.
DROP POLICY IF EXISTS audit_log_select ON audit_log;
CREATE POLICY audit_log_select ON audit_log FOR SELECT USING (app_is_admin());

-- ---------------------------------------------------------------------------
-- 8. RESOURCE LIMITS FOR THE RUNTIME ROLE
-- ---------------------------------------------------------------------------
-- A runaway or hostile query cannot pin a connection indefinitely.
DO $$
BEGIN
  EXECUTE 'ALTER ROLE asoc_app SET statement_timeout = ''15s''';
  EXECUTE 'ALTER ROLE asoc_app SET idle_in_transaction_session_timeout = ''30s''';
  EXECUTE 'ALTER ROLE asoc_app SET lock_timeout = ''5s''';
EXCEPTION WHEN insufficient_privilege OR undefined_object THEN
  RAISE NOTICE 'Skipping role-level timeouts: not permitted on this server.';
END $$;
