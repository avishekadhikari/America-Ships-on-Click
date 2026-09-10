import { createMigratedDatabase } from '/home/avishek/Desktop/America-Ships-on-Click-main/tests/helpers/migration-harness.ts';
async function main() {
  const h = await createMigratedDatabase();
  console.log('All migrations applied cleanly.');
  await h.destroy();
}
main().catch(e => { console.error(String(e.message)); process.exit(1); });
