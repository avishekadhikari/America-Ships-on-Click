-- Street, ZIP, and full pickup/drop labels on loads.
--
-- The map already geocodes an exact dock, a street, a ZIP, or a city. Until
-- now only city + state were stored, so the board could not find a load by
-- the address the shipper asked the driver to come to. These columns keep
-- that place; origin_city / dest_city stay required so older city-only rows
-- and analytics keep working.

ALTER TABLE loads ADD COLUMN IF NOT EXISTS origin_street  TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS origin_zip     TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS origin_address TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS dest_street    TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS dest_zip       TEXT;
ALTER TABLE loads ADD COLUMN IF NOT EXISTS dest_address   TEXT;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_origin_zip_format
    CHECK (origin_zip IS NULL OR origin_zip ~ '^\d{5}(-\d{4})?$');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_dest_zip_format
    CHECK (dest_zip IS NULL OR dest_zip ~ '^\d{5}(-\d{4})?$');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_origin_street_len
    CHECK (origin_street IS NULL OR char_length(origin_street) BETWEEN 1 AND 120);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_dest_street_len
    CHECK (dest_street IS NULL OR char_length(dest_street) BETWEEN 1 AND 120);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_origin_address_len
    CHECK (origin_address IS NULL OR char_length(origin_address) BETWEEN 1 AND 200);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE loads ADD CONSTRAINT loads_dest_address_len
    CHECK (dest_address IS NULL OR char_length(dest_address) BETWEEN 1 AND 200);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_loads_origin_zip ON loads (origin_zip) WHERE origin_zip IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_loads_dest_zip   ON loads (dest_zip)   WHERE dest_zip   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_loads_origin_address_lower ON loads (lower(origin_address)) WHERE origin_address IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_loads_dest_address_lower   ON loads (lower(dest_address))   WHERE dest_address   IS NOT NULL;
