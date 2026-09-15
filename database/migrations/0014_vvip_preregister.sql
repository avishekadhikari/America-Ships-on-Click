-- Golden VVIP writes go through a SECURITY DEFINER routine, not a direct
-- INSERT as 'anon'.
--
-- Migration 0013 granted INSERT with a WITH CHECK of app_current_role() =
-- 'anon'. That expression is true when selected in the same transaction, but
-- PostgreSQL still rejects the row at RLS evaluation — this codebase has no
-- other unauthenticated INSERT policy, and the working public-write paths
-- (login throttle, rate limit) all go through SECURITY DEFINER functions.
-- Direct INSERT is revoked so a compromised route cannot write leads except
-- by calling this routine, which also collapses duplicate emails.

CREATE OR REPLACE FUNCTION app_vvip_preregister(
  p_id TEXT,
  p_name TEXT,
  p_email TEXT,
  p_who TEXT,
  p_location TEXT,
  p_ip TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF app_current_role() <> 'anon' THEN
    RAISE EXCEPTION 'VVIP pre-register is public-only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO vvip_leads (id, name, email, who_you_are, location, ip_address)
  VALUES (p_id, p_name, p_email, p_who, p_location, p_ip)
  ON CONFLICT (email) DO NOTHING;

  RETURN FOUND;
END $$;

REVOKE INSERT ON vvip_leads FROM asoc_app;
GRANT EXECUTE ON FUNCTION app_vvip_preregister(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO asoc_app;
