export type UserRole = 'driver' | 'shipper' | 'admin';
export type EquipmentType =
  | 'cargo_van'
  | 'bumper_pull'
  | 'gooseneck_hotshot'
  | 'gooseneck_cdl_40'
  | 'gooseneck_specialized'
  | 'car_carrier'
  | 'flatbed'
  | 'oversize_legal'
  | 'oversize_permitted'
  | 'dry_van'
  | 'reefer'
  | 'step_deck'
  | 'power_only';
export type LoadStatus = 'open' | 'booked' | 'in_transit' | 'delivered' | 'cancelled';
export type BookingStatus = 'active' | 'completed' | 'cancelled';
export type VvipRole = 'shipper' | 'carrier' | 'fleet' | 'other';

export interface PlatformConfig {
  fee_pct: number;
  factor_pct: number;
  broker_comparison_pct: number;
  fuel_rate_per_mile: number;
  quote_gross_pct?: number;
  diesel_base_ppg?: number;
}

export interface RateCard {
  equipment_key: EquipmentType;
  label: string;
  cdl_required: boolean;
  rate_min_per_mile: number;
  rate_max_per_mile: number;
  base_rate_per_mile: number;
  short_haul_under_miles: number | null;
  short_haul_rate_min_per_mile: number | null;
  short_haul_rate_max_per_mile: number | null;
  short_haul_base_rate_per_mile: number | null;
  minimum_charge: number;
  short_haul_minimum_charge: number | null;
  deadhead_buffer_pct: number;
  fuel_mpg: number;
  express_surcharge_pct: number;
}

export interface AccessorialFee {
  code: string;
  label: string;
  amount: number;
  description?: string;
}

export interface RateCatalog {
  cards: RateCard[];
  accessorials: AccessorialFee[];
  diesel_ppg: number;
  diesel_base_ppg: number;
  quote_gross_pct: number;
  default_demand_multiplier: number;
}

export interface QuoteBreakdown {
  equipment_key: string;
  label: string;
  miles: number;
  applied_rate_per_mile: number;
  short_haul: boolean;
  linehaul_raw: number;
  minimum_floor: number;
  minimum_applied: boolean;
  linehaul: number;
  deadhead_miles: number;
  deadhead_from_miles: number;
  deadhead_from_buffer: number;
  deadhead_amount: number;
  diesel_ppg: number;
  diesel_base_ppg: number;
  fuel_mpg: number;
  fuel_surcharge_per_mile: number;
  fuel_surcharge: number;
  accessorials: { code: string; label: string; amount: number }[];
  accessorials_amount: number;
  demand_multiplier: number;
  express: boolean;
  express_surcharge_pct: number;
  after_demand: number;
  after_express: number;
  quote_gross_pct: number;
  gross_markup: number;
  quoted_total: number;
  quoted_rate_per_mile: number;
}

export interface RateQuoteLog {
  id: string;
  equipment_key: EquipmentType;
  equipment_label?: string;
  load_id?: string;
  miles: number;
  quoted_total: number;
  quoted_rate_per_mile: number;
  posted_rate_per_mile: number;
  overridden: boolean;
  created_at: string;
}

export interface GeoPlace {
  city: string;
  state: string;
  lat: number;
  lng: number;
  label: string;
}

export interface GeoRoute {
  miles: number;
  geometry: [number, number][];
}

export interface User {
  id: string;
  email: string;
  role: UserRole;
  driverId?: string;
  shipperId?: string;
  name?: string;
}

export interface Load {
  id: string;
  shipper_id: string;
  shipper_name?: string;
  origin_city: string;
  origin_state: string;
  dest_city: string;
  dest_state: string;
  miles: number;
  rate_per_mile: number;
  equipment_type: EquipmentType;
  pickup_date: string;
  weight_lbs?: number;
  notes?: string;
  same_day_funding_offered: boolean;
  status: LoadStatus;
  created_at: string;
}

export interface Booking {
  id: string;
  load_id: string;
  driver_id: string;
  booked_at: string;
  status: BookingStatus;
  pod_url?: string;
  delivered_at?: string;
}

export interface BookingWithLoad extends Booking {
  origin_city: string;
  origin_state: string;
  dest_city: string;
  dest_state: string;
  miles: number;
  rate_per_mile: number;
  equipment_type: EquipmentType;
  pickup_date: string;
  same_day_funding_offered: boolean;
  load_status: LoadStatus;
  shipper_id: string;
  weight_lbs?: number;
  notes?: string;
}

export interface PublicLedgerItem {
  id: string;
  load_id: string;
  origin_city: string;
  origin_state: string;
  dest_city: string;
  dest_state: string;
  equipment_type: EquipmentType;
  miles: number;
  rate_per_mile: number;
  fuel_rate_per_mile: number;
  gross_amount: number;
  fee_amount: number;
  fee_pct_applied: number;
  fuel_cost: number;
  factor_cost: number;
  factored: boolean;
  net_amount: number;
  settled_at: string;
}

export interface SettlementTotals {
  count: number;
  miles: number;
  gross: number;
  fee: number;
  fuel: number;
  factor: number;
  net: number;
}

export interface DriverOnboardInput {
  full_name: string;
  home_base_city: string;
  home_base_state: string;
  cdl_number?: string;
  cdl_class?: 'A' | 'B';
  dot_number?: string;
  mc_number?: string;
  equipment_type: EquipmentType;
  trailer_length_ft?: number;
  routing_number?: string;
  account_number?: string;
  same_day_funding_opt_in: boolean;
  cdl_photo_url?: string;
  dot_authority_url?: string;
  coi_url?: string;
}
