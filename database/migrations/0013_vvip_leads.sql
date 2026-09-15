-- Golden VVIP interest list.
--
-- This is not an account, not a payment, and not a wallet. The public
-- /vvip page captures a name, email, role, and city so the founder can
-- reach people before the public window. Rows are append-only: a lead is
-- a fact, the same way a settlement is. Duplicate emails collapse to the
-- first write so a refresh cannot stack the inbox.
--
-- INSERT is allowed from the unauthenticated 'anon' context only.
-- SELECT is admin-only. There is no UPDATE or DELETE grant, and the
-- append-only trigger refuses those operations even for the table owner.

CREATE TABLE IF NOT EXISTS vvip_leads (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  email        TEXT NOT NULL CHECK (char_length(email) BETWEEN 3 AND 254) UNIQUE,
  who_you_are  TEXT NOT NULL CHECK (who_you_are IN ('shipper', 'carrier', 'fleet', 'other')),
  location     TEXT NOT NULL CHECK (char_length(location) BETWEEN 1 AND 120),
  ip_address   TEXT,
  created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_vvip_leads_created
  ON vvip_leads (created_at DESC);

GRANT SELECT, INSERT ON vvip_leads TO asoc_app;

ALTER TABLE vvip_leads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vvip_leads_insert ON vvip_leads;
CREATE POLICY vvip_leads_insert ON vvip_leads FOR INSERT WITH CHECK (
  app_current_role() = 'anon'
);

DROP POLICY IF EXISTS vvip_leads_select ON vvip_leads;
CREATE POLICY vvip_leads_select ON vvip_leads FOR SELECT USING (
  app_is_admin()
);

DROP TRIGGER IF EXISTS audit_vvip_leads ON vvip_leads;
CREATE TRIGGER audit_vvip_leads AFTER INSERT OR UPDATE OR DELETE ON vvip_leads
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

DROP TRIGGER IF EXISTS vvip_leads_append_only ON vvip_leads;
CREATE TRIGGER vvip_leads_append_only BEFORE UPDATE OR DELETE ON vvip_leads
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
