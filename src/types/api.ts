export type UserRole = 'driver' | 'shipper' | 'admin';
export type EquipmentType = 'dry_van' | 'reefer' | 'flatbed' | 'step_deck' | 'power_only';
export type LoadStatus = 'open' | 'booked' | 'in_transit' | 'delivered' | 'cancelled';
export type BookingStatus = 'active' | 'completed' | 'cancelled';

export interface PlatformConfig {
  fee_pct: number;
  factor_pct: number;
  broker_comparison_pct: number;
  fuel_rate_per_mile: number;
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
  phone: string;
  email: string;
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
}
