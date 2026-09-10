/**
 * Database entry point.
 *
 * `db` is a lazily-constructed singleton over the configured backend (real
 * PostgreSQL when DATABASE_URL is set, embedded PGlite otherwise). Importing
 * this module opens no connection — the pool is created on first query, so
 * `dotenv` and CLI flags are always read before the connection is configured.
 */
import {
  ANON_CONTEXT,
  createAdminDatabase,
  createDatabase,
  type Database,
  type DriverName,
  type Queryable,
  type QueryResult,
  type ScopedDatabase,
  type SessionContext
} from './client';
import { runMigrations } from './migrate';
import { isDatabaseEmpty, seedDatabase, seedingEnabled } from './seed';
import { ensureAdminAccount } from './admin-account';

export type { Database, DriverName, Queryable, QueryResult, ScopedDatabase, SessionContext };
export { ANON_CONTEXT } from './client';
export { runMigrations, migrationStatus } from './migrate';
export { seedDatabase, isDatabaseEmpty, seedingEnabled } from './seed';

let instance: Database | null = null;

export function getDb(): Database {
  if (!instance) {
    instance = createDatabase();
  }
  return instance;
}

/** Shared handle used across the server. Connects on first use. */
export const db: Database = {
  get driver() {
    return getDb().driver;
  },
  get description() {
    return getDb().description;
  },
  query: (sql, params) => getDb().query(sql, params),
  exec: sql => getDb().exec(sql),
  transaction: (fn, ctx) => getDb().transaction(fn, ctx),
  as: ctx => getDb().as(ctx),
  close: async () => {
    if (!instance) return;
    const current = instance;
    instance = null;
    await current.close();
  }
};

/**
 * Privileged handle for schema changes and seeding.
 *
 * The runtime role deliberately cannot create tables or alter policies, so
 * migrations connect as the owner via DATABASE_ADMIN_URL. Falls back to the
 * runtime connection when no separate owner is configured (single-role setups
 * and the embedded engine).
 */
export function getMigrationDb(): { db: Database; isSeparate: boolean } {
  const admin = createAdminDatabase();
  return admin ? { db: admin, isSeparate: true } : { db: getDb(), isSeparate: false };
}

/** Round-trips a query to prove the connection is alive. */
export async function pingDb(): Promise<boolean> {
  try {
    await db.query('SELECT 1');
    return true;
  } catch (err: any) {
    console.error('[DB] Ping failed:', err.message);
    return false;
  }
}

export interface InitDbResult {
  driver: DriverName;
  description: string;
  migrationsApplied: string[];
  seeded: boolean;
}

/**
 * Connects, migrates, and seeds an empty database.
 *
 * Throws on failure — a server that boots without a schema only produces 500s
 * on every request, so the process should die loudly at startup instead.
 */
export async function initDb(): Promise<InitDbResult> {
  const connected = await pingDb();
  if (!connected) {
    throw new Error(
      `Could not connect to the database (${db.description}). ` +
      'Check DATABASE_URL and that the server is reachable.'
    );
  }
  console.log(`[DB] Connected to ${db.description} (driver: ${db.driver})`);

  const { db: migrationDb, isSeparate } = getMigrationDb();
  if (isSeparate) {
    console.log('[DB] Running migrations as the owner role (DATABASE_ADMIN_URL)');
  }

  let migrationsApplied: string[] = [];
  let seeded = false;

  try {
    migrationsApplied = await runMigrations(migrationDb);
    if (migrationsApplied.length > 0) {
      console.log(`[DB] Applied ${migrationsApplied.length} migration(s): ${migrationsApplied.join(', ')}`);
    } else {
      console.log('[DB] Schema up to date, no migrations pending');
    }

    if (await isDatabaseEmpty(migrationDb)) {
      if (seedingEnabled()) {
        await seedDatabase(migrationDb);
        seeded = true;
      } else {
        console.log('[DB] Database is empty; skipping demo seed (set DB_SEED=true to enable)');
      }
    }

    // Runs after seeding, and whether or not seeding ran: ADMIN_PASSWORD is
    // the supported way to hold an administrator credential now that signup
    // refuses the role, so it has to apply to an existing install too.
    const adminAccount = await ensureAdminAccount(migrationDb);
    switch (adminAccount.status) {
      case 'created':
        console.log(`[DB] Created administrator ${adminAccount.email} from ADMIN_PASSWORD`);
        break;
      case 'rotated':
        console.log(
          `[DB] Updated administrator password for ${adminAccount.email} from ADMIN_PASSWORD` +
          (adminAccount.sessionsRevoked > 0
            ? ` (revoked ${adminAccount.sessionsRevoked} active session(s))`
            : '')
        );
        break;
      case 'unchanged':
        console.log(`[DB] Administrator ${adminAccount.email} already matches ADMIN_PASSWORD`);
        break;
      case 'skipped':
        if (process.env.NODE_ENV === 'production') {
          console.warn(
            '[DB] ADMIN_PASSWORD is not set. No administrator credential is managed ' +
            'by this deployment; see .env.example.'
          );
        }
        break;
    }
  } finally {
    // The privileged connection is short-lived: it exists for startup only and
    // is not left open for the lifetime of the process.
    if (isSeparate) await migrationDb.close();
  }

  console.log('[DB] Database initialized successfully');
  return { driver: db.driver, description: db.description, migrationsApplied, seeded };
}

/** Closes the pool. Safe to call more than once. */
export async function closeDb(): Promise<void> {
  await db.close();
}
