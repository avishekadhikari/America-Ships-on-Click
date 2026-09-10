-- Carrier verification, and disputes against an immutable ledger.
--
-- Two holes this closes.
--
-- Verification: `driver_profiles.verification_status` existed but nothing ever
-- moved it, and the RLS UPDATE policy lets a driver write their own profile row
-- — which includes that column. A carrier could mark themselves verified. From
-- here the column is only writable by an admin, enforced by a trigger rather
-- than by convention, and every decision leaves a permanent review record.
--
-- Disputes: settlements are append-only by design, so "the fuel surcharge was
-- wrong" cannot be fixed by editing the row — that is the whole point of Open
-- Books. Corrections are therefore additive: a dispute is opened against a
-- settlement, and resolving it writes a signed adjustment that layers on top.
-- The original figure and the correction are both permanently visible.

-- ---------------------------------------------------------------------------
-- 1. VERIFICATION WORKFLOW
-- ---------------------------------------------------------------------------

ALTER TABLE driver_profiles ADD COLUMN IF NOT EXISTS verified_at      TIMESTAMP WITH TIME ZONE;
ALTER TABLE driver_profiles ADD COLUMN IF NOT EXISTS verified_by      TEXT;
ALTER TABLE driver_profiles ADD COLUMN IF NOT EXISTS rejection_reason TEXT;
ALTER TABLE driver_profiles ADD COLUMN IF NOT EXISTS insurance_expires_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE driver_documents ADD COLUMN IF NOT EXISTS review_status verification_status DEFAULT 'pending';
ALTER TABLE driver_documents ADD COLUMN IF NOT EXISTS reviewed_at   TIMESTAMP WITH TIME ZONE;
ALTER TABLE driver_documents ADD COLUMN IF NOT EXISTS reviewed_by   TEXT;
ALTER TABLE driver_documents ADD COLUMN IF NOT EXISTS review_notes  TEXT;
ALTER TABLE driver_documents ADD COLUMN IF NOT EXISTS expires_at    TIMESTAMP WITH TIME ZONE;

CREATE INDEX IF NOT EXISTS idx_driver_documents_queue
  ON driver_documents (review_status, uploaded_at);

CREATE TABLE IF NOT EXISTS verification_reviews (
  id               TEXT PRIMARY KEY,
  driver_id        TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  document_id      TEXT REFERENCES driver_documents(id) ON DELETE RESTRICT,
  reviewer_user_id TEXT,
  decision         verification_status NOT NULL,
  notes            TEXT,
  created_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_verification_reviews_driver
  ON verification_reviews (driver_id, created_at DESC);

DROP TRIGGER IF EXISTS verification_reviews_append_only ON verification_reviews;
CREATE TRIGGER verification_reviews_append_only BEFORE UPDATE OR DELETE ON verification_reviews
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Self-verification, closed at the source. The driver still owns their profile
-- row and may edit their name, equipment and contact details; the trust flag is
-- not theirs to set.
CREATE OR REPLACE FUNCTION driver_verification_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.verification_status IS DISTINCT FROM OLD.verification_status
     AND NOT app_is_admin()
     AND app_current_role() <> 'enrollment' THEN
    RAISE EXCEPTION 'verification_status is set by review, not by the carrier'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS driver_verification_guard_trg ON driver_profiles;
CREATE TRIGGER driver_verification_guard_trg BEFORE UPDATE ON driver_profiles
  FOR EACH ROW EXECUTE FUNCTION driver_verification_guard();

-- Records a document decision and rolls it up to the carrier's overall status.
-- One rejected document rejects the carrier; a carrier is verified once every
-- document they have uploaded is verified and the required set is present.
CREATE OR REPLACE FUNCTION app_review_driver_document(
  p_document_id TEXT, p_decision verification_status, p_notes TEXT
) RETURNS TABLE(driver_id TEXT, document_status verification_status, driver_status verification_status)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  doc            driver_documents%ROWTYPE;
  rolled_up      verification_status;
  has_rejected   BOOLEAN;
  pending_count  INTEGER;
  verified_types INTEGER;
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Only an administrator may review carrier documents'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO doc FROM driver_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document not found' USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE driver_documents
     SET review_status = p_decision,
         verified      = (p_decision = 'verified'),
         reviewed_at   = now(),
         reviewed_by   = app_current_user_id(),
         review_notes  = p_notes
   WHERE id = p_document_id;

  INSERT INTO verification_reviews (id, driver_id, document_id, reviewer_user_id, decision, notes)
  VALUES ('vrv-' || md5(random()::text || clock_timestamp()::text),
          doc.driver_id, p_document_id, app_current_user_id(), p_decision, p_notes);

  SELECT
    bool_or(review_status = 'rejected'),
    count(*) FILTER (WHERE review_status = 'pending'),
    count(DISTINCT doc_type) FILTER (WHERE review_status = 'verified' AND doc_type <> 'pod')
  INTO has_rejected, pending_count, verified_types
  FROM driver_documents WHERE driver_documents.driver_id = doc.driver_id;

  rolled_up := CASE
    WHEN has_rejected THEN 'rejected'
    WHEN pending_count > 0 THEN 'pending'
    -- CDL, operating authority and a certificate of insurance: the three
    -- documents a shipper is entitled to assume exist.
    WHEN verified_types >= 3 THEN 'verified'
    ELSE 'pending'
  END::verification_status;

  UPDATE driver_profiles
     SET verification_status = rolled_up,
         verified_at = CASE WHEN rolled_up = 'verified' THEN now() ELSE NULL END,
         verified_by = CASE WHEN rolled_up = 'verified' THEN app_current_user_id() ELSE NULL END,
         rejection_reason = CASE WHEN rolled_up = 'rejected' THEN p_notes ELSE NULL END
   WHERE id = doc.driver_id;

  PERFORM app_notify(
    (SELECT user_id FROM driver_profiles WHERE id = doc.driver_id),
    'verification_' || rolled_up::TEXT,
    'Carrier verification ' || rolled_up::TEXT,
    COALESCE(p_notes, ''), '/onboarding', NULL,
    CASE rolled_up WHEN 'verified' THEN 'success' WHEN 'rejected' THEN 'critical' ELSE 'info' END
  );

  RETURN QUERY SELECT doc.driver_id, p_decision, rolled_up;
END $$;

-- Manual override for support cases the document flow does not cover.
CREATE OR REPLACE FUNCTION app_set_driver_verification(
  p_driver_id TEXT, p_status verification_status, p_reason TEXT
) RETURNS verification_status
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Only an administrator may set carrier verification'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE driver_profiles
     SET verification_status = p_status,
         verified_at = CASE WHEN p_status = 'verified' THEN now() ELSE NULL END,
         verified_by = CASE WHEN p_status = 'verified' THEN app_current_user_id() ELSE NULL END,
         rejection_reason = CASE WHEN p_status = 'rejected' THEN p_reason ELSE NULL END
   WHERE id = p_driver_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carrier not found' USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO verification_reviews (id, driver_id, document_id, reviewer_user_id, decision, notes)
  VALUES ('vrv-' || md5(random()::text || clock_timestamp()::text),
          p_driver_id, NULL, app_current_user_id(), p_status, p_reason);

  PERFORM app_notify(
    (SELECT user_id FROM driver_profiles WHERE id = p_driver_id),
    'verification_' || p_status::TEXT,
    'Carrier verification ' || p_status::TEXT,
    COALESCE(p_reason, ''), '/onboarding', NULL,
    CASE p_status WHEN 'verified' THEN 'success' WHEN 'rejected' THEN 'critical' ELSE 'info' END
  );

  RETURN p_status;
END $$;

GRANT EXECUTE ON FUNCTION app_review_driver_document(TEXT, verification_status, TEXT) TO asoc_app;
GRANT EXECUTE ON FUNCTION app_set_driver_verification(TEXT, verification_status, TEXT) TO asoc_app;
GRANT SELECT ON verification_reviews TO asoc_app;

ALTER TABLE verification_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS verification_reviews_select ON verification_reviews;
CREATE POLICY verification_reviews_select ON verification_reviews FOR SELECT USING (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- Off by default so existing demo accounts keep booking. Turn it on and an
-- unverified carrier cannot take freight.
INSERT INTO platform_config (key, value) VALUES ('require_driver_verification', 0)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. DISPUTES AND ADJUSTMENTS
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  CREATE TYPE dispute_status AS ENUM ('open', 'under_review', 'resolved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS settlement_disputes (
  id                 TEXT PRIMARY KEY,
  settlement_id      TEXT NOT NULL REFERENCES settlements(id) ON DELETE RESTRICT,
  load_id            TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  opened_by_user_id  TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  opened_by_role     TEXT NOT NULL CHECK (opened_by_role IN ('driver', 'shipper', 'admin')),
  category           TEXT NOT NULL CHECK (category IN (
                       'rate', 'miles', 'fuel', 'detention', 'damage', 'fee', 'other')),
  reason             TEXT NOT NULL CHECK (length(reason) BETWEEN 10 AND 4000),
  claimed_amount     NUMERIC CHECK (claimed_amount IS NULL OR claimed_amount >= 0),
  status             dispute_status NOT NULL DEFAULT 'open',
  resolution_note    TEXT,
  resolved_at        TIMESTAMP WITH TIME ZONE,
  resolved_by        TEXT,
  created_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- One live dispute per settlement per party.
CREATE UNIQUE INDEX IF NOT EXISTS idx_dispute_one_open_per_party
  ON settlement_disputes (settlement_id, opened_by_user_id)
  WHERE status IN ('open', 'under_review');

CREATE INDEX IF NOT EXISTS idx_disputes_queue ON settlement_disputes (status, created_at);

-- Corrections to an immutable ledger, as their own permanent rows. Positive
-- amounts pay the carrier more, negative claw back.
CREATE TABLE IF NOT EXISTS settlement_adjustments (
  id            TEXT PRIMARY KEY,
  settlement_id TEXT NOT NULL REFERENCES settlements(id) ON DELETE RESTRICT,
  dispute_id    TEXT REFERENCES settlement_disputes(id) ON DELETE RESTRICT,
  amount        NUMERIC NOT NULL CHECK (amount <> 0),
  reason        TEXT NOT NULL,
  created_by    TEXT,
  created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_adjustments_settlement
  ON settlement_adjustments (settlement_id, created_at);

DROP TRIGGER IF EXISTS settlement_adjustments_append_only ON settlement_adjustments;
CREATE TRIGGER settlement_adjustments_append_only BEFORE UPDATE OR DELETE ON settlement_adjustments
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

DROP TRIGGER IF EXISTS audit_disputes ON settlement_disputes;
CREATE TRIGGER audit_disputes AFTER INSERT OR UPDATE OR DELETE ON settlement_disputes
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS audit_adjustments ON settlement_adjustments;
CREATE TRIGGER audit_adjustments AFTER INSERT OR UPDATE OR DELETE ON settlement_adjustments
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- The ledger as it stands today: the original settlement, plus every
-- correction ever applied to it, with both halves still legible.
CREATE OR REPLACE VIEW settlement_effective_view AS
SELECT
  s.id,
  s.load_id,
  s.booking_id,
  l.origin_city, l.origin_state, l.dest_city, l.dest_state, l.equipment_type,
  s.miles, s.rate_per_mile, s.fuel_rate_per_mile,
  s.gross_amount, s.fee_amount, s.fee_pct_applied, s.fuel_cost, s.factor_cost,
  s.factored,
  s.net_amount                                        AS original_net_amount,
  COALESCE(adj.total, 0)                              AS adjustment_total,
  s.net_amount + COALESCE(adj.total, 0)               AS effective_net_amount,
  COALESCE(adj.count, 0)::INTEGER                     AS adjustment_count,
  COALESCE(dsp.open_count, 0)::INTEGER                AS open_dispute_count,
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

-- Resolves a dispute and applies its correction in one transaction, so a
-- settlement is never marked resolved without the money moving with it.
CREATE OR REPLACE FUNCTION app_resolve_dispute(
  p_dispute_id TEXT, p_status dispute_status, p_note TEXT, p_adjustment NUMERIC
) RETURNS TABLE(dispute_id TEXT, status dispute_status, adjustment_id TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  dsp    settlement_disputes%ROWTYPE;
  adj_id TEXT;
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Only an administrator may resolve a dispute'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_status NOT IN ('under_review', 'resolved', 'rejected') THEN
    RAISE EXCEPTION 'A dispute can only move to under_review, resolved or rejected'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO dsp FROM settlement_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispute not found' USING ERRCODE = 'no_data_found';
  END IF;

  IF dsp.status IN ('resolved', 'rejected') THEN
    RAISE EXCEPTION 'Dispute is already %', dsp.status USING ERRCODE = 'check_violation';
  END IF;

  IF p_adjustment IS NOT NULL AND p_adjustment <> 0 THEN
    IF p_status <> 'resolved' THEN
      RAISE EXCEPTION 'An adjustment can only accompany a resolved dispute'
        USING ERRCODE = 'check_violation';
    END IF;
    adj_id := 'adj-' || md5(random()::text || clock_timestamp()::text);
    INSERT INTO settlement_adjustments (id, settlement_id, dispute_id, amount, reason, created_by)
    VALUES (adj_id, dsp.settlement_id, dsp.id, p_adjustment,
            COALESCE(p_note, 'Dispute resolution'), app_current_user_id());
  END IF;

  UPDATE settlement_disputes
     SET status = p_status,
         resolution_note = p_note,
         resolved_at = CASE WHEN p_status IN ('resolved', 'rejected') THEN now() ELSE NULL END,
         resolved_by = CASE WHEN p_status IN ('resolved', 'rejected') THEN app_current_user_id() ELSE NULL END,
         updated_at = now()
   WHERE id = p_dispute_id;

  PERFORM app_log_load_event(
    dsp.load_id, NULL,
    CASE WHEN p_status = 'under_review' THEN 'disputed' ELSE 'dispute_resolved' END::load_event_type,
    dsp.status::TEXT, p_status::TEXT, p_note, NULL, NULL,
    jsonb_build_object('dispute_id', dsp.id, 'adjustment', COALESCE(p_adjustment, 0))
  );

  PERFORM app_notify(dsp.opened_by_user_id, 'dispute_' || p_status::TEXT,
    'Dispute ' || p_status::TEXT, COALESCE(p_note, ''),
    '/settlements/' || dsp.settlement_id, dsp.load_id,
    CASE p_status WHEN 'resolved' THEN 'success' WHEN 'rejected' THEN 'warning' ELSE 'info' END);

  RETURN QUERY SELECT dsp.id, p_status, adj_id;
END $$;

GRANT EXECUTE ON FUNCTION app_resolve_dispute(TEXT, dispute_status, TEXT, NUMERIC) TO asoc_app;

GRANT SELECT, INSERT ON settlement_disputes TO asoc_app;
GRANT SELECT ON settlement_adjustments TO asoc_app;
GRANT SELECT ON settlement_effective_view TO asoc_app;

ALTER TABLE settlement_disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_adjustments ENABLE ROW LEVEL SECURITY;

-- Visible to the parties to the load and to admins. Not public: a dispute is an
-- allegation, and the ledger publishes the outcome, not the argument.
DROP POLICY IF EXISTS settlement_disputes_select ON settlement_disputes;
CREATE POLICY settlement_disputes_select ON settlement_disputes FOR SELECT USING (
  app_is_admin()
  OR opened_by_user_id = app_current_user_id()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = settlement_disputes.load_id AND l.shipper_id = app_current_shipper_id()
  )
  OR EXISTS (
    SELECT 1 FROM settlements s JOIN bookings b ON b.id = s.booking_id
    WHERE s.id = settlement_disputes.settlement_id AND b.driver_id = app_current_driver_id()
  )
);

DROP POLICY IF EXISTS settlement_disputes_insert ON settlement_disputes;
CREATE POLICY settlement_disputes_insert ON settlement_disputes FOR INSERT WITH CHECK (
  opened_by_user_id = app_current_user_id()
  AND (
    app_is_admin()
    OR EXISTS (
      SELECT 1 FROM loads l
      WHERE l.id = settlement_disputes.load_id AND l.shipper_id = app_current_shipper_id()
    )
    OR EXISTS (
      SELECT 1 FROM settlements s JOIN bookings b ON b.id = s.booking_id
      WHERE s.id = settlement_disputes.settlement_id AND b.driver_id = app_current_driver_id()
    )
  )
);

-- Adjustments are part of the public record, exactly like the settlements they
-- correct: an Open Books ledger that hid its corrections would not be open.
DROP POLICY IF EXISTS settlement_adjustments_select ON settlement_adjustments;
CREATE POLICY settlement_adjustments_select ON settlement_adjustments FOR SELECT USING (true);
