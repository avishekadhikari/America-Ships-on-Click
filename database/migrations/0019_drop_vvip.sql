-- Golden VVIP is retired. Migrations 0013 and 0014 created the interest
-- list and its public write path. This drops both.
--
-- DROP TABLE does not fire the append-only row trigger, so the owner can
-- remove the table without a row-level DELETE.

DROP FUNCTION IF EXISTS app_vvip_preregister(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP TABLE IF EXISTS vvip_leads;
