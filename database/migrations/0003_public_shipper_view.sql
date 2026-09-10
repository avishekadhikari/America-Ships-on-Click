-- Public projection of shipper identity.
--
-- The load board shows which company posted each load, but shipper_profiles
-- also holds billing_email and the owning user_id, and Row-Level Security
-- (migration 0002) correctly hides those rows from anonymous visitors.
--
-- Row-Level Security is row-scoped, not column-scoped, so the answer is a view
-- that exposes exactly the two public columns. It is owned by the schema owner
-- and therefore reads past RLS on the base table — which is safe precisely
-- because it can only ever project id and company_name.

CREATE OR REPLACE VIEW public_shipper_view AS
SELECT
  id,
  company_name
FROM shipper_profiles;

GRANT SELECT ON public_shipper_view TO asoc_app;
