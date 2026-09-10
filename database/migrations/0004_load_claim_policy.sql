-- Let a driver claim an open load, without letting them touch anyone else's.
--
-- Booking a load starts with `SELECT ... FOR UPDATE` to serialize competing
-- drivers. In PostgreSQL a locking read is checked against the UPDATE policy as
-- well as the SELECT one, so the policy from migration 0002 — which required an
-- existing booking — made an open load invisible to the very driver trying to
-- book it, and every booking attempt failed with "Load not found".
--
-- The rule that expresses the intent: a driver may lock a load that is open, or
-- one they already hold a booking on (USING), and whatever they write must
-- leave them holding a live booking for it (WITH CHECK). Claiming a load
-- therefore requires having inserted your own booking row first, which
-- bookings_insert already restricts to your own driver id.

DROP POLICY IF EXISTS loads_update ON loads;
CREATE POLICY loads_update ON loads FOR UPDATE
USING (
  app_is_admin()
  OR shipper_id = app_current_shipper_id()
  OR (
    app_current_driver_id() IS NOT NULL
    AND (
      status = 'open'
      OR EXISTS (
        SELECT 1 FROM bookings b
        WHERE b.load_id = loads.id
          AND b.driver_id = app_current_driver_id()
          AND b.status <> 'cancelled'
      )
    )
  )
)
WITH CHECK (
  app_is_admin()
  OR shipper_id = app_current_shipper_id()
  OR EXISTS (
    SELECT 1 FROM bookings b
    WHERE b.load_id = loads.id
      AND b.driver_id = app_current_driver_id()
      AND b.status <> 'cancelled'
  )
);
