# Deploying to a Node host

`www.americashipsonclick.com` currently serves a **static** build on Vercel.
That is why `/vvip`, `/loads` and `/dashboard` return 404 and every `/api`
route is missing: this app is an Express server, not a static site. `npm run
build` produces `dist/server.cjs`, which serves the API *and* the SPA (with a
`GET *` fallback, so deep links resolve). Something has to run that process.

`render.yaml` in the repo root is a Render Blueprint that does it.

---

## Why two database roles

`database/scripts/postgres-dev.sh` runs the app as `asoc_app`, a least-privilege
role, and reserves the owner role (`asoc`) for migrations. Production must keep
that split:

- RLS is **enabled but not forced** (`pg_class.relforcerowsecurity = false`).
- PostgreSQL exempts a table's **owner** from row-level security.
- So if `DATABASE_URL` points at the owner, every policy in
  `0002_security.sql` silently stops applying. The app still works. The
  isolation described in `SECURITY.md` is simply gone.

Managed Postgres hands you one role, and it is the owner. Step 3 below creates
the runtime role so this does not happen.

---

## 1. Create the Blueprint

Render → **New → Blueprint** → pick this repo. It reads `render.yaml` and
creates the web service plus a PostgreSQL 16 instance.

If you created a **Web Service** by hand instead of this Blueprint, Render
defaults to `npm start` with no build. That crashes immediately:

```
Error: Cannot find module '/opt/render/project/src/dist/server.cjs'
```

Set **Build Command** to `npm ci && npm run build` and **Start Command** to
`npm start`. If Build Command is left empty, `postinstall` still compiles on
Render (`RENDER=true`) during install — before start — so the process can bind
`$PORT` immediately. Do not compile in `npm start`: Render sends SIGTERM if no
port is open while Vite is still running.

A Blueprint first deploy can still fail at boot. That is expected: `DATABASE_URL`
is not set yet, and the role it points to does not exist. Steps 2–4 fix that.

## 2. Set `ADMIN_PASSWORD`

Render → service → **Environment**. Must be 8+ characters and must not be the
demo password published in this repo; the server refuses to start otherwise.

`JWT_SECRET` and `PAYMENT_TOKEN_SECRET` are generated once by Render and
persist across deploys. Rotating `JWT_SECRET` invalidates every issued token.

## 3. Create the runtime role

Copy the **External Database URL** from the Render database page, then:

```bash
psql "<external-database-url>"
```

```sql
-- Migration 0002 creates asoc_app as NOLOGIN with no password, so it cannot be
-- connected as. Creating it here first means 0002 finds it and only grants
-- privileges. Use a long random password.
CREATE ROLE asoc_app LOGIN PASSWORD 'replace-with-a-long-random-password';
```

Generate one with:

```bash
head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-32
```

## 4. Point `DATABASE_URL` at that role

Take the Internal Database URL, swap in the `asoc_app` credentials, and set it
in the Render dashboard:

```
postgresql://asoc_app:<password>@<internal-host>/asoc
```

Leave `DATABASE_ADMIN_URL` alone — the Blueprint wires it to the owner
connection automatically, and migrations run under it at boot behind a
`pg_advisory_xact_lock`, so a rolling deploy migrates exactly once.

Redeploy. The log should read:

```
[DB] Connected to postgres://.../asoc (driver: postgres)
[DB] Running migrations as the owner role (DATABASE_ADMIN_URL)
[SERVER] America Ships On Click server running on http://0.0.0.0:10000
```

## 5. Verify before moving DNS

Against the `onrender.com` URL:

```bash
curl -s https://<service>.onrender.com/api/health
curl -s -o /dev/null -w '%{http_code}\n' https://<service>.onrender.com/vvip   # expect 200
```

Confirm RLS is actually in force — this should return **zero rows**, because
`asoc_app` may not read another carrier's identity:

```bash
psql "postgresql://asoc_app:<password>@<external-host>/asoc" \
  -c "SELECT count(*) FROM driver_profiles;"
```

If it returns a count, `DATABASE_URL` is still pointing at the owner.

## 6. Move the domain

Render → service → **Settings → Custom Domains** → add
`www.americashipsonclick.com` and `americashipsonclick.com`.

Then at your DNS provider, **remove the Vercel records** and add what Render
shows:

| Type | Name | Value |
|---|---|---|
| CNAME | `www` | `<service>.onrender.com` |
| A / ALIAS | `@` | as shown by Render |

DNS currently points at Vercel (`vercel-dns-017.com`); both cannot own the
domain at once. Render issues the TLS certificate once the records resolve.

After cutover:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.americashipsonclick.com/vvip
curl -s https://www.americashipsonclick.com/api/config
```

---

## Note on Vercel

Vercel auto-deploys this repo on every push to `main` and will keep serving the
stale static build until the domain moves. Once DNS points at Render, either
delete the Vercel project or disconnect it from the repo so the two do not
diverge.
