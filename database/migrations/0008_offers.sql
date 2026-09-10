-- Rate negotiation.
--
-- The board is take-it-or-leave-it today: a driver either books at the posted
-- rate or moves on, and a shipper never hears what the load was actually worth.
-- An offer is a driver's counter-proposal that the shipper can accept, decline,
-- or let expire.
--
-- Acceptance is the interesting half. It has to lock the load, create a booking
-- *on the driver's behalf*, record the agreed rate, and knock back competing
-- offers — atomically, and while the caller is the shipper rather than the
-- driver whose booking is being written. Row-Level Security correctly forbids
-- one party writing another's booking row, so the whole operation is one
-- SECURITY DEFINER function that authorizes the caller itself.

DO $$
BEGIN
  CREATE TYPE offer_status AS ENUM ('pending', 'accepted', 'declined', 'withdrawn', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS load_offers (
  id                   TEXT PRIMARY KEY,
  load_id              TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  driver_id            TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  offered_rate_per_mile NUMERIC NOT NULL CHECK (offered_rate_per_mile > 0),
  message              TEXT,
  status               offer_status NOT NULL DEFAULT 'pending',
  expires_at           TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '48 hours'),
  created_at           TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  responded_at         TIMESTAMP WITH TIME ZONE,
  responded_by         TEXT,
  response_note        TEXT
);

-- One live offer per driver per load: a new price replaces the old one rather
-- than stacking up a queue of bids from the same carrier.
CREATE UNIQUE INDEX IF NOT EXISTS idx_offer_one_pending_per_driver
  ON load_offers (load_id, driver_id) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_offers_load ON load_offers (load_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_offers_driver ON load_offers (driver_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_offers_expiry ON load_offers (expires_at) WHERE status = 'pending';

DROP TRIGGER IF EXISTS audit_load_offers ON load_offers;
CREATE TRIGGER audit_load_offers AFTER INSERT OR UPDATE OR DELETE ON load_offers
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- ---------------------------------------------------------------------------
-- Expiry
-- ---------------------------------------------------------------------------
-- Swept lazily by readers rather than by a scheduler, so an expired offer is
-- never observable as pending even with no cron running anywhere.

CREATE OR REPLACE FUNCTION app_expire_stale_offers() RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE affected INTEGER;
BEGIN
  UPDATE load_offers SET status = 'expired', responded_at = now()
   WHERE status = 'pending' AND expires_at <= now();
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END $$;

GRANT EXECUTE ON FUNCTION app_expire_stale_offers() TO asoc_app;

-- ---------------------------------------------------------------------------
-- Acceptance
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_accept_offer(p_offer_id TEXT, p_note TEXT)
RETURNS TABLE(booking_id TEXT, load_id TEXT, driver_id TEXT, agreed_rate NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  offer      load_offers%ROWTYPE;
  the_load   loads%ROWTYPE;
  new_booking TEXT;
BEGIN
  SELECT * INTO offer FROM load_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offer not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Lock the load before authorizing, so two shippers' clients accepting two
  -- offers on the same load serialize here instead of both proceeding.
  SELECT * INTO the_load FROM loads WHERE id = offer.load_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Load not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Definer functions run as the owner and bypass RLS, so authorization is
  -- explicit: only the shipper who posted the load, or an admin.
  IF NOT app_is_admin() AND the_load.shipper_id IS DISTINCT FROM app_current_shipper_id() THEN
    RAISE EXCEPTION 'Only the shipper who posted this load may accept offers on it'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF offer.status <> 'pending' THEN
    RAISE EXCEPTION 'Offer is % and can no longer be accepted', offer.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF offer.expires_at <= now() THEN
    UPDATE load_offers SET status = 'expired', responded_at = now() WHERE id = offer.id;
    RAISE EXCEPTION 'Offer has expired' USING ERRCODE = 'check_violation';
  END IF;

  IF the_load.status <> 'open' THEN
    RAISE EXCEPTION 'Load is % and can no longer be booked', the_load.status
      USING ERRCODE = 'check_violation';
  END IF;

  new_booking := 'BK-' || md5(random()::text || clock_timestamp()::text);

  INSERT INTO bookings (id, load_id, driver_id, status, agreed_rate_per_mile)
  VALUES (new_booking, offer.load_id, offer.driver_id, 'active', offer.offered_rate_per_mile);

  UPDATE loads SET status = 'booked' WHERE id = offer.load_id;

  UPDATE load_offers
     SET status = 'accepted', responded_at = now(),
         responded_by = app_current_user_id(), response_note = p_note
   WHERE id = offer.id;

  -- Everyone else who bid on this load is out; leaving them pending would show
  -- carriers a live offer on a load that is already gone.
  UPDATE load_offers
     SET status = 'declined', responded_at = now(),
         responded_by = app_current_user_id(),
         response_note = 'Load awarded to another carrier'
   WHERE load_id = offer.load_id AND id <> offer.id AND status = 'pending';

  PERFORM app_log_load_event(
    offer.load_id, new_booking, 'offer_accepted', the_load.status::TEXT, 'booked', p_note,
    NULL, NULL,
    jsonb_build_object('offer_id', offer.id,
                       'posted_rate', the_load.rate_per_mile,
                       'agreed_rate', offer.offered_rate_per_mile)
  );

  RETURN QUERY SELECT new_booking, offer.load_id, offer.driver_id, offer.offered_rate_per_mile;
END $$;

GRANT EXECUTE ON FUNCTION app_accept_offer(TEXT, TEXT) TO asoc_app;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE ON load_offers TO asoc_app;
ALTER TABLE load_offers ENABLE ROW LEVEL SECURITY;

-- A carrier sees their own bids. A shipper sees every bid on their own loads —
-- and nothing on anyone else's, so rival carriers' pricing stays private.
DROP POLICY IF EXISTS load_offers_select ON load_offers;
CREATE POLICY load_offers_select ON load_offers FOR SELECT USING (
  app_is_admin()
  OR driver_id = app_current_driver_id()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = load_offers.load_id AND l.shipper_id = app_current_shipper_id()
  )
);

DROP POLICY IF EXISTS load_offers_insert ON load_offers;
CREATE POLICY load_offers_insert ON load_offers FOR INSERT WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- A driver may withdraw their own; a shipper may respond to one on their load.
DROP POLICY IF EXISTS load_offers_update ON load_offers;
CREATE POLICY load_offers_update ON load_offers FOR UPDATE USING (
  app_is_admin()
  OR driver_id = app_current_driver_id()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = load_offers.load_id AND l.shipper_id = app_current_shipper_id()
  )
) WITH CHECK (
  app_is_admin()
  OR driver_id = app_current_driver_id()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = load_offers.load_id AND l.shipper_id = app_current_shipper_id()
  )
);
