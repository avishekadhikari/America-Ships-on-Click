/**
 * Versioned SQL migration runner.
 *
 * Every `*.sql` file in the migrations directory is applied once, in filename
 * order, and recorded in `schema_migrations`. All pending files run inside a
 * single transaction (Postgres DDL is transactional), so a failure halfway
 * through leaves the schema untouched rather than half-migrated.
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import type { Database, Queryable } from './client';

/** Arbitrary but fixed key so concurrent instances serialize on the same lock. */
const MIGRATION_LOCK_KEY = 8_675_309;

const SCHEMA_MIGRATIONS_DDL = `
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    TEXT PRIMARY KEY,
  checksum   TEXT NOT NULL,
  applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`;

function moduleDir(): string {
  try {
    // ESM (tsx / vite dev)
    return path.dirname(fileURLToPath(import.meta.url));
  } catch {
    // CJS bundle (dist/server.cjs)
    return typeof __dirname !== 'undefined' ? __dirname : process.cwd();
  }
}

/**
 * Finds the migrations directory across dev (`database/migrations`) and the
 * bundled production layout (`dist/migrations`). `MIGRATIONS_DIR` overrides.
 */
export function resolveMigrationsDir(): string {
  const candidates = [
    process.env.MIGRATIONS_DIR,
    path.join(process.cwd(), 'database', 'migrations'),
    path.join(process.cwd(), 'dist', 'migrations'),
    path.join(process.cwd(), 'migrations'),
    path.join(moduleDir(), 'migrations'),
    path.join(moduleDir(), '..', 'migrations')
  ].filter(Boolean) as string[];

  for (const dir of candidates) {
    if (fs.existsSync(dir) && fs.statSync(dir).isDirectory()) return dir;
  }
  throw new Error(
    `No migrations directory found. Looked in:\n  ${candidates.join('\n  ')}\n` +
    'Set MIGRATIONS_DIR to point at it.'
  );
}

export interface MigrationFile {
  version: string;
  filePath: string;
  sql: string;
  checksum: string;
}

export function loadMigrationFiles(dir = resolveMigrationsDir()): MigrationFile[] {
  return fs
    .readdirSync(dir)
    .filter(f => f.endsWith('.sql'))
    .sort()
    .map(file => {
      const filePath = path.join(dir, file);
      const sql = fs.readFileSync(filePath, 'utf-8');
      return {
        version: file.replace(/\.sql$/, ''),
        filePath,
        sql,
        checksum: crypto.createHash('sha256').update(sql).digest('hex').slice(0, 16)
      };
    });
}

async function appliedVersions(tx: Queryable): Promise<Map<string, string>> {
  const res = await tx.query<{ version: string; checksum: string }>(
    'SELECT version, checksum FROM schema_migrations'
  );
  return new Map(res.rows.map(r => [r.version, r.checksum]));
}

/** Applies every pending migration. Returns the versions that were applied. */
export async function runMigrations(db: Database): Promise<string[]> {
  const migrations = loadMigrationFiles();

  return db.transaction(async tx => {
    // Serialize concurrent boots (multiple app instances / a rolling deploy).
    // Transaction-scoped, so the lock is released by COMMIT or ROLLBACK.
    if (db.driver === 'postgres') {
      await tx.query('SELECT pg_advisory_xact_lock($1)', [MIGRATION_LOCK_KEY]);
    }

    await tx.exec(SCHEMA_MIGRATIONS_DDL);
    const applied = await appliedVersions(tx);
    const appliedNow: string[] = [];

    for (const migration of migrations) {
      const previousChecksum = applied.get(migration.version);

      if (previousChecksum !== undefined) {
        if (previousChecksum !== migration.checksum) {
          console.warn(
            `[DB] Migration ${migration.version} changed since it was applied ` +
            `(${previousChecksum} -> ${migration.checksum}). Add a new migration ` +
            'instead of editing an applied one.'
          );
        }
        continue;
      }

      console.log(`[DB] Applying migration ${migration.version}`);
      await tx.exec(migration.sql);
      await tx.query(
        'INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)',
        [migration.version, migration.checksum]
      );
      appliedNow.push(migration.version);
    }

    return appliedNow;
  });
}

export interface MigrationStatus {
  version: string;
  applied: boolean;
  appliedAt: string | null;
  checksumChanged: boolean;
}

export async function migrationStatus(db: Database): Promise<MigrationStatus[]> {
  // Read-only: reporting status must work over a connection that has no DDL
  // rights, so the ledger table is queried rather than created.
  const exists = await db.query<{ present: boolean }>(
    "SELECT to_regclass('public.schema_migrations') IS NOT NULL AS present"
  );

  const applied = new Map<string, { version: string; checksum: string; applied_at: string }>();
  if (exists.rows[0]?.present) {
    const res = await db.query<{ version: string; checksum: string; applied_at: string }>(
      'SELECT version, checksum, applied_at FROM schema_migrations'
    );
    res.rows.forEach(r => applied.set(r.version, r));
  }

  return loadMigrationFiles().map(m => {
    const row = applied.get(m.version);
    return {
      version: m.version,
      applied: Boolean(row),
      appliedAt: row ? new Date(row.applied_at).toISOString() : null,
      checksumChanged: Boolean(row && row.checksum !== m.checksum)
    };
  });
}
