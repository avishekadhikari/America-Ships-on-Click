/**
 * Lane geocoding for Post Load. Nominatim (OSM) for US city lookup,
 * OSRM for driving miles. Browser clients cannot set Nominatim's required
 * User-Agent, so the app proxies these instead of calling them from the SPA.
 */

const NOMINATIM = 'https://nominatim.openstreetmap.org';
const OSRM = 'https://router.project-osrm.org';
const USER_AGENT = 'AmericaShipsOnClick/1.0 (https://www.americashipsonclick.com; freight lane geocode)';

export type GeoPlace = {
  city: string;
  state: string;
  lat: number;
  lng: number;
  label: string;
};

export type GeoRoute = {
  miles: number;
  geometry: [number, number][];
};

const STATE_BY_NAME: Record<string, string> = {
  alabama: 'AL', alaska: 'AK', arizona: 'AZ', arkansas: 'AR', california: 'CA',
  colorado: 'CO', connecticut: 'CT', delaware: 'DE', 'district of columbia': 'DC',
  florida: 'FL', georgia: 'GA', hawaii: 'HI', idaho: 'ID', illinois: 'IL',
  indiana: 'IN', iowa: 'IA', kansas: 'KS', kentucky: 'KY', louisiana: 'LA',
  maine: 'ME', maryland: 'MD', massachusetts: 'MA', michigan: 'MI',
  minnesota: 'MN', mississippi: 'MS', missouri: 'MO', montana: 'MT',
  nebraska: 'NE', nevada: 'NV', 'new hampshire': 'NH', 'new jersey': 'NJ',
  'new mexico': 'NM', 'new york': 'NY', 'north carolina': 'NC', 'north dakota': 'ND',
  ohio: 'OH', oklahoma: 'OK', oregon: 'OR', pennsylvania: 'PA', 'rhode island': 'RI',
  'south carolina': 'SC', 'south dakota': 'SD', tennessee: 'TN', texas: 'TX',
  utah: 'UT', vermont: 'VT', virginia: 'VA', washington: 'WA',
  'west virginia': 'WV', wisconsin: 'WI', wyoming: 'WY'
};

type NominatimAddress = Record<string, unknown>;

type NominatimHit = {
  lat?: string;
  lon?: string;
  address?: NominatimAddress;
};

function usStateCode(address: NominatimAddress): string | null {
  const iso = address['ISO3166-2-lvl4'] ?? address['ISO3166-2-lvl3'];
  if (typeof iso === 'string' && iso.startsWith('US-') && iso.length === 5) {
    return iso.slice(3);
  }
  if (typeof address.state_code === 'string' && address.state_code.length === 2) {
    return address.state_code.toUpperCase();
  }
  if (typeof address.state === 'string') {
    const mapped = STATE_BY_NAME[address.state.toLowerCase()];
    if (mapped) return mapped;
    if (/^[A-Za-z]{2}$/.test(address.state)) return address.state.toUpperCase();
  }
  return null;
}

function cityFromAddress(address: NominatimAddress): string | null {
  const keys = ['city', 'town', 'village', 'hamlet', 'municipality', 'county'];
  for (const key of keys) {
    const value = address[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return null;
}

function placeFromNominatim(hit: NominatimHit): GeoPlace | null {
  const address = hit.address;
  if (!address) return null;
  if (String(address.country_code || '').toLowerCase() !== 'us') return null;
  const state = usStateCode(address);
  const city = cityFromAddress(address);
  const lat = parseFloat(String(hit.lat ?? ''));
  const lng = parseFloat(String(hit.lon ?? ''));
  if (!state || !city || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  return { city, state, lat, lng, label: `${city}, ${state}` };
}

async function nominatimGet(url: URL): Promise<unknown> {
  const res = await fetch(url, {
    headers: {
      Accept: 'application/json',
      'User-Agent': USER_AGENT
    },
    signal: AbortSignal.timeout(8000)
  });
  if (!res.ok) {
    throw new Error(`Geocoder returned ${res.status}`);
  }
  return res.json();
}

export async function searchPlaces(q: string): Promise<GeoPlace[]> {
  const url = new URL(`${NOMINATIM}/search`);
  url.searchParams.set('q', q);
  url.searchParams.set('format', 'json');
  url.searchParams.set('addressdetails', '1');
  url.searchParams.set('countrycodes', 'us');
  url.searchParams.set('limit', '6');
  const data = await nominatimGet(url);
  if (!Array.isArray(data)) return [];
  const seen = new Set<string>();
  const places: GeoPlace[] = [];
  for (const hit of data) {
    const place = placeFromNominatim(hit as NominatimHit);
    if (!place) continue;
    const key = `${place.city}|${place.state}`;
    if (seen.has(key)) continue;
    seen.add(key);
    places.push(place);
  }
  return places;
}

export async function reversePlace(lat: number, lng: number): Promise<GeoPlace | null> {
  const url = new URL(`${NOMINATIM}/reverse`);
  url.searchParams.set('lat', String(lat));
  url.searchParams.set('lon', String(lng));
  url.searchParams.set('format', 'json');
  url.searchParams.set('addressdetails', '1');
  url.searchParams.set('zoom', '10');
  const data = await nominatimGet(url);
  return placeFromNominatim(data as NominatimHit);
}

function haversineMiles(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const r = 3958.8;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const h = sinLat * sinLat + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * sinLng * sinLng;
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(h)));
}

export async function drivingRoute(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number }
): Promise<GeoRoute> {
  const path = `${from.lng},${from.lat};${to.lng},${to.lat}`;
  const url = new URL(`${OSRM}/route/v1/driving/${path}`);
  url.searchParams.set('overview', 'simplified');
  url.searchParams.set('geometries', 'geojson');

  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`Router returned ${res.status}`);
    const data = await res.json() as {
      code?: string;
      routes?: Array<{
        distance: number;
        geometry?: { coordinates?: number[][] };
      }>;
    };
    const route = data.routes?.[0];
    if (data.code !== 'Ok' || !route) throw new Error('No driving route');
    const miles = Math.max(1, Math.round(route.distance / 1609.344));
    const geometry: [number, number][] = (route.geometry?.coordinates ?? []).map(
      ([lng, lat]) => [lat, lng] as [number, number]
    );
    return { miles, geometry };
  } catch {
    // Highway circuity vs great-circle; used only if the public router is down.
    const miles = Math.max(1, Math.round(haversineMiles(from, to) * 1.18));
    return {
      miles,
      geometry: [[from.lat, from.lng], [to.lat, to.lng]]
    };
  }
}
