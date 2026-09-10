-- The full life of a load, and an append-only record of how it got there.
--
-- Before this migration a load could only travel open -> booked -> delivered,
-- and nothing could be cancelled: a shipper whose customer pulled the order had
-- no way to withdraw it, and a driver who broke down could not hand it back.
-- The `in_transit` status existed in the enum but nothing ever set it.
--
-- Two rules make the timeline trustworthy:
--
--   * Transitions are checked by a trigger, not by the application. An illegal
--     jump (delivered -> open, cancelling a load that already settled) is
--     rejected by the database whatever the route does.
--   * Every transition writes a `load_events` row from the same trigger, so the
--     history cannot be edited, forged, or quietly skipped.

-- ---------------------------------------------------------------------------
-- 1. COLUMNS
-- ---------------------------------------------------------------------------

ALTER TABLE loads ADD COLUMN IF NOT EXISTS delivery_date       TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS commodity           TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS reference_number    TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS cancelled_at        TIMESTAMP WITH TIME ZONE;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS updated_at          TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS picked_up_at         TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_at         TIMESTAMP WITH TIME ZONE;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancellation_reason  TEXT;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_by         TEXT;

-- The rate a load actually pays can differ from the posted rate once an offer
-- is accepted (migration 0008). Settlement reads this first and falls back to
-- the posted rate, so historical bookings keep settling exactly as before.
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS agreed_rate_per_mile NUMERIC;

DO $$
BEGIN
  ALTER TABLE bookings ADD CONSTRAINT bookings_agreed_rate_positive
    CHECK (agreed_rate_per_mile IS NULL OR agreed_rate_per_mile > 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- 2. EVENT TIMELINE
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  CREATE TYPE load_event_type AS ENUM (
    'posted', 'updated', 'booked', 'picked_up', 'in_transit', 'delivered',
    'settled', 'cancelled', 'offer_made', 'offer_accepted', 'offer_declined',
    'offer_withdrawn', 'document_uploaded', 'disputed', 'dispute_resolved', 'note'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS load_events (
  id             TEXT PRIMARY KEY,
  load_id        TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  booking_id     TEXT REFERENCES bookings(id) ON DELETE RESTRICT,
  event_type     load_event_type NOT NULL,
  actor_id       TEXT,
  actor_role     TEXT,
  from_status    TEXT,
  to_status      TEXT,
  notes          TEXT,
  location_city  TEXT,
  location_state TEXT,
  metadata       JSONB,
  occurred_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_load_events_load ON load_events (load_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_load_events_type ON load_events (event_type, occurred_at DESC);

-- History is a record of what happened; it does not get revised.
DROP TRIGGER IF EXISTS load_events_append_only ON load_events;
CREATE TRIGGER load_events_append_only BEFORE UPDATE OR DELETE ON load_events
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- The only way to write an event. The actor is taken from the transaction
-- identity, never from an argument, so an event cannot be attributed to
-- somebody else.
CREATE OR REPLACE FUNCTION app_log_load_event(
  p_load_id TEXT, p_booking_id TEXT, p_type load_event_type,
  p_from TEXT, p_to TEXT, p_notes TEXT,
  p_city TEXT, p_state TEXT, p_metadata JSONB
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE new_id TEXT := 'evt-' || md5(random()::text || clock_timestamp()::text);
BEGIN
  INSERT INTO load_events (
    id, load_id, booking_id, event_type, actor_id, actor_role,
    from_status, to_status, notes, location_city, location_state, metadata
  ) VALUES (
    new_id, p_load_id, p_booking_id, p_type, app_current_user_id(), app_current_role(),
    p_from, p_to, p_notes, p_city, p_state, p_metadata
  );
  RETURN new_id;
END $$;

GRANT EXECUTE ON FUNCTION app_log_load_event(TEXT, TEXT, load_event_type, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO asoc_app;

-- ---------------------------------------------------------------------------
-- 3. STATUS MACHINE
-- ---------------------------------------------------------------------------
-- Legal transitions, in one place:
--
--   open       -> booked | cancelled
--   booked     -> in_transit | delivered | open (booking released) | cancelled
--   in_transit -> delivered | cancelled
--   delivered  -> (terminal — a settlement exists and settlements are immutable)
--   cancelled  -> (terminal)

CREATE OR REPLACE FUNCTION loads_status_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'delivered' THEN
    RAISE EXCEPTION 'Load % is delivered and cannot change status', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.status = 'cancelled' THEN
    RAISE EXCEPTION 'Load % is cancelled and cannot be reopened', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    (OLD.status = 'open'       AND NEW.status IN ('booked', 'cancelled')) OR
    (OLD.status = 'booked'     AND NEW.status IN ('in_transit', 'delivered', 'open', 'cancelled')) OR
    (OLD.status = 'in_transit' AND NEW.status IN ('delivered', 'cancelled'))
  ) THEN
    RAISE EXCEPTION 'Illegal load transition % -> % on %', OLD.status, NEW.status, OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'cancelled' THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
    NEW.cancellation_reason := COALESCE(NEW.cancellation_reason, 'No reason supplied');
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS loads_status_guard_trg ON loads;
CREATE TRIGGER loads_status_guard_trg BEFORE UPDATE ON loads
  FOR EACH ROW EXECUTE FUNCTION loads_status_guard();

-- Timeline entries are written after the row is committed to, so an event never
-- describes a transition that was rejected.
CREATE OR REPLACE FUNCTION loads_timeline_writer() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  evt load_event_type;
  bk  TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM app_log_load_event(NEW.id, NULL, 'posted', NULL, NEW.status::TEXT, NULL, NULL, NULL, NULL);
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  evt := CASE NEW.status
           WHEN 'booked'     THEN 'booked'
           WHEN 'in_transit' THEN 'in_transit'
           WHEN 'delivered'  THEN 'delivered'
           WHEN 'cancelled'  THEN 'cancelled'
           ELSE 'updated'
         END::load_event_type;

  SELECT b.id INTO bk FROM bookings b
   WHERE b.load_id = NEW.id AND b.status <> 'cancelled'
   ORDER BY b.booked_at DESC LIMIT 1;

  PERFORM app_log_load_event(
    NEW.id, bk, evt, OLD.status::TEXT, NEW.status::TEXT,
    CASE WHEN NEW.status = 'cancelled' THEN NEW.cancellation_reason ELSE NULL END,
    NULL, NULL, NULL
  );
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS loads_timeline_trg ON loads;
CREATE TRIGGER loads_timeline_trg AFTER INSERT OR UPDATE ON loads
  FOR EACH ROW EXECUTE FUNCTION loads_timeline_writer();

-- ---------------------------------------------------------------------------
-- 4. BOOKING RELEASE
-- ---------------------------------------------------------------------------
-- Cancelling a booking has to put the load back on the board, and the partial
-- unique index (load_id) WHERE status <> 'cancelled' has to see the cancelled
-- row before the next driver may claim it. Doing that in a trigger keeps the
-- two facts in one transaction no matter which route performs the cancel.

CREATE OR REPLACE FUNCTION bookings_release_load() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());

    -- A delivered load has already settled; releasing it would contradict the
    -- ledger, so a settled booking cannot be cancelled at all.
    IF EXISTS (SELECT 1 FROM settlements s WHERE s.booking_id = NEW.id) THEN
      RAISE EXCEPTION 'Booking % has settled and cannot be cancelled', NEW.id
        USING ERRCODE = 'restrict_violation';
    END IF;

    UPDATE loads SET status = 'open'
     WHERE id = NEW.load_id AND status IN ('booked', 'in_transit');
  END IF;

  IF NEW.picked_up_at IS NOT NULL AND OLD.picked_up_at IS NULL THEN
    UPDATE loads SET status = 'in_transit'
     WHERE id = NEW.load_id AND status = 'booked';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS bookings_release_trg ON bookings;
CREATE TRIGGER bookings_release_trg BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION bookings_release_load();

-- ---------------------------------------------------------------------------
-- 5. ACCESS
-- ---------------------------------------------------------------------------

GRANT SELECT ON load_events TO asoc_app;

ALTER TABLE load_events ENABLE ROW LEVEL SECURITY;

-- A load's history is visible to the parties to it. It carries driver notes and
-- pickup locations, so it is not public the way the load board is.
DROP POLICY IF EXISTS load_events_select ON load_events;
CREATE POLICY load_events_select ON load_events FOR SELECT USING (
  app_is_admin()
  OR EXISTS (
    SELECT 1 FROM loads l
    WHERE l.id = load_events.load_id AND l.shipper_id = app_current_shipper_id()
  )
  OR EXISTS (
    SELECT 1 FROM bookings b
    WHERE b.load_id = load_events.load_id AND b.driver_id = app_current_driver_id()
  )
);

CREATE INDEX IF NOT EXISTS idx_loads_shipper_status ON loads (shipper_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookings_driver_status ON bookings (driver_id, status, booked_at DESC);
