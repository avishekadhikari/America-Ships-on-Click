import React, { useEffect, useRef, useState } from 'react';
import * as L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { api } from '../lib/api';
import type { GeoPlace } from '../types/api';

type PickMode = 'origin' | 'dest';

interface LaneMapProps {
  origin: GeoPlace | null;
  dest: GeoPlace | null;
  onOriginChange: (place: GeoPlace) => void;
  onDestChange: (place: GeoPlace) => void;
  onMilesChange: (miles: number) => void;
}

function pinIcon(kind: PickMode): L.DivIcon {
  const letter = kind === 'origin' ? 'A' : 'B';
  const tone = kind === 'origin' ? 'origin' : 'dest';
  return L.divIcon({
    className: 'lane-pin',
    html: `<span class="lane-pin-dot ${tone}"><span class="lane-pin-letter">${letter}</span></span>`,
    iconSize: [28, 28],
    iconAnchor: [14, 28],
    popupAnchor: [0, -24]
  });
}

interface CitySearchProps {
  label: string;
  hint: string;
  placeholder: string;
  place: GeoPlace | null;
  active: boolean;
  onActivate: () => void;
  onSelect: (place: GeoPlace) => void;
}

const CitySearch: React.FC<CitySearchProps> = ({
  label,
  hint,
  placeholder,
  place,
  active,
  onActivate,
  onSelect
}) => {
  const [query, setQuery] = useState(place?.label ?? '');
  const [hits, setHits] = useState<GeoPlace[]>([]);
  const [open, setOpen] = useState(false);
  const [searching, setSearching] = useState(false);

  useEffect(() => {
    setQuery(place?.label ?? '');
  }, [place?.label]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2 || q === place?.label) {
      setHits([]);
      setSearching(false);
      return;
    }

    let cancelled = false;
    setSearching(true);
    const timer = window.setTimeout(() => {
      api.searchPlaces(q)
        .then((results) => {
          if (cancelled) return;
          setHits(results);
          setOpen(true);
        })
        .catch(() => {
          if (!cancelled) setHits([]);
        })
        .finally(() => {
          if (!cancelled) setSearching(false);
        });
    }, 320);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [query, place?.label]);

  const pick = (next: GeoPlace) => {
    setQuery(next.label);
    setHits([]);
    setOpen(false);
    onSelect(next);
  };

  return (
    <div className={`lane-search ${active ? 'is-active' : ''}`}>
      <button type="button" className="lane-search-tab" onClick={onActivate}>
        <span className="lane-search-letter">{hint}</span>
        {label}
      </button>
      <div className="relative">
        <input
          type="text"
          value={query}
          placeholder={placeholder}
          autoComplete="off"
          onFocus={onActivate}
          onChange={(e) => {
            onActivate();
            setQuery(e.target.value);
            setOpen(true);
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (hits[0]) pick(hits[0]);
            }
          }}
          className="w-full p-2.5 bg-[#F0EAD8] border border-[#E4DCC4] rounded text-sm"
        />
        {searching && (
          <span className="absolute right-2 top-1/2 -translate-y-1/2 font-mono text-[10px] uppercase tracking-wider text-[#5B6168]">
            …
          </span>
        )}
        {open && hits.length > 0 && (
          <ul className="lane-suggest" role="listbox">
            {hits.map((hit) => (
              <li key={`${hit.city}-${hit.state}-${hit.lat}`}>
                <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => pick(hit)}>
                  {hit.label}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
};

export const LaneMap: React.FC<LaneMapProps> = ({
  origin,
  dest,
  onOriginChange,
  onDestChange,
  onMilesChange
}) => {
  const mapElRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<L.Map | null>(null);
  const layersRef = useRef<{
    origin?: L.Marker;
    dest?: L.Marker;
    line?: L.Polyline;
  }>({});
  const pickModeRef = useRef<PickMode>('origin');
  const originCbRef = useRef(onOriginChange);
  const destCbRef = useRef(onDestChange);
  const milesCbRef = useRef(onMilesChange);

  const [pickMode, setPickMode] = useState<PickMode>(origin && !dest ? 'dest' : 'origin');
  const [locating, setLocating] = useState(false);
  const [measuring, setMeasuring] = useState(false);
  const [mapError, setMapError] = useState<string | null>(null);
  const [geometry, setGeometry] = useState<[number, number][]>([]);

  pickModeRef.current = pickMode;
  originCbRef.current = onOriginChange;
  destCbRef.current = onDestChange;
  milesCbRef.current = onMilesChange;

  useEffect(() => {
    const el = mapElRef.current;
    if (!el || mapRef.current) return;

    const map = L.map(el, {
      center: [39.5, -98.35],
      zoom: 4,
      minZoom: 3,
      maxZoom: 12,
      zoomControl: true,
      attributionControl: true
    });

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors',
      maxZoom: 12
    }).addTo(map);

    map.on('click', (event: L.LeafletMouseEvent) => {
      const mode = pickModeRef.current;
      setLocating(true);
      setMapError(null);
      api.reverseGeocode(event.latlng.lat, event.latlng.lng)
        .then((place) => {
          if (mode === 'origin') {
            originCbRef.current(place);
            setPickMode('dest');
          } else {
            destCbRef.current(place);
          }
        })
        .catch((err: Error) => {
          setMapError(err.message || 'Drop the pin on a US city.');
        })
        .finally(() => setLocating(false));
    });

    mapRef.current = map;
    const sizeTimer = window.setTimeout(() => map.invalidateSize(), 80);

    return () => {
      window.clearTimeout(sizeTimer);
      map.remove();
      mapRef.current = null;
      layersRef.current = {};
    };
  }, []);

  useEffect(() => {
    if (!origin || !dest) {
      setGeometry([]);
      setMeasuring(false);
      return;
    }

    let cancelled = false;
    setMeasuring(true);
    setMapError(null);
    api.drivingRoute(origin, dest)
      .then((route) => {
        if (cancelled) return;
        setGeometry(route.geometry);
        milesCbRef.current(route.miles);
      })
      .catch((err: Error) => {
        if (!cancelled) setMapError(err.message || 'Could not measure that lane.');
      })
      .finally(() => {
        if (!cancelled) setMeasuring(false);
      });

    return () => {
      cancelled = true;
    };
  }, [origin, dest]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const layers = layersRef.current;

    const upsert = (kind: PickMode, place: GeoPlace | null) => {
      const existing = layers[kind];
      if (!place) {
        if (existing) {
          map.removeLayer(existing);
          layers[kind] = undefined;
        }
        return;
      }
      const latlng: L.LatLngExpression = [place.lat, place.lng];
      if (existing) {
        existing.setLatLng(latlng);
        existing.setPopupContent(place.label);
      } else {
        layers[kind] = L.marker(latlng, { icon: pinIcon(kind), keyboard: false })
          .addTo(map)
          .bindPopup(place.label);
      }
    };

    upsert('origin', origin);
    upsert('dest', dest);

    if (layers.line) {
      map.removeLayer(layers.line);
      layers.line = undefined;
    }

    const linePoints = geometry.length >= 2
      ? geometry
      : origin && dest
        ? [[origin.lat, origin.lng], [dest.lat, dest.lng]] as [number, number][]
        : [];

    if (linePoints.length >= 2) {
      layers.line = L.polyline(linePoints, {
        color: '#0F5132',
        weight: 3,
        opacity: 0.85
      }).addTo(map);
      map.fitBounds(layers.line.getBounds(), { padding: [36, 36], maxZoom: 7 });
    } else if (origin) {
      map.setView([origin.lat, origin.lng], 6);
    }
  }, [origin, dest, geometry]);

  const status = locating
    ? 'Locating city…'
    : measuring
      ? 'Measuring driving miles…'
      : pickMode === 'origin'
        ? 'Click the map to drop pickup (A), or search a city.'
        : 'Click the map to drop destination (B), or search a city.';

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <CitySearch
          label="Pickup city"
          hint="A"
          placeholder="Dallas, TX"
          place={origin}
          active={pickMode === 'origin'}
          onActivate={() => setPickMode('origin')}
          onSelect={(place) => {
            onOriginChange(place);
            setPickMode('dest');
          }}
        />
        <CitySearch
          label="Destination city"
          hint="B"
          placeholder="Atlanta, GA"
          place={dest}
          active={pickMode === 'dest'}
          onActivate={() => setPickMode('dest')}
          onSelect={onDestChange}
        />
      </div>

      <div className="lane-map-wrap">
        <div ref={mapElRef} className="lane-map" role="application" aria-label="Lane map" />
        <p className="lane-map-status">{status}</p>
      </div>

      {mapError && (
        <p className="font-mono text-xs text-[#8C2F1B]">{mapError}</p>
      )}
    </div>
  );
};
