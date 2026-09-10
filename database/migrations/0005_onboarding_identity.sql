-- Stop the 'enrollment' context from rewriting an existing driver's records.
--
-- The enrollment context exists because signup has to create rows before any
-- identity exists. Migration 0002 granted it FOR ALL on the driver tables,
-- which also let it UPDATE rows belonging to drivers who had already signed up.
-- Combined with an unauthenticated onboarding route that looked its user up by
-- email, that allowed anyone to repoint another driver's payout account at
-- their own bank details.
--
-- Onboarding now runs as the authenticated driver, so enrollment only ever
-- needs to INSERT. Splitting the policies per command makes that explicit and
-- leaves a database-level backstop: even if a route regresses, a pre-identity
-- request cannot overwrite a payout account, a profile, or an equipment row.

-- driver_payment_accounts ---------------------------------------------------
-- The most sensitive table. Reads and updates require the owning driver id.
DROP POLICY IF EXISTS driver_payment_accounts_rw ON driver_payment_accounts;

DROP POLICY IF EXISTS driver_payment_accounts_select ON driver_payment_accounts;
CREATE POLICY driver_payment_accounts_select ON driver_payment_accounts FOR SELECT USING (
  app_is_admin() OR driver_id = app_current_driver_id()
);

DROP POLICY IF EXISTS driver_payment_accounts_insert ON driver_payment_accounts;
CREATE POLICY driver_payment_accounts_insert ON driver_payment_accounts FOR INSERT WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

DROP POLICY IF EXISTS driver_payment_accounts_update ON driver_payment_accounts;
CREATE POLICY driver_payment_accounts_update ON driver_payment_accounts FOR UPDATE USING (
  app_is_admin() OR driver_id = app_current_driver_id()
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- driver_equipment ----------------------------------------------------------
DROP POLICY IF EXISTS driver_equipment_rw ON driver_equipment;

DROP POLICY IF EXISTS driver_equipment_select ON driver_equipment;
CREATE POLICY driver_equipment_select ON driver_equipment FOR SELECT USING (
  app_is_admin() OR driver_id = app_current_driver_id()
);

DROP POLICY IF EXISTS driver_equipment_insert ON driver_equipment;
CREATE POLICY driver_equipment_insert ON driver_equipment FOR INSERT WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

DROP POLICY IF EXISTS driver_equipment_update ON driver_equipment;
CREATE POLICY driver_equipment_update ON driver_equipment FOR UPDATE USING (
  app_is_admin() OR driver_id = app_current_driver_id()
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- driver_documents ----------------------------------------------------------
DROP POLICY IF EXISTS driver_documents_rw ON driver_documents;

DROP POLICY IF EXISTS driver_documents_select ON driver_documents;
CREATE POLICY driver_documents_select ON driver_documents FOR SELECT USING (
  app_is_admin() OR driver_id = app_current_driver_id()
);

DROP POLICY IF EXISTS driver_documents_insert ON driver_documents;
CREATE POLICY driver_documents_insert ON driver_documents FOR INSERT WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id() OR app_current_role() = 'enrollment'
);

DROP POLICY IF EXISTS driver_documents_update ON driver_documents;
CREATE POLICY driver_documents_update ON driver_documents FOR UPDATE USING (
  app_is_admin() OR driver_id = app_current_driver_id()
) WITH CHECK (
  app_is_admin() OR driver_id = app_current_driver_id()
);

-- driver_profiles -----------------------------------------------------------
-- Enrollment no longer completes a pending profile; the authenticated driver
-- does, and is matched by the user_id / driver_id clauses already present.
DROP POLICY IF EXISTS driver_profiles_update ON driver_profiles;
CREATE POLICY driver_profiles_update ON driver_profiles FOR UPDATE USING (
  app_is_admin()
  OR user_id = app_current_user_id()
  OR id = app_current_driver_id()
);
