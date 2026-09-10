/**
 * Database CLI — `npm run db:migrate | db:seed | db:status | db:reset`.
 *
 * Operates on whatever backend the environment points at: a real PostgreSQL
 * server via DATABASE_URL, or the embedded PGlite store when it is unset.
 */
import 'dotenv/config';
import fs from 'fs';
import { PGLITE_DATA_DIR } from './client';
import { closeDb, db, getDb, getMigrationDb, isDatabaseEmpty, migrationStatus, runMigrations, seedDatabase } from './index';

const USAGE = `
Usage: tsx database/cli.ts <command> [--force]

Commands:
  migrate   Apply pending migrations
  seed      Insert demo data (skipped unless the database is empty, or --force)
  status    Show connection target and migration state
  reset     DESTRUCTIVE: drop all data, re-migrate, re-seed (requires --force)
  ping      Verify the database is reachable
`.trim();

async function main(): Promise<void> {
  const [command, ...flags] = process.argv.slice(2);
  const force = flags.includes('--force');

  switch (command) {
    case 'migrate': {
      const { db: target, isSeparate } = getMigrationDb();
      const applied = await runMigrations(target);
      if (isSeparate) await target.close();
      console.log(
        applied.length ? `Applied: ${applied.join(', ')}` : 'Nothing to apply — schema is up to date.'
      );
      break;
    }

    case 'seed': {
      const { db: target, isSeparate } = getMigrationDb();
      try {
        if (!(await isDatabaseEmpty(target)) && !force) {
          console.log('Database already contains users. Re-run with --force to seed anyway.');
          break;
        }
        await seedDatabase(target);
      } finally {
        if (isSeparate) await target.close();
      }
      break;
    }

    case 'status': {
      const { db: target, isSeparate } = getMigrationDb();
      console.log(`Runtime  : ${db.description} (driver: ${db.driver})`);
      if (isSeparate) console.log(`Owner    : ${target.description}`);
      const rows = await migrationStatus(target);
      if (isSeparate) await target.close();
      console.log('\nMigrations:');
      for (const row of rows) {
        const state = row.applied ? `applied ${row.appliedAt}` : 'PENDING';
        const drift = row.checksumChanged ? '  [checksum changed since applied]' : '';
        console.log(`  ${row.version.padEnd(28)} ${state}${drift}`);
      }
      break;
    }

    case 'reset': {
      if (process.env.NODE_ENV === 'production') {
        throw new Error('Refusing to reset the database while NODE_ENV=production.');
      }
      if (!force) {
        throw new Error(`This deletes every row in ${db.description}. Re-run with --force.`);
      }

      if (db.driver === 'postgres') {
        const { db: owner, isSeparate } = getMigrationDb();
        console.log(`Dropping and recreating schema "public" in ${owner.description}...`);
        await owner.exec('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
        await runMigrations(owner);
        await seedDatabase(owner);
        if (isSeparate) await owner.close();
        console.log('Reset complete.');
        break;
      } else {
        console.log(`Deleting embedded data directory ${PGLITE_DATA_DIR}...`);
        await closeDb();
        fs.rmSync(PGLITE_DATA_DIR, { recursive: true, force: true });
      }

      await runMigrations(getDb());
      await seedDatabase(getDb());
      console.log('Reset complete.');
      break;
    }

    case 'ping': {
      await db.query('SELECT 1');
      console.log(`OK — ${db.description} is reachable.`);
      break;
    }

    default:
      console.log(USAGE);
      if (command) process.exitCode = 1;
  }
}

main()
  .catch(err => {
    console.error(`[DB CLI] ${err.message}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closeDb().catch(() => {});
  });
