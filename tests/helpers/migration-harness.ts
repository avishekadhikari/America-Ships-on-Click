/**
 * Applies the real migration files to a throwaway embedded database.
 *
 * Tests run against the same SQL production runs — not a hand-maintained
 * fixture schema — so a migration that does not apply fails the suite instead
 * of failing a deploy.
 */
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import os from 'os';
import path from 'path';

export const MIGRATIONS_DIR = path.join(process.cwd(), 'database', 'migrations');

export function migrationFiles(): string[] {
  return fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
}

export interface Harness {
  pg: PGlite;
  dataDir: string;
  destroy(): Promise<void>;
}

/** Fresh database with every migration applied, in a temp directory. */
export async function createMigratedDatabase(): Promise<Harness> {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'asoc-test-'));
  const pg = new PGlite(dataDir);

  // The real runner creates this ledger before the first migration; 0002 grants
  // SELECT on it, so it has to exist here too.
  await pg.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    TEXT PRIMARY KEY,
      checksum   TEXT NOT NULL,
      applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
  `);

  for (const file of migrationFiles()) {
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf-8');
    try {
      await pg.exec(sql);
    } catch (err: any) {
      await pg.close();
      throw new Error(`Migration ${file} failed to apply: ${err.message}`);
    }
  }

  return {
    pg,
    dataDir,
    async destroy() {
      await pg.close();
      fs.rmSync(dataDir, { recursive: true, force: true });
    }
  };
}
