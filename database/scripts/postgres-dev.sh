#!/usr/bin/env bash
#
# Project-local PostgreSQL cluster for development.
#
# Runs a real PostgreSQL server owned by your user account — no Docker, no sudo,
# no interference with a system-wide Postgres. Everything lives under .data/
# (gitignored), so `destroy` leaves nothing behind.
#
#   ./scripts/postgres-dev.sh up       start it (creating it on first run)
#   ./scripts/postgres-dev.sh down     stop it, keeping the data
#   ./scripts/postgres-dev.sh status   is it running, and where
#   ./scripts/postgres-dev.sh psql     open a psql shell on it
#   ./scripts/postgres-dev.sh destroy  stop it and delete all data
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$PROJECT_ROOT/.data/cluster"
LOG_FILE="$PROJECT_ROOT/.data/postgres.log"
PASS_FILE="$PROJECT_ROOT/.data/cluster.password"
APP_PASS_FILE="$PROJECT_ROOT/.data/app.password"
PORT="${ASOC_PG_PORT:-5433}"
DB_USER="asoc"        # owner: migrations, seeding, backups
APP_USER="asoc_app"   # runtime: least-privilege role the server connects as
DB_NAME="asoc"

# Locate the PostgreSQL binaries (Debian/Ubuntu, Homebrew, or already on PATH).
find_pg_bin() {
  if [ -n "${PGBIN:-}" ]; then echo "$PGBIN"; return; fi
  local candidate
  candidate="$(ls -d /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin \
    /usr/local/opt/postgresql@*/bin /usr/pgsql-*/bin 2>/dev/null | sort -V | tail -1)"
  if [ -n "$candidate" ]; then echo "$candidate"; return; fi
  if command -v initdb >/dev/null 2>&1; then dirname "$(command -v initdb)"; return; fi
  echo ""
}

PG_BIN="$(find_pg_bin)"
if [ -z "$PG_BIN" ]; then
  echo "error: PostgreSQL server binaries not found (initdb, pg_ctl)." >&2
  echo "       Install PostgreSQL, or set PGBIN=/path/to/postgres/bin." >&2
  exit 1
fi

# Runtime connection: restricted role, subject to Row-Level Security.
connection_url() {
  echo "postgresql://$APP_USER:$(cat "$APP_PASS_FILE")@127.0.0.1:$PORT/$DB_NAME"
}

# Privileged connection: owns the schema, used for migrations only.
admin_connection_url() {
  echo "postgresql://$DB_USER:$(cat "$PASS_FILE")@127.0.0.1:$PORT/$DB_NAME"
}

random_password() {
  # Every stage consumes its full input; `head -c` on the random source would
  # SIGPIPE under `set -o pipefail`.
  head -c 24 /dev/urandom | base64 | LC_ALL=C tr -d '/+=\n' | cut -c1-32
}

# The runtime role's credentials are owned by this script; migration 0002 owns
# its privileges. Creating it here keeps the password out of migration files
# and out of version control.
ensure_app_role() {
  local owner_pw app_pw
  owner_pw="$(cat "$PASS_FILE")"
  if [ ! -f "$APP_PASS_FILE" ]; then
    random_password > "$APP_PASS_FILE"
    chmod 600 "$APP_PASS_FILE"
  fi
  app_pw="$(cat "$APP_PASS_FILE")"

  PGPASSWORD="$owner_pw" "$PG_BIN/psql" -q -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 -v app_user="$APP_USER" -v app_pw="$app_pw" <<'SQL' >/dev/null
SELECT format(
  CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
       THEN 'ALTER ROLE %I LOGIN PASSWORD %L'
       ELSE 'CREATE ROLE %I LOGIN PASSWORD %L'
  END, :'app_user', :'app_pw') AS stmt \gset
:stmt;
SQL
}

is_running() {
  "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" status >/dev/null 2>&1
}

create_cluster() {
  echo "Creating PostgreSQL cluster in .data/cluster ..."
  mkdir -p "$PROJECT_ROOT/.data"

  # A random password, kept in a 0600 file and mirrored into DATABASE_URL.
  local pwfile
  pwfile="$(mktemp)"
  chmod 600 "$pwfile"
  random_password > "$pwfile"
  cp "$pwfile" "$PASS_FILE"
  chmod 600 "$PASS_FILE"

  "$PG_BIN/initdb" -D "$CLUSTER_DIR" -U "$DB_USER" \
    --auth-local=trust --auth-host=scram-sha-256 --pwfile="$pwfile" \
    --encoding=UTF8 >/dev/null
  rm -f "$pwfile"
}

start_cluster() {
  # Loopback only: this is a development database, never exposed off the machine.
  "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" -l "$LOG_FILE" -w \
    -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=$CLUSTER_DIR" \
    start >/dev/null
}

ensure_database() {
  local password exists
  password="$(cat "$PASS_FILE")"
  exists="$(PGPASSWORD="$password" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U "$DB_USER" \
    -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")"
  if [ "$exists" != "1" ]; then
    PGPASSWORD="$password" "$PG_BIN/createdb" -h 127.0.0.1 -p "$PORT" -U "$DB_USER" "$DB_NAME"
    echo "Created database \"$DB_NAME\"."
  fi
}

case "${1:-}" in
  up)
    [ -d "$CLUSTER_DIR" ] || create_cluster
    if is_running; then
      echo "Already running."
    else
      start_cluster
      echo "PostgreSQL $("$PG_BIN/postgres" --version | awk '{print $3}') started on 127.0.0.1:$PORT"
    fi
    ensure_database
    ensure_app_role
    echo
    echo "DATABASE_URL=\"$(connection_url)\""
    echo "DATABASE_ADMIN_URL=\"$(admin_connection_url)\""
    ;;

  down)
    if is_running; then
      "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" -m fast -w stop >/dev/null
      echo "Stopped."
    else
      echo "Not running."
    fi
    ;;

  status)
    if is_running; then
      echo "Running on 127.0.0.1:$PORT (data: .data/cluster, log: .data/postgres.log)"
      echo "DATABASE_URL=\"$(connection_url)\""
      echo "DATABASE_ADMIN_URL=\"$(admin_connection_url)\""
    else
      [ -d "$CLUSTER_DIR" ] && echo "Stopped (data preserved in .data/cluster)." || echo "Not created yet. Run: npm run db:up"
    fi
    ;;

  psql)
    shift
    PGPASSWORD="$(cat "$PASS_FILE")" exec "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" "$@"
    ;;

  destroy)
    if [ "${2:-}" != "--force" ]; then
      echo "This permanently deletes the cluster and every row in it." >&2
      echo "Re-run with: ./scripts/postgres-dev.sh destroy --force" >&2
      exit 1
    fi
    is_running && "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" -m immediate -w stop >/dev/null || true
    rm -rf "$CLUSTER_DIR" "$LOG_FILE" "$PASS_FILE" "$APP_PASS_FILE"
    echo "Cluster destroyed."
    ;;

  *)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
