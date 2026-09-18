import type { Load } from '../types/api';

/** City centroids used when a load was posted before lat/lng existed. */
const CITY_COORDS: Record<string, [number, number]> = {
  'atlanta|GA': [33.749, -84.388],
  'boise|ID': [43.615, -116.2023],
  'boston|MA': [42.3601, -71.0589],
  'charlotte|NC': [35.2271, -80.8431],
  'chicago|IL': [41.8781, -87.6298],
  'columbus|OH': [39.9612, -82.9988],
  'dallas|TX': [32.7767, -96.797],
  'denver|CO': [39.7392, -104.9903],
  'harrisburg|PA': [40.2732, -76.8867],
  'houston|TX': [29.7604, -95.3698],
  'indianapolis|IN': [39.7684, -86.1581],
  'kansas city|MO': [39.0997, -94.5786],
  'laredo|TX': [27.5306, -99.4803],
  'los angeles|CA': [34.0522, -118.2437],
  'memphis|TN': [35.1495, -90.049],
  'miami|FL': [25.7617, -80.1918],
  'nashville|TN': [36.1627, -86.7816],
  'newark|NJ': [40.7357, -74.1724],
  'ontario|CA': [34.0633, -117.6509],
  'phoenix|AZ': [33.4484, -112.074],
  'reno|NV': [39.5296, -119.8138],
  'salt lake city|UT': [40.7608, -111.891],
  'savannah|GA': [32.0809, -81.0912],
  'seattle|WA': [47.6062, -122.3321]
};

export type LatLng = { lat: number; lng: number };

export function asCoord(value: unknown): number | null {
  if (value == null || value === '') return null;
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

function cityKey(city: string, state: string): string {
  return `${city.trim().toLowerCase()}|${state.trim().toUpperCase()}`;
}

function cityCentroid(city: string, state: string): LatLng | null {
  const pair = CITY_COORDS[cityKey(city, state)];
  return pair ? { lat: pair[0], lng: pair[1] } : null;
}

export function lanePlace(city: string, state: string, address?: string): string {
  return address || `${city}, ${state}`;
}

export function pickupCoords(load: Pick<Load, 'origin_lat' | 'origin_lng' | 'origin_city' | 'origin_state'>): LatLng | null {
  const lat = asCoord(load.origin_lat);
  const lng = asCoord(load.origin_lng);
  if (lat != null && lng != null) return { lat, lng };
  return cityCentroid(load.origin_city, load.origin_state);
}

export function dropCoords(load: Pick<Load, 'dest_lat' | 'dest_lng' | 'dest_city' | 'dest_state'>): LatLng | null {
  const lat = asCoord(load.dest_lat);
  const lng = asCoord(load.dest_lng);
  if (lat != null && lng != null) return { lat, lng };
  return cityCentroid(load.dest_city, load.dest_state);
}
