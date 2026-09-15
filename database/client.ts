/**
 * Database client abstraction.
 *
 * Two interchangeable backends implement the same `Database` contract:
 *
 *   - `postgres` (default when DATABASE_URL is set) — a real PostgreSQL server
 *     accessed through a `pg` connection pool. Use this for staging/production.
 *   - `pglite`  (fallback) — the embedded WASM Postgres engine, file-backed under
 *     `.data/pgdata`. Zero-setup local development, same SQL dialect.
 *
 * Every query in the app goes through this module, so raw SQL, migrations,
 * `FOR UPDATE` row locking and transactions behave identically on both.
 */
import pg from 'pg';
import type { Pool as PgPool, PoolClient, PoolConfig } from 'pg';
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import path from 'path';

const { Pool } = pg;

export type DriverName = 'postgres' | 'pglite';

/**
 * Who the database should believe is making a request.
 *
 * Applied per transaction as `app.*` settings that Row-Level Security policies
 * read (see migrations/0002_security.sql). Transaction-scoped, so identity can
 * never leak from one pooled request to the next.
 *
 *   anon        unauthenticated public traffic
 *   auth        credential verification, before an identity exists
 *   enrollment  signup and driver onboarding
 *   webhook     chain-indexer ingest (signature verified in the route)
 *   driver/shipper/admin  an authenticated user
 */
export interface SessionContext {
  role: 'anon' | 'auth' | 'enrollment' | 'webhook' | 'driver' | 'shipper' | 'admin';
  userId?: string;
  driverId?: string;
  shipperId?: string;
}

export const ANON_CONTEXT: SessionContext = { role: 'anon' };

/** One statement, fully parameterized, setting the identity for this transaction. */
const SET_CONTEXT_SQL = `SELECT set_config('app.user_role', $1, true),
                                set_config('app.user_id', $2, true),
                                set_config('app.driver_id', $3, true),
                                set_config('app.shipper_id', $4, true)`;

function contextParams(ctx: SessionContext): string[] {
  return [ctx.role, ctx.userId ?? '', ctx.driverId ?? '', ctx.shipperId ?? ''];
}

export interface QueryResult<T = any> {
  rows: T[];
  rowCount: number;
}

/** Anything that can run SQL: the pool itself, or a single transaction. */
export interface Queryable {
  query<T = any>(sql: string, params?: any[]): Promise<QueryResult<T>>;
  /** Runs a multi-statement SQL script (no bind parameters). */
  exec(sql: string): Promise<void>;
}

export interface Database extends Queryable {
  readonly driver: DriverName;
  /** Human-readable target, safe to log (never contains the password). */
  readonly description: string;
  /**
   * Runs `fn` inside a single transaction on a single dedicated connection.
   * Commits on resolve, rolls back on throw. Required for anything using
   * `SELECT ... FOR UPDATE`, since pooled queries land on different clients.
   *
   * `ctx` sets the identity Row-Level Security policies enforce for the
   * duration of the transaction.
   */
  transaction<T>(fn: (tx: Queryable) => Promise<T>, ctx?: SessionContext): Promise<T>;
  /**
   * A view of the database that runs every statement under `ctx`. Each `query`
   * is its own transaction, because RLS settings are transaction-scoped.
   */
  as(ctx: SessionContext): ScopedDatabase;
  close(): Promise<void>;
}

export interface ScopedDatabase extends Queryable {
  transaction<T>(fn: (tx: Queryable) => Promise<T>): Promise<T>;
}

/** Shared `as()` implementation: every statement runs in a scoped transaction. */
function scopedView(db: Database, ctx: SessionContext): ScopedDatabase {
  return {
    query: (sql, params) => db.transaction(tx => tx.query(sql, params), ctx),
    exec: sql => db.transaction(tx => tx.exec(sql), ctx),
    transaction: fn => db.transaction(fn, ctx)
  };
}

// ---------------------------------------------------------------------------
// PostgreSQL (pg Pool)
// ---------------------------------------------------------------------------

/**
 * Resolves TLS settings. `DATABASE_SSL` wins when set; otherwise we infer:
 * remote hosts (Supabase/Neon/RDS/etc.) get TLS, localhost does not.
 */
function resolveSsl(connectionString: string): PoolConfig['ssl'] {
  const mode = (process.env.DATABASE_SSL || '').trim().toLowerCase();
  const ca = process.env.DATABASE_SSL_CA
    ? fs.readFileSync(path.resolve(process.env.DATABASE_SSL_CA), 'utf-8')
    : undefined;

  if (mode === 'disable' || mode === 'false' || mode === 'off') return undefined;
  if (mode === 'verify-full' || mode === 'strict') return { rejectUnauthorized: true, ca };
  if (mode === 'require' || mode === 'true' || mode === 'no-verify') {
    return { rejectUnauthorized: false, ca };
  }

  // Auto-detect from the connection string.
  try {
    const url = new URL(connectionString);
    const sslmode = url.searchParams.get('sslmode');
    if (sslmode === 'disable') return undefined;
    if (sslmode === 'verify-full' || sslmode === 'verify-ca') return { rejectUnauthorized: true, ca };
    if (sslmode) return { rejectUnauthorized: false, ca };

    const host = url.hostname;
    const isLocal = host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === 'db' || host === 'postgres';
    return isLocal ? undefined : { rejectUnauthorized: false, ca };
  } catch {
    return undefined;
  }
}

/** Strips credentials so a connection target can be logged safely. */
function describeConnection(connectionString: string): string {
  try {
    const url = new URL(connectionString);
    const db = url.pathname.replace(/^\//, '') || 'postgres';
    return `postgres://${url.hostname}:${url.port || '5432'}/${db}`;
  } catch {
    return 'postgres (connection string)';
  }
}

function toResult<T>(res: { rows: T[]; rowCount: number | null }): QueryResult<T> {
  return { rows: res.rows, rowCount: res.rowCount ?? res.rows.length };
}

class PostgresDatabase implements Database {
  readonly driver: DriverName = 'postgres';
  readonly description: string;
  private pool: PgPool;

  constructor(connectionString: string) {
    this.description = describeConnection(connectionString);
    this.pool = new Pool({
      connectionString,
      ssl: resolveSsl(connectionString),
      max: parseInt(process.env.DATABASE_POOL_MAX || '10', 10),
      idleTimeoutMillis: parseInt(process.env.DATABASE_IDLE_TIMEOUT_MS || '30000', 10),
      connectionTimeoutMillis: parseInt(process.env.DATABASE_CONNECT_TIMEOUT_MS || '10000', 10),
      application_name: 'america-ships-on-click'
    });

    // An idle client erroring out (server restart, network blip) must not take
    // the process down; the pool discards it and reconnects on next checkout.
    this.pool.on('error', err => {
      console.error('[DB] Idle client error (connection will be recycled):', err.message);
    });
  }

  async query<T = any>(sql: string, params: any[] = []): Promise<QueryResult<T>> {
    const res = await this.pool.query<any>(sql, params);
    return toResult<T>(res as any);
  }

  async exec(sql: string): Promise<void> {
    // No bind params => simple query protocol, which allows multiple statements.
    await this.pool.query(sql);
  }

  as(ctx: SessionContext): ScopedDatabase {
    return scopedView(this, ctx);
  }

  async transaction<T>(fn: (tx: Queryable) => Promise<T>, ctx?: SessionContext): Promise<T> {
    const client: PoolClient = await this.pool.connect();
    const tx: Queryable = {
      query: async <R = any>(sql: string, params: any[] = []) =>
        toResult<R>(await client.query<any>(sql, params) as any),
      exec: async (sql: string) => {
        await client.query(sql);
      }
    };

    try {
      await client.query('BEGIN');
      if (ctx) {
        await client.query(SET_CONTEXT_SQL, contextParams(ctx));
      }
      const result = await fn(tx);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (rollbackErr: any) {
        console.error('[DB] Rollback failed:', rollbackErr?.message);
      }
      throw err;
    } finally {
      client.release();
    }
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}

// ---------------------------------------------------------------------------
// PGlite (embedded fallback)
// ---------------------------------------------------------------------------

class PgliteDatabase implements Database {
  readonly driver: DriverName = 'pglite';
  readonly description: string;
  private pglite: PGlite;

  constructor(dataDir: string) {
    fs.mkdirSync(path.dirname(dataDir), { recursive: true });
    this.description = `pglite://${path.relative(process.cwd(), dataDir) || dataDir}`;
    this.pglite = new PGlite(dataDir);
  }

  async query<T = any>(sql: string, params: any[] = []): Promise<QueryResult<T>> {
    const res = await this.pglite.query<T>(sql, params);
    return { rows: res.rows, rowCount: res.affectedRows ?? res.rows.length };
  }

  async exec(sql: string): Promise<void> {
    await this.pglite.exec(sql);
  }

  as(ctx: SessionContext): ScopedDatabase {
    return scopedView(this, ctx);
  }

  async transaction<T>(fn: (tx: Queryable) => Promise<T>, ctx?: SessionContext): Promise<T> {
    const result = await this.pglite.transaction(async pgliteTx => {
      // PGlite connects as a superuser, which bypasses RLS. The context is
      // still set so audit rows carry the actor, and so behaviour matches
      // PostgreSQL as closely as the embedded engine allows.
      if (ctx) {
        await pgliteTx.query(SET_CONTEXT_SQL, contextParams(ctx));
      }
      const tx: Queryable = {
        query: async <R = any>(sql: string, params: any[] = []) => {
          const res = await pgliteTx.query<R>(sql, params);
          return { rows: res.rows, rowCount: res.affectedRows ?? res.rows.length };
        },
        exec: async (sql: string) => {
          await pgliteTx.exec(sql);
        }
      };
      return fn(tx);
    });
    return result as T;
  }

  async close(): Promise<void> {
    await this.pglite.close();
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export const PGLITE_DATA_DIR = path.join(process.cwd(), '.data', 'pgdata');

export function createDatabaseFromUrl(connectionString: string): Database {
  return new PostgresDatabase(connectionString);
}

/**
 * The privileged connection used for migrations and seeding, when the runtime
 * connection is a restricted role that (by design) cannot run DDL.
 * Returns null when no separate owner connection is configured.
 */
export function createAdminDatabase(): Database | null {
  const adminUrl = (process.env.DATABASE_ADMIN_URL || '').trim();
  const appUrl = (process.env.DATABASE_URL || '').trim();
  if (!adminUrl || adminUrl === appUrl) return null;
  return new PostgresDatabase(adminUrl);
}

export function createDatabase(): Database {
  const connectionString = (process.env.DATABASE_URL || '').trim();

  if (connectionString) {
    return new PostgresDatabase(connectionString);
  }

  if (process.env.NODE_ENV === 'production') {
    // Embedded storage on an ephemeral production filesystem silently loses
    // every settlement on redeploy — refuse instead of pretending to persist.
    throw new Error(
      'DATABASE_URL is required when NODE_ENV=production. ' +
      'Set it to your PostgreSQL connection string (see .env.example).'
    );
  }

  console.warn(
    '[DB] DATABASE_URL not set — falling back to embedded PGlite. ' +
    'Set DATABASE_URL to use a real PostgreSQL server.'
  );
  return new PgliteDatabase(PGLITE_DATA_DIR);
}
