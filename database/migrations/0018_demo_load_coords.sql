-- Backfill demo board pins so Find Loads can draw pickup / drop without
-- waiting for a shipper to re-post. Posted loads already store lat/lng
-- from the Post Load map; this only fills the original seed rows.

UPDATE loads SET origin_lat = 32.7767, origin_lng = -96.7970, dest_lat = 33.7490, dest_lng = -84.3880
  WHERE id = 'LD-1042' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 41.8781, origin_lng = -87.6298, dest_lat = 35.1495, dest_lng = -90.0490
  WHERE id = 'LD-1043' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 34.0522, origin_lng = -118.2437, dest_lat = 33.4484, dest_lng = -112.0740
  WHERE id = 'LD-1044' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 27.5306, origin_lng = -99.4803, dest_lat = 41.8781, dest_lng = -87.6298
  WHERE id = 'LD-1045' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 35.2271, origin_lng = -80.8431, dest_lat = 25.7617, dest_lng = -80.1918
  WHERE id = 'LD-1046' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 39.9612, origin_lng = -82.9988, dest_lat = 40.7357, dest_lng = -74.1724
  WHERE id = 'LD-1047' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 47.6062, origin_lng = -122.3321, dest_lat = 39.7392, dest_lng = -104.9903
  WHERE id = 'LD-1048' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 29.7604, origin_lng = -95.3698, dest_lat = 36.1627, dest_lng = -86.7816
  WHERE id = 'LD-1049' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 39.7684, origin_lng = -86.1581, dest_lat = 39.0997, dest_lng = -94.5786
  WHERE id = 'LD-1050' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 32.0809, origin_lng = -81.0912, dest_lat = 35.2271, dest_lng = -80.8431
  WHERE id = 'LD-1051' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 34.0633, origin_lng = -117.6509, dest_lat = 40.7608, dest_lng = -111.8910
  WHERE id = 'LD-1052' AND origin_lat IS NULL;
UPDATE loads SET origin_lat = 40.2732, origin_lng = -76.8867, dest_lat = 42.3601, dest_lng = -71.0589
  WHERE id = 'LD-1053' AND origin_lat IS NULL;
