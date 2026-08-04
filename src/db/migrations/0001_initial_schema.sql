-- America Ships On Click: Initial PostgreSQL Schema Migration

-- 1. ENUMS
CREATE TYPE user_role AS ENUM ('driver', 'shipper', 'admin');
CREATE TYPE verification_status AS ENUM ('pending', 'verified', 'rejected');
CREATE TYPE cdl_class AS ENUM ('A', 'B');
CREATE TYPE doc_type AS ENUM ('cdl_photo', 'dot_authority', 'coi', 'pod');
CREATE TYPE equipment_type AS ENUM ('dry_van', 'reefer', 'flatbed', 'step_deck', 'power_only');
CREATE TYPE load_status AS ENUM ('open', 'booked', 'in_transit', 'delivered', 'cancelled');
CREATE TYPE booking_status AS ENUM ('active', 'completed', 'cancelled');

-- 2. USERS
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  role user_role NOT NULL DEFAULT 'driver',
  email TEXT UNIQUE NOT NULL,
  phone TEXT,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. DRIVER PROFILES
CREATE TABLE IF NOT EXISTS driver_profiles (
  id TEXT PRIMARY KEY,
  user_id TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  full_name TEXT NOT NULL,
  home_base_city TEXT NOT NULL,
  home_base_state TEXT NOT NULL,
  cdl_number TEXT,
  cdl_class cdl_class DEFAULT 'A',
  dot_number TEXT,
  mc_number TEXT,
  verification_status verification_status DEFAULT 'pending',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. DRIVER DOCUMENTS
CREATE TABLE IF NOT EXISTS driver_documents (
  id TEXT PRIMARY KEY,
  driver_id TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  doc_type doc_type NOT NULL,
  file_url TEXT NOT NULL,
  uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  verified BOOLEAN DEFAULT FALSE
);

-- 5. DRIVER EQUIPMENT
CREATE TABLE IF NOT EXISTS driver_equipment (
  id TEXT PRIMARY KEY,
  driver_id TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  equipment_type equipment_type NOT NULL DEFAULT 'dry_van',
  trailer_length_ft INTEGER DEFAULT 53
);

-- 6. DRIVER PAYMENT ACCOUNTS
CREATE TABLE IF NOT EXISTS driver_payment_accounts (
  id TEXT PRIMARY KEY,
  driver_id TEXT UNIQUE NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  payment_processor TEXT NOT NULL DEFAULT 'stripe',
  processor_account_id TEXT NOT NULL,
  same_day_funding_opt_in BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 7. SHIPPER PROFILES
CREATE TABLE IF NOT EXISTS shipper_profiles (
  id TEXT PRIMARY KEY,
  user_id TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  company_name TEXT NOT NULL,
  billing_email TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 8. LOADS
CREATE TABLE IF NOT EXISTS loads (
  id TEXT PRIMARY KEY,
  shipper_id TEXT NOT NULL REFERENCES shipper_profiles(id) ON DELETE RESTRICT,
  origin_city TEXT NOT NULL,
  origin_state TEXT NOT NULL,
  dest_city TEXT NOT NULL,
  dest_state TEXT NOT NULL,
  miles NUMERIC NOT NULL,
  rate_per_mile NUMERIC NOT NULL,
  equipment_type equipment_type NOT NULL DEFAULT 'dry_van',
  pickup_date TEXT NOT NULL,
  weight_lbs NUMERIC,
  notes TEXT,
  same_day_funding_offered BOOLEAN DEFAULT FALSE,
  status load_status DEFAULT 'open',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 9. BOOKINGS
CREATE TABLE IF NOT EXISTS bookings (
  id TEXT PRIMARY KEY,
  load_id TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  driver_id TEXT NOT NULL REFERENCES driver_profiles(id) ON DELETE RESTRICT,
  booked_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  status booking_status DEFAULT 'active',
  pod_url TEXT,
  delivered_at TIMESTAMP WITH TIME ZONE
);

-- Partial Unique Index to prevent double-booking on non-cancelled bookings:
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_active_booking ON bookings (load_id) WHERE status NOT IN ('cancelled');

-- 10. SETTLEMENTS ("Open Books" Ledger)
CREATE TABLE IF NOT EXISTS settlements (
  id TEXT PRIMARY KEY,
  booking_id TEXT UNIQUE NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  load_id TEXT NOT NULL REFERENCES loads(id) ON DELETE RESTRICT,
  miles NUMERIC NOT NULL,
  rate_per_mile NUMERIC NOT NULL,
  fuel_rate_per_mile NUMERIC NOT NULL DEFAULT 0.45,
  gross_amount NUMERIC NOT NULL,
  fee_amount NUMERIC NOT NULL,
  fee_pct_applied NUMERIC NOT NULL,
  fuel_cost NUMERIC NOT NULL,
  factor_cost NUMERIC NOT NULL DEFAULT 0,
  factored BOOLEAN DEFAULT FALSE,
  net_amount NUMERIC NOT NULL,
  settled_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 11. PLATFORM CONFIG
CREATE TABLE IF NOT EXISTS platform_config (
  key TEXT PRIMARY KEY,
  value NUMERIC NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Initial rows for platform config
INSERT INTO platform_config (key, value) VALUES
  ('fee_pct', 0.05),
  ('factor_pct', 0.03),
  ('broker_comparison_pct', 0.20),
  ('fuel_rate_per_mile', 0.45)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP;

-- 12. VIEWS
CREATE OR REPLACE VIEW public_ledger_view AS
SELECT 
  s.id,
  s.load_id,
  l.origin_city,
  l.origin_state,
  l.dest_city,
  l.dest_state,
  l.equipment_type,
  s.miles,
  s.rate_per_mile,
  s.fuel_rate_per_mile,
  s.gross_amount,
  s.fee_amount,
  s.fee_pct_applied,
  s.fuel_cost,
  s.factor_cost,
  s.factored,
  s.net_amount,
  s.settled_at
FROM settlements s
JOIN loads l ON s.load_id = l.id
ORDER BY s.settled_at DESC;

CREATE OR REPLACE VIEW settlement_totals_view AS
SELECT 
  COUNT(*)::INTEGER AS count,
  COALESCE(SUM(miles), 0)::NUMERIC AS miles,
  COALESCE(SUM(gross_amount), 0)::NUMERIC AS gross,
  COALESCE(SUM(fee_amount), 0)::NUMERIC AS fee,
  COALESCE(SUM(fuel_cost), 0)::NUMERIC AS fuel,
  COALESCE(SUM(factor_cost), 0)::NUMERIC AS factor,
  COALESCE(SUM(net_amount), 0)::NUMERIC AS net
FROM settlements;

-- 13. INDEXES
CREATE INDEX IF NOT EXISTS idx_loads_search ON loads(status, origin_state, dest_state, equipment_type);
CREATE INDEX IF NOT EXISTS idx_settlements_settled_at ON settlements(settled_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookings_load_id ON bookings(load_id);
