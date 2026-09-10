-- Administrator accounts cannot be self-served.
--
-- The signup endpoint is unauthenticated by design — a carrier or shipper has
-- no credentials before it runs — and it writes under the 'enrollment' session
-- context, which `users_insert` (migration 0002) trusted with any role at all.
-- That made the admin role reachable by anyone who could post to the endpoint:
-- one request away from the full settlement ledger, every carrier's CDL and
-- banking identity, and the RLS bypass behind `app_is_admin()`.
--
-- The route no longer accepts the role, but a route is the wrong place for
-- this rule to live alone. Enrollment is a low-trust context by definition, so
-- the restriction belongs where it cannot be edited away by a later change to
-- a Zod schema: enrollment may create carriers and shippers, and nothing else.
-- Creating an administrator now requires an actor who is already an admin, or
-- an operator with direct database access — which is how the seeded account
-- and any first administrator come into being.
--
-- Promotion after the fact is already closed off: `users` carries no UPDATE
-- policy, so under RLS the row cannot be rewritten at all, and the two
-- SECURITY DEFINER routines that do write it (migration 0006) touch only
-- `password_hash`. No policy is added here, because adding one would grant
-- access that does not exist today.

DROP POLICY IF EXISTS users_insert ON users;
CREATE POLICY users_insert ON users FOR INSERT WITH CHECK (
  app_is_admin()
  OR (app_current_role() = 'enrollment' AND role <> 'admin')
);
