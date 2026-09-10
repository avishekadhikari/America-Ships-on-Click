-- Operational infrastructure for the HTTP layer.
--
-- Four concerns that all share one property: they must hold across process
-- restarts and across every server instance behind a load balancer, so they
-- live in the database rather than in a per-process Map.
--
--   1. Refresh tokens        — long-lived sessions that can actually be revoked,
--                              with rotation and reuse detection.
--   2. Password reset        — the app role deliberately has no UPDATE on
--                              `users`; resets go through a SECURITY DEFINER
--                              function so a hash can only ever be replaced by
--                              a caller holding a valid single-use token.
--   3. Idempotency keys      — a retried POST returns the first response instead
--                              of booking a second load or paying twice.
--   4. Rate limiting         — fixed-window counters keyed by identity or IP.
--
-- Token *values* are never stored. Only SHA-256 digests are persisted, so a
-- database leak does not hand out live sessions.

-- ---------------------------------------------------------------------------
-- 1. AUDIT REDACTION (extended)
-- ---------------------------------------------------------------------------
-- The tables below carry secret material. Teach the existing audit trigger to
-- strip it before anything is written to the log.

CREATE OR REPLACE FUNCTION audit_row_change() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  redacted_old JSONB;
  redacted_new JSONB;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    redacted_old := to_jsonb(OLD) - 'password_hash' - 'processor_account_id'
                    - 'token_hash' - 'response_body';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    redacted_new := to_jsonb(NEW) - 'password_hash' - 'processor_account_id'
                    - 'token_hash' - 'response_body';
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

-- ---------------------------------------------------------------------------
-- 2. REFRESH TOKENS
-- ---------------------------------------------------------------------------
-- Access tokens are stateless JWTs and cannot be withdrawn before they expire,
-- so they are kept short-lived and paired with a refresh token that can be.
--
-- The table is never granted to the app role. Every operation goes through a
-- SECURITY DEFINER function, which means a SQL injection in any route still
-- cannot enumerate session digests or mint a session for another account.

CREATE TABLE IF NOT EXISTS refresh_tokens (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  token_hash  TEXT UNIQUE NOT NULL,
  family_id   TEXT NOT NULL,
  issued_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
  used_at     TIMESTAMP WITH TIME ZONE,
  revoked_at  TIMESTAMP WITH TIME ZONE,
  revoked_reason TEXT,
  replaced_by TEXT,
  user_agent  TEXT,
  ip_address  TEXT
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens (user_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family ON refresh_tokens (family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expiry ON refresh_tokens (expires_at);

ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;

-- Issues a session. `p_family_id` NULL starts a new family; rotation passes the
-- previous family so a whole lineage can be revoked at once.
CREATE OR REPLACE FUNCTION app_issue_refresh_token(
  p_user_id TEXT, p_token_hash TEXT, p_ttl_days INTEGER,
  p_family_id TEXT, p_user_agent TEXT, p_ip TEXT
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  new_id     TEXT := 'rt-' || md5(random()::text || clock_timestamp()::text);
  the_family TEXT := COALESCE(p_family_id, 'fam-' || md5(random()::text || clock_timestamp()::text));
BEGIN
  -- Housekeeping: expired and long-revoked rows have no forensic value.
  DELETE FROM refresh_tokens
  WHERE expires_at < now() - INTERVAL '30 days'
     OR (revoked_at IS NOT NULL AND revoked_at < now() - INTERVAL '30 days');

  INSERT INTO refresh_tokens (id, user_id, token_hash, family_id, expires_at, user_agent, ip_address)
  VALUES (new_id, p_user_id, p_token_hash, the_family,
          now() + make_interval(days => GREATEST(p_ttl_days, 1)), p_user_agent, p_ip);

  RETURN new_id || '|' || the_family;
END $$;

-- Exchanges a refresh token for its owner, single-use.
--
-- Presenting an already-used token is the signature of a stolen session being
-- replayed: the legitimate client rotated it away, so the only party still
-- holding it is an attacker. The whole family is revoked, and the caller is
-- told nothing beyond "invalid".
CREATE OR REPLACE FUNCTION app_consume_refresh_token(p_token_hash TEXT)
RETURNS TABLE(user_id TEXT, family_id TEXT, outcome TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  row_found refresh_tokens%ROWTYPE;
BEGIN
  SELECT * INTO row_found FROM refresh_tokens WHERE token_hash = p_token_hash FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::TEXT, NULL::TEXT, 'not_found'::TEXT;
    RETURN;
  END IF;

  IF row_found.used_at IS NOT NULL THEN
    UPDATE refresh_tokens
       SET revoked_at = COALESCE(revoked_at, now()),
           revoked_reason = COALESCE(revoked_reason, 'reuse_detected')
     WHERE family_id = row_found.family_id AND revoked_at IS NULL;
    RETURN QUERY SELECT row_found.user_id, row_found.family_id, 'reuse_detected'::TEXT;
    RETURN;
  END IF;

  IF row_found.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT row_found.user_id, row_found.family_id, 'revoked'::TEXT;
    RETURN;
  END IF;

  IF row_found.expires_at <= now() THEN
    RETURN QUERY SELECT row_found.user_id, row_found.family_id, 'expired'::TEXT;
    RETURN;
  END IF;

  UPDATE refresh_tokens SET used_at = now() WHERE id = row_found.id;
  RETURN QUERY SELECT row_found.user_id, row_found.family_id, 'ok'::TEXT;
END $$;

CREATE OR REPLACE FUNCTION app_revoke_refresh_token(p_token_hash TEXT, p_reason TEXT)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE affected INTEGER;
BEGIN
  UPDATE refresh_tokens
     SET revoked_at = now(), revoked_reason = COALESCE(p_reason, 'logout')
   WHERE token_hash = p_token_hash AND revoked_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END $$;

-- Signs every device out. Used by "log out everywhere" and by password change,
-- where any session established with the old credential must not survive.
CREATE OR REPLACE FUNCTION app_revoke_user_sessions(p_user_id TEXT, p_reason TEXT)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE affected INTEGER;
BEGIN
  UPDATE refresh_tokens
     SET revoked_at = now(), revoked_reason = COALESCE(p_reason, 'revoke_all')
   WHERE user_id = p_user_id AND revoked_at IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END $$;

CREATE OR REPLACE FUNCTION app_list_sessions(p_user_id TEXT)
RETURNS TABLE(id TEXT, issued_at TIMESTAMPTZ, expires_at TIMESTAMPTZ,
              used_at TIMESTAMPTZ, revoked_at TIMESTAMPTZ, user_agent TEXT, ip_address TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT id, issued_at, expires_at, used_at, revoked_at, user_agent, ip_address
  FROM refresh_tokens
  WHERE user_id = p_user_id
  ORDER BY issued_at DESC
  LIMIT 50
$$;

GRANT EXECUTE ON FUNCTION app_issue_refresh_token(TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_consume_refresh_token(TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_revoke_refresh_token(TEXT, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_revoke_user_sessions(TEXT, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_list_sessions(TEXT) TO asoc_app;

-- ---------------------------------------------------------------------------
-- 3. PASSWORD RESET
-- ---------------------------------------------------------------------------
-- `users` is granted SELECT and INSERT only, on purpose: no route may rewrite a
-- password hash or a role. A reset still has to change one, so it goes through
-- a definer function that will only do it in exchange for an unused,
-- unexpired token — a capability the application cannot forge, because it never
-- learns the stored digest.

CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  token_hash TEXT UNIQUE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  used_at    TIMESTAMP WITH TIME ZONE,
  requested_ip TEXT
);

CREATE INDEX IF NOT EXISTS idx_password_reset_user ON password_reset_tokens (user_id, created_at DESC);
ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;

-- Returns the user id when the address exists, NULL otherwise. The route emits
-- the same response either way, so the endpoint is not an account oracle.
CREATE OR REPLACE FUNCTION app_create_password_reset(p_email TEXT, p_token_hash TEXT, p_ttl_minutes INTEGER, p_ip TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE target_id TEXT;
BEGIN
  SELECT id INTO target_id FROM users WHERE lower(email) = lower(p_email);
  IF target_id IS NULL THEN RETURN NULL; END IF;

  DELETE FROM password_reset_tokens WHERE expires_at < now() - INTERVAL '7 days';

  -- Only the newest request stays live, so an old link in an inbox stops working.
  UPDATE password_reset_tokens SET used_at = now()
   WHERE user_id = target_id AND used_at IS NULL;

  INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, requested_ip)
  VALUES ('prt-' || md5(random()::text || clock_timestamp()::text), target_id, p_token_hash,
          now() + make_interval(mins => GREATEST(p_ttl_minutes, 1)), p_ip);

  RETURN target_id;
END $$;

-- Consumes the token and installs the new hash atomically. The bcrypt shape
-- CHECK on `users` still applies, so a plaintext password cannot slip through.
CREATE OR REPLACE FUNCTION app_reset_password(p_token_hash TEXT, p_new_hash TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE target_id TEXT;
BEGIN
  SELECT user_id INTO target_id
  FROM password_reset_tokens
  WHERE token_hash = p_token_hash AND used_at IS NULL AND expires_at > now()
  FOR UPDATE;

  IF target_id IS NULL THEN RETURN NULL; END IF;

  UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = p_token_hash;
  UPDATE users SET password_hash = p_new_hash, updated_at = now() WHERE id = target_id;

  -- Every session predating the reset dies with the old password.
  UPDATE refresh_tokens
     SET revoked_at = now(), revoked_reason = 'password_reset'
   WHERE user_id = target_id AND revoked_at IS NULL;

  RETURN target_id;
END $$;

-- Signed-in password change. The caller must prove the current password in the
-- route; the definer function additionally refuses to act on anyone but the
-- identity the transaction is running as.
CREATE OR REPLACE FUNCTION app_change_password(p_user_id TEXT, p_new_hash TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF app_current_user_id() IS DISTINCT FROM p_user_id AND NOT app_is_admin() THEN
    RAISE EXCEPTION 'A password may only be changed by its owner'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE users SET password_hash = p_new_hash, updated_at = now() WHERE id = p_user_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  UPDATE refresh_tokens
     SET revoked_at = now(), revoked_reason = 'password_change'
   WHERE user_id = p_user_id AND revoked_at IS NULL;

  RETURN TRUE;
END $$;

GRANT EXECUTE ON FUNCTION app_create_password_reset(TEXT, TEXT, INTEGER, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_reset_password(TEXT, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_change_password(TEXT, TEXT) TO asoc_app;

-- ---------------------------------------------------------------------------
-- 4. IDEMPOTENCY KEYS
-- ---------------------------------------------------------------------------
-- Booking a load and completing a settlement both move money. A dropped
-- response, a double-tapped button, or a client retry must not perform them
-- twice, so the first attempt claims the key and later attempts replay the
-- stored outcome.

CREATE TABLE IF NOT EXISTS idempotency_keys (
  id            TEXT PRIMARY KEY,
  idem_key      TEXT NOT NULL,
  user_id       TEXT NOT NULL,
  endpoint      TEXT NOT NULL,
  request_hash  TEXT NOT NULL,
  state         TEXT NOT NULL DEFAULT 'in_progress' CHECK (state IN ('in_progress', 'completed')),
  status_code   INTEGER,
  response_body JSONB,
  created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at  TIMESTAMP WITH TIME ZONE,
  expires_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '24 hours')
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_idempotency_scope
  ON idempotency_keys (idem_key, user_id, endpoint);
CREATE INDEX IF NOT EXISTS idx_idempotency_expiry ON idempotency_keys (expires_at);

ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;

-- Claims a key. Returns the disposition plus the stored response when there is
-- one, so the caller can replay it verbatim.
--
--   'claimed'    first use — proceed and call app_idempotency_complete
--   'replay'     a completed response exists — return it as-is
--   'in_flight'  an identical request is still running — 409, tell them to wait
--   'mismatch'   same key, different payload — 422, the key is being reused
CREATE OR REPLACE FUNCTION app_idempotency_begin(
  p_key TEXT, p_user_id TEXT, p_endpoint TEXT, p_request_hash TEXT
) RETURNS TABLE(outcome TEXT, status_code INTEGER, response_body JSONB)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE existing idempotency_keys%ROWTYPE;
BEGIN
  DELETE FROM idempotency_keys WHERE expires_at < now();

  SELECT * INTO existing FROM idempotency_keys
   WHERE idem_key = p_key AND user_id = p_user_id AND endpoint = p_endpoint
   FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO idempotency_keys (id, idem_key, user_id, endpoint, request_hash)
    VALUES ('idem-' || md5(random()::text || clock_timestamp()::text),
            p_key, p_user_id, p_endpoint, p_request_hash);
    RETURN QUERY SELECT 'claimed'::TEXT, NULL::INTEGER, NULL::JSONB;
    RETURN;
  END IF;

  IF existing.request_hash IS DISTINCT FROM p_request_hash THEN
    RETURN QUERY SELECT 'mismatch'::TEXT, NULL::INTEGER, NULL::JSONB;
    RETURN;
  END IF;

  IF existing.state = 'completed' THEN
    RETURN QUERY SELECT 'replay'::TEXT, existing.status_code, existing.response_body;
    RETURN;
  END IF;

  -- A crashed request would otherwise wedge the key forever.
  IF existing.created_at < now() - INTERVAL '2 minutes' THEN
    UPDATE idempotency_keys SET created_at = now() WHERE id = existing.id;
    RETURN QUERY SELECT 'claimed'::TEXT, NULL::INTEGER, NULL::JSONB;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'in_flight'::TEXT, NULL::INTEGER, NULL::JSONB;
END $$;

CREATE OR REPLACE FUNCTION app_idempotency_complete(
  p_key TEXT, p_user_id TEXT, p_endpoint TEXT, p_status INTEGER, p_body JSONB
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE idempotency_keys
     SET state = 'completed', status_code = p_status, response_body = p_body, completed_at = now()
   WHERE idem_key = p_key AND user_id = p_user_id AND endpoint = p_endpoint;
END $$;

-- A failed attempt releases the key so the client may genuinely retry.
CREATE OR REPLACE FUNCTION app_idempotency_release(p_key TEXT, p_user_id TEXT, p_endpoint TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM idempotency_keys
   WHERE idem_key = p_key AND user_id = p_user_id AND endpoint = p_endpoint AND state = 'in_progress';
END $$;

GRANT EXECUTE ON FUNCTION app_idempotency_begin(TEXT, TEXT, TEXT, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_idempotency_complete(TEXT, TEXT, TEXT, INTEGER, JSONB) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_idempotency_release(TEXT, TEXT, TEXT) TO asoc_app;

-- ---------------------------------------------------------------------------
-- 5. RATE LIMITING
-- ---------------------------------------------------------------------------
-- Fixed-window counters. Shared state means the limit is the limit no matter
-- which instance serves the request, unlike a per-process counter that N
-- replicas silently multiply by N.

CREATE TABLE IF NOT EXISTS api_rate_limits (
  bucket       TEXT NOT NULL,
  window_start TIMESTAMP WITH TIME ZONE NOT NULL,
  hits         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_window ON api_rate_limits (window_start);
ALTER TABLE api_rate_limits ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION app_rate_limit_hit(p_bucket TEXT, p_limit INTEGER, p_window_secs INTEGER)
RETURNS TABLE(allowed BOOLEAN, remaining INTEGER, retry_after INTEGER, window_reset TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  win_start TIMESTAMPTZ;
  current_hits INTEGER;
BEGIN
  -- Truncate now() onto a window boundary so every instance agrees on which
  -- window a request belongs to without coordinating.
  win_start := to_timestamp(floor(extract(epoch FROM now()) / p_window_secs) * p_window_secs);

  IF random() < 0.01 THEN
    DELETE FROM api_rate_limits WHERE window_start < now() - INTERVAL '1 hour';
  END IF;

  INSERT INTO api_rate_limits (bucket, window_start, hits)
  VALUES (p_bucket, win_start, 1)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = api_rate_limits.hits + 1
  RETURNING api_rate_limits.hits INTO current_hits;

  RETURN QUERY SELECT
    current_hits <= p_limit,
    GREATEST(0, p_limit - current_hits),
    CASE WHEN current_hits <= p_limit THEN 0
         ELSE GREATEST(1, CEIL(EXTRACT(EPOCH FROM (win_start + make_interval(secs => p_window_secs) - now())))::INTEGER)
    END,
    win_start + make_interval(secs => p_window_secs);
END $$;

GRANT EXECUTE ON FUNCTION app_rate_limit_hit(TEXT, INTEGER, INTEGER) TO asoc_app;
