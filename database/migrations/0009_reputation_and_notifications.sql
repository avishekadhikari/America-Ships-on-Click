-- Reputation and in-app notifications.
--
-- Reputation exists because a no-broker board removes the intermediary who used
-- to vouch for both sides. A rating can only be written by a party to a load
-- that actually settled, which is what separates it from a review site: every
-- score is backed by a completed, publicly-ledgered transaction.
--
-- Notifications are written by triggers rather than by route handlers. A carrier
-- finding out they were awarded a load is not a nice-to-have that can be lost
-- when a code path forgets to call the notifier, so the database emits them.

-- ---------------------------------------------------------------------------
-- 1. RATINGS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ratings (
  id                  TEXT PRIMARY KEY,
  booking_id          TEXT NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  load_id             TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  rater_user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  rater_role          TEXT NOT NULL CHECK (rater_role IN ('driver', 'shipper')),
  subject_driver_id   TEXT REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  subject_shipper_id  TEXT REFERENCES shipper_profiles(id) ON DELETE RESTRICT,
  score               INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
  communication_score INTEGER CHECK (communication_score BETWEEN 1 AND 5),
  on_time             BOOLEAN,
  comment             TEXT CHECK (comment IS NULL OR length(comment) <= 2000),
  created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Exactly one subject: a driver rates the shipper, a shipper rates the driver.
  CONSTRAINT ratings_one_subject CHECK (
    (subject_driver_id IS NOT NULL AND subject_shipper_id IS NULL) OR
    (subject_driver_id IS NULL AND subject_shipper_id IS NOT NULL)
  )
);

-- One rating per person per load, so nobody can stack a reputation.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ratings_once_per_party
  ON ratings (booking_id, rater_user_id);
CREATE INDEX IF NOT EXISTS idx_ratings_driver ON ratings (subject_driver_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ratings_shipper ON ratings (subject_shipper_id, created_at DESC);

-- A score has to be earned. Unsettled work cannot be rated, and a rating cannot
-- be re-pointed at a different load or subject after the fact; the text may be
-- corrected for a day, after which it is fixed.
CREATE OR REPLACE FUNCTION ratings_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM settlements s WHERE s.booking_id = NEW.booking_id) THEN
      RAISE EXCEPTION 'A load can only be rated once it has settled'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.booking_id       IS DISTINCT FROM OLD.booking_id
  OR NEW.rater_user_id    IS DISTINCT FROM OLD.rater_user_id
  OR NEW.subject_driver_id IS DISTINCT FROM OLD.subject_driver_id
  OR NEW.subject_shipper_id IS DISTINCT FROM OLD.subject_shipper_id THEN
    RAISE EXCEPTION 'A rating cannot be moved to a different load or party'
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.created_at < now() - INTERVAL '24 hours' THEN
    RAISE EXCEPTION 'Ratings can only be edited within 24 hours of being left'
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS ratings_guard_trg ON ratings;
CREATE TRIGGER ratings_guard_trg BEFORE INSERT OR UPDATE ON ratings
  FOR EACH ROW EXECUTE FUNCTION ratings_guard();

DROP TRIGGER IF EXISTS audit_ratings ON ratings;
CREATE TRIGGER audit_ratings AFTER INSERT OR UPDATE OR DELETE ON ratings
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- Public reputation. Aggregates only, and the view is owner-owned so it reads
-- past RLS on the base table — safe because it projects no rater identity and
-- no free text.
CREATE OR REPLACE VIEW driver_reputation_view AS
SELECT
  d.id                                                   AS driver_id,
  d.full_name,
  d.home_base_city,
  d.home_base_state,
  d.verification_status,
  COUNT(r.id)::INTEGER                                   AS rating_count,
  ROUND(AVG(r.score)::NUMERIC, 2)                        AS avg_score,
  ROUND(AVG(r.communication_score)::NUMERIC, 2)          AS avg_communication,
  ROUND(
    COALESCE(AVG(CASE WHEN r.on_time THEN 1.0 ELSE 0.0 END), 0)::NUMERIC * 100, 1
  )                                                      AS on_time_pct
FROM driver_profiles d
LEFT JOIN ratings r ON r.subject_driver_id = d.id
GROUP BY d.id, d.full_name, d.home_base_city, d.home_base_state, d.verification_status;

CREATE OR REPLACE VIEW shipper_reputation_view AS
SELECT
  s.id                                          AS shipper_id,
  s.company_name,
  COUNT(r.id)::INTEGER                          AS rating_count,
  ROUND(AVG(r.score)::NUMERIC, 2)               AS avg_score,
  ROUND(AVG(r.communication_score)::NUMERIC, 2) AS avg_communication
FROM shipper_profiles s
LEFT JOIN ratings r ON r.subject_shipper_id = s.id
GROUP BY s.id, s.company_name;

GRANT SELECT ON driver_reputation_view, shipper_reputation_view TO asoc_app;
GRANT SELECT, INSERT, UPDATE ON ratings TO asoc_app;

ALTER TABLE ratings ENABLE ROW LEVEL SECURITY;

-- The raw rows carry free text and the rater's identity, so they are scoped to
-- the parties involved. Everyone else reads the aggregate views.
DROP POLICY IF EXISTS ratings_select ON ratings;
CREATE POLICY ratings_select ON ratings FOR SELECT USING (
  app_is_admin()
  OR rater_user_id = app_current_user_id()
  OR subject_driver_id = app_current_driver_id()
  OR subject_shipper_id = app_current_shipper_id()
);

DROP POLICY IF EXISTS ratings_insert ON ratings;
CREATE POLICY ratings_insert ON ratings FOR INSERT WITH CHECK (
  app_is_admin() OR rater_user_id = app_current_user_id()
);

DROP POLICY IF EXISTS ratings_update ON ratings;
CREATE POLICY ratings_update ON ratings FOR UPDATE USING (
  app_is_admin() OR rater_user_id = app_current_user_id()
) WITH CHECK (
  app_is_admin() OR rater_user_id = app_current_user_id()
);

-- ---------------------------------------------------------------------------
-- 2. NOTIFICATIONS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS notifications (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  type       TEXT NOT NULL,
  title      TEXT NOT NULL,
  body       TEXT,
  link       TEXT,
  load_id    TEXT REFERENCES loads(id) ON DELETE RESTRICT,
  severity   TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'success', 'warning', 'critical')),
  read_at    TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_notifications_inbox
  ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON notifications (user_id) WHERE read_at IS NULL;

CREATE TABLE IF NOT EXISTS notification_preferences (
  user_id            TEXT PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
  booking_alerts     BOOLEAN NOT NULL DEFAULT TRUE,
  offer_alerts       BOOLEAN NOT NULL DEFAULT TRUE,
  settlement_alerts  BOOLEAN NOT NULL DEFAULT TRUE,
  verification_alerts BOOLEAN NOT NULL DEFAULT TRUE,
  dispute_alerts     BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Emits a notification, honouring the recipient's preferences. Called from
-- triggers, so the caller is whatever transaction caused the event.
CREATE OR REPLACE FUNCTION app_notify(
  p_user_id TEXT, p_type TEXT, p_title TEXT, p_body TEXT,
  p_link TEXT, p_load_id TEXT, p_severity TEXT
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  new_id TEXT;
  wants  BOOLEAN := TRUE;
  prefs  notification_preferences%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO prefs FROM notification_preferences WHERE user_id = p_user_id;
  IF FOUND THEN
    wants := CASE
      WHEN p_type LIKE 'offer%'        THEN prefs.offer_alerts
      WHEN p_type LIKE 'booking%'      THEN prefs.booking_alerts
      WHEN p_type LIKE 'load%'         THEN prefs.booking_alerts
      WHEN p_type LIKE 'settlement%'   THEN prefs.settlement_alerts
      WHEN p_type LIKE 'verification%' THEN prefs.verification_alerts
      WHEN p_type LIKE 'dispute%'      THEN prefs.dispute_alerts
      ELSE TRUE
    END;
  END IF;

  IF NOT wants THEN RETURN NULL; END IF;

  new_id := 'ntf-' || md5(random()::text || clock_timestamp()::text);
  INSERT INTO notifications (id, user_id, type, title, body, link, load_id, severity)
  VALUES (new_id, p_user_id, p_type, p_title, p_body, p_link, p_load_id,
          COALESCE(p_severity, 'info'));
  RETURN new_id;
END $$;

GRANT EXECUTE ON FUNCTION app_notify(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO asoc_app;

-- Every user gets a preferences row on signup, so the UI never has to guess
-- whether "absent" means opted in or out.
CREATE OR REPLACE FUNCTION users_default_preferences() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO notification_preferences (user_id) VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS users_default_preferences_trg ON users;
CREATE TRIGGER users_default_preferences_trg AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION users_default_preferences();

INSERT INTO notification_preferences (user_id)
SELECT id FROM users ON CONFLICT (user_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. EVENT -> NOTIFICATION TRIGGERS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION notify_on_booking() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  shipper_user TEXT;
  driver_user  TEXT;
  driver_name  TEXT;
  lane         TEXT;
BEGIN
  SELECT sp.user_id, l.origin_city || ', ' || l.origin_state || ' → ' || l.dest_city || ', ' || l.dest_state
    INTO shipper_user, lane
  FROM loads l JOIN shipper_profiles sp ON sp.id = l.shipper_id
  WHERE l.id = NEW.load_id;

  SELECT d.user_id, d.full_name INTO driver_user, driver_name
  FROM driver_profiles d WHERE d.id = NEW.driver_id;

  IF TG_OP = 'INSERT' THEN
    PERFORM app_notify(shipper_user, 'booking_created', 'Your load was booked',
      COALESCE(driver_name, 'A carrier') || ' booked ' || COALESCE(lane, NEW.load_id),
      '/loads/' || NEW.load_id, NEW.load_id, 'success');
    RETURN NEW;
  END IF;

  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    PERFORM app_notify(shipper_user, 'booking_cancelled', 'A booking was cancelled',
      COALESCE(lane, NEW.load_id) || ' is back on the board',
      '/loads/' || NEW.load_id, NEW.load_id, 'warning');
    PERFORM app_notify(driver_user, 'booking_cancelled', 'Your booking was cancelled',
      COALESCE(NEW.cancellation_reason, 'No reason supplied'),
      '/loads/' || NEW.load_id, NEW.load_id, 'warning');
  END IF;

  IF NEW.picked_up_at IS NOT NULL AND OLD.picked_up_at IS NULL THEN
    PERFORM app_notify(shipper_user, 'load_picked_up', 'Load picked up',
      COALESCE(lane, NEW.load_id) || ' is in transit',
      '/loads/' || NEW.load_id, NEW.load_id, 'info');
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_booking_trg ON bookings;
CREATE TRIGGER notify_booking_trg AFTER INSERT OR UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION notify_on_booking();

CREATE OR REPLACE FUNCTION notify_on_settlement() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  shipper_user TEXT;
  driver_user  TEXT;
BEGIN
  SELECT sp.user_id INTO shipper_user
  FROM loads l JOIN shipper_profiles sp ON sp.id = l.shipper_id
  WHERE l.id = NEW.load_id;

  SELECT d.user_id INTO driver_user
  FROM bookings b JOIN driver_profiles d ON d.id = b.driver_id
  WHERE b.id = NEW.booking_id;

  PERFORM app_notify(driver_user, 'settlement_paid', 'Settlement posted',
    'Net to you: $' || to_char(NEW.net_amount, 'FM999999990.00'),
    '/settlements/' || NEW.id, NEW.load_id, 'success');

  PERFORM app_notify(shipper_user, 'settlement_posted', 'Load delivered and settled',
    'Gross: $' || to_char(NEW.gross_amount, 'FM999999990.00'),
    '/settlements/' || NEW.id, NEW.load_id, 'success');

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_settlement_trg ON settlements;
CREATE TRIGGER notify_settlement_trg AFTER INSERT ON settlements
  FOR EACH ROW EXECUTE FUNCTION notify_on_settlement();

CREATE OR REPLACE FUNCTION notify_on_offer() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  shipper_user TEXT;
  driver_user  TEXT;
  driver_name  TEXT;
BEGIN
  SELECT sp.user_id INTO shipper_user
  FROM loads l JOIN shipper_profiles sp ON sp.id = l.shipper_id
  WHERE l.id = NEW.load_id;

  SELECT d.user_id, d.full_name INTO driver_user, driver_name
  FROM driver_profiles d WHERE d.id = NEW.driver_id;

  IF TG_OP = 'INSERT' THEN
    PERFORM app_notify(shipper_user, 'offer_received', 'New rate offer',
      COALESCE(driver_name, 'A carrier') || ' offered $' ||
      to_char(NEW.offered_rate_per_mile, 'FM990.00') || '/mi',
      '/loads/' || NEW.load_id, NEW.load_id, 'info');
    RETURN NEW;
  END IF;

  IF NEW.status <> OLD.status AND NEW.status IN ('accepted', 'declined', 'expired') THEN
    PERFORM app_notify(driver_user, 'offer_' || NEW.status,
      'Your offer was ' || NEW.status,
      COALESCE(NEW.response_note, ''),
      '/loads/' || NEW.load_id, NEW.load_id,
      CASE NEW.status WHEN 'accepted' THEN 'success' ELSE 'info' END);
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_offer_trg ON load_offers;
CREATE TRIGGER notify_offer_trg AFTER INSERT OR UPDATE ON load_offers
  FOR EACH ROW EXECUTE FUNCTION notify_on_offer();

-- ---------------------------------------------------------------------------
-- 4. ACCESS
-- ---------------------------------------------------------------------------

GRANT SELECT, UPDATE ON notifications TO asoc_app;
GRANT SELECT, INSERT, UPDATE ON notification_preferences TO asoc_app;

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;

-- An inbox is private. There is deliberately no INSERT grant: notifications
-- come from triggers, so a route cannot fabricate one in someone else's inbox.
DROP POLICY IF EXISTS notifications_select ON notifications;
CREATE POLICY notifications_select ON notifications FOR SELECT USING (
  app_is_admin() OR user_id = app_current_user_id()
);

-- Marking as read is the only mutation the owner may make.
DROP POLICY IF EXISTS notifications_update ON notifications;
CREATE POLICY notifications_update ON notifications FOR UPDATE USING (
  user_id = app_current_user_id()
) WITH CHECK (
  user_id = app_current_user_id()
);

DROP POLICY IF EXISTS notification_prefs_select ON notification_preferences;
CREATE POLICY notification_prefs_select ON notification_preferences FOR SELECT USING (
  app_is_admin() OR user_id = app_current_user_id()
);

DROP POLICY IF EXISTS notification_prefs_insert ON notification_preferences;
CREATE POLICY notification_prefs_insert ON notification_preferences FOR INSERT WITH CHECK (
  app_is_admin() OR user_id = app_current_user_id() OR app_current_role() = 'enrollment'
);

DROP POLICY IF EXISTS notification_prefs_update ON notification_preferences;
CREATE POLICY notification_prefs_update ON notification_preferences FOR UPDATE USING (
  app_is_admin() OR user_id = app_current_user_id()
) WITH CHECK (
  app_is_admin() OR user_id = app_current_user_id()
);
