/* =============================================================
   cameras.js — Data normalization, corridor filtering, sorting
   ============================================================= */

const Cameras = (() => {
  const EARTH_RADIUS_KM = 6371;

  function toRad(deg) {
    return deg * Math.PI / 180;
  }

  // Haversine distance between two points in km
  function haversine(lat1, lon1, lat2, lon2) {
    const dLat = toRad(lat2 - lat1);
    const dLon = toRad(lon2 - lon1);
    const a = Math.sin(dLat / 2) ** 2 +
              Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
              Math.sin(dLon / 2) ** 2;
    return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  // Minimum distance from a point to a line segment (A-B) in km
  function pointToSegmentDistance(pLat, pLon, aLat, aLon, bLat, bLon) {
    const dAB = haversine(aLat, aLon, bLat, bLon);
    if (dAB < 0.001) return haversine(pLat, pLon, aLat, aLon);

    // Project point onto segment using dot product approximation
    const dx = bLon - aLon;
    const dy = bLat - aLat;
    const t = Math.max(0, Math.min(1,
      ((pLon - aLon) * dx + (pLat - aLat) * dy) / (dx * dx + dy * dy)
    ));
    const projLat = aLat + t * dy;
    const projLon = aLon + t * dx;
    return haversine(pLat, pLon, projLat, projLon);
  }

  // Minimum distance from a point to a polyline in km
  // For dense polylines (OSRM geometry), uses bounding-box pre-filter to skip
  // segments that are clearly too far away, avoiding expensive haversine calls.
  function pointToPolylineDistance(lat, lon, waypoints, bufferKm) {
    let minDist = Infinity;
    // Convert buffer to approximate degree threshold for bbox pre-filter
    // 1 degree latitude ≈ 111km, 1 degree longitude ≈ 111km * cos(lat)
    const bufferDeg = bufferKm ? (bufferKm / 111) * 1.5 : 0; // 1.5x safety margin
    const useBbox = bufferDeg > 0 && waypoints.length > 50;

    for (let i = 0; i < waypoints.length - 1; i++) {
      const aLat = waypoints[i].lat, aLon = waypoints[i].lon;
      const bLat = waypoints[i + 1].lat, bLon = waypoints[i + 1].lon;

      // Bounding-box pre-filter: skip segments clearly outside buffer range
      if (useBbox) {
        const minLat = Math.min(aLat, bLat) - bufferDeg;
        const maxLat = Math.max(aLat, bLat) + bufferDeg;
        const minLon = Math.min(aLon, bLon) - bufferDeg;
        const maxLon = Math.max(aLon, bLon) + bufferDeg;
        if (lat < minLat || lat > maxLat || lon < minLon || lon > maxLon) continue;
      }

      const d = pointToSegmentDistance(lat, lon, aLat, aLon, bLat, bLon);
      if (d < minDist) {
        minDist = d;
        // Early exit if we're essentially on the road
        if (minDist < 0.1) return minDist;
      }
    }
    return minDist;
  }

  // Find the closest waypoint index for a camera (for sorting by route order)
  function routePosition(lat, lon, waypoints) {
    let minDist = Infinity;
    let bestIdx = 0;
    let bestT = 0;

    for (let i = 0; i < waypoints.length - 1; i++) {
      const aLat = waypoints[i].lat, aLon = waypoints[i].lon;
      const bLat = waypoints[i + 1].lat, bLon = waypoints[i + 1].lon;
      const dx = bLon - aLon;
      const dy = bLat - aLat;
      const len2 = dx * dx + dy * dy;
      const t = len2 < 0.000001 ? 0 : Math.max(0, Math.min(1,
        ((lon - aLon) * dx + (lat - aLat) * dy) / len2
      ));
      const projLat = aLat + t * dy;
      const projLon = aLon + t * dx;
      const d = haversine(lat, lon, projLat, projLon);
      if (d < minDist) {
        minDist = d;
        bestIdx = i;
        bestT = t;
      }
    }
    return bestIdx + bestT;
  }

  // Normalize Alberta 511 camera data
  function normalizeAlberta(data) {
    if (!Array.isArray(data)) return [];
    const cameras = [];
    for (const cam of data) {
      if (!cam.Latitude || !cam.Longitude) continue;
      const views = cam.Views || [];
      for (const view of views) {
        cameras.push({
          id: `ab-${cam.Id}-${view.Id || 0}`,
          name: cam.Location || 'Unknown',
          highway: cam.Roadway || '',
          region: 'AB',
          lat: cam.Latitude,
          lon: cam.Longitude,
          imageUrl: view.Url || '',
          status: (view.Status || '').toLowerCase() === 'disabled' ? 'inactive' : 'active',
          direction: cam.Direction || view.Description || '',
          lastUpdated: view.LastUpdated || null,
        });
      }
      if (views.length === 0) {
        cameras.push({
          id: `ab-${cam.Id}`,
          name: cam.Location || 'Unknown',
          highway: cam.Roadway || '',
          region: 'AB',
          lat: cam.Latitude,
          lon: cam.Longitude,
          imageUrl: '',
          status: 'inactive',
          direction: cam.Direction || '',
          lastUpdated: null,
        });
      }
    }
    return cameras;
  }

  // Normalize DriveBC camera data
  // API returns GeoJSON coordinates [lon, lat], image paths are relative to https://www.drivebc.ca
  const DRIVEBC_BASE = 'https://www.drivebc.ca';

  function normalizeBC(data) {
    if (!Array.isArray(data) && data?.webcams) {
      data = data.webcams;
    }
    if (!Array.isArray(data)) return [];
    return data.filter(cam => {
        // GeoJSON: coordinates = [longitude, latitude]
        const coords = cam.location?.coordinates;
        return coords && coords.length >= 2;
      })
      .filter(cam => cam.should_appear !== false)
      .map(cam => {
        const coords = cam.location.coordinates;
        const imgPath = cam.links?.imageDisplay || '';
        const imageUrl = imgPath.startsWith('http') ? imgPath : (imgPath ? DRIVEBC_BASE + imgPath : '');
        return {
          id: `bc-${cam.id}`,
          name: cam.name || cam.caption || 'Unknown',
          highway: cam.highway_display || cam.highway || '',
          region: 'BC',
          lat: coords[1],
          lon: coords[0],
          imageUrl: imageUrl.split('?')[0], // strip cache-bust param, we add our own
          thumbnailUrl: imageUrl.split('?')[0],
          status: cam.is_on ? 'active' : 'inactive',
          direction: cam.orientation || '',
          lastUpdated: cam.last_update_modified || null,
        };
      });
  }

  // Normalize WSDOT camera data
  function normalizeWA(data) {
    if (!Array.isArray(data)) return [];
    return data.filter(cam => cam.CameraLocation?.Latitude && cam.CameraLocation?.Longitude)
      .map(cam => ({
        id: `wa-${cam.CameraID}`,
        name: cam.Title || cam.CameraLocation?.Description || 'Unknown',
        highway: cam.CameraLocation?.RoadName || '',
        region: 'WA',
        lat: cam.CameraLocation.Latitude,
        lon: cam.CameraLocation.Longitude,
        imageUrl: cam.ImageURL || '',
        status: cam.IsActive ? 'active' : 'inactive',
        direction: cam.CameraLocation?.Direction || '',
        lastUpdated: null,
      }));
  }

  // Alberta highway keywords — filter out urban intersection cameras
  const AB_HIGHWAY_KEYWORDS = [
    'highway', 'hwy', 'qe2', 'qeii', 'trans-canada', 'trans canada',
    'yellowhead', 'icefields', 'crowsnest',
  ];

  function isHighwayCamera(cam) {
    // BC and WA cameras are already highway cameras
    if (cam.region !== 'AB') return true;
    const text = (cam.name + ' ' + cam.highway).toLowerCase();
    // Include if it matches known highway keywords
    if (AB_HIGHWAY_KEYWORDS.some(kw => text.includes(kw))) return true;
    // Include if highway field explicitly says "Hwy N" or "Highway N"
    if (/\bhwy\s*\d|highway\s*\d/i.test(cam.highway)) return true;
    // Exclude everything else — urban cameras, ring roads, etc.
    return false;
  }

  // Cache corridor distance results to avoid recomputing for same camera+route
  let _corridorCache = { waypointKey: '', distances: new Map() };

  function getCorridorCacheKey(waypoints) {
    // For dense geometry (OSRM), sample a subset of points for the cache key
    // to avoid serializing thousands of coordinates
    if (waypoints.length > 50) {
      const step = Math.floor(waypoints.length / 20);
      const samples = [];
      for (let i = 0; i < waypoints.length; i += step) {
        samples.push(`${waypoints[i].lat.toFixed(3)},${waypoints[i].lon.toFixed(3)}`);
      }
      // Always include the last point
      const last = waypoints[waypoints.length - 1];
      samples.push(`${last.lat.toFixed(3)},${last.lon.toFixed(3)}`);
      return `dense:${waypoints.length}:${samples.join('|')}`;
    }
    return waypoints.map(w => `${w.lat.toFixed(3)},${w.lon.toFixed(3)}`).join('|');
  }

  // Filter cameras to those within the route corridor
  function filterByCorridor(cameras, waypoints, bufferKm) {
    const wpKey = getCorridorCacheKey(waypoints);
    if (_corridorCache.waypointKey !== wpKey) {
      _corridorCache = { waypointKey: wpKey, distances: new Map() };
    }
    const distCache = _corridorCache.distances;

    return cameras.filter(cam => {
      if (!isHighwayCamera(cam)) return false;
      let dist = distCache.get(cam.id);
      if (dist === undefined) {
        dist = pointToPolylineDistance(cam.lat, cam.lon, waypoints, bufferKm);
        distCache.set(cam.id, dist);
      }
      return dist <= bufferKm;
    });
  }

  // Sort cameras by their position along the route
  function sortByRoute(cameras, waypoints) {
    return cameras.slice().sort((a, b) => {
      const posA = routePosition(a.lat, a.lon, waypoints);
      const posB = routePosition(b.lat, b.lon, waypoints);
      return posA - posB;
    });
  }

  // Get subset of waypoints between two named stops
  function getWaypointsBetween(allStops, fromId, toId) {
    const fromIdx = allStops.findIndex(s => s.id === fromId);
    const toIdx = allStops.findIndex(s => s.id === toId);
    if (fromIdx === -1 || toIdx === -1) return allStops;

    const start = Math.min(fromIdx, toIdx);
    const end = Math.max(fromIdx, toIdx);
    return allStops.slice(start, end + 1);
  }

  // Get all unique city stops from route data
  function getAllStops(routeData) {
    const seen = new Set();
    const stops = [];
    for (const route of Object.values(routeData.routes)) {
      for (const stop of route.stops) {
        if (!seen.has(stop.id)) {
          seen.add(stop.id);
          stops.push(stop);
        }
      }
    }
    return stops;
  }

  // Find the best route between two stops
  // When both stops exist in multiple routes, pick the one with fewest intermediate stops
  function findRoute(routeData, fromId, toId) {
    let bestSegment = null;
    for (const route of Object.values(routeData.routes)) {
      const fromIdx = route.stops.findIndex(s => s.id === fromId);
      const toIdx = route.stops.findIndex(s => s.id === toId);
      if (fromIdx !== -1 && toIdx !== -1) {
        const start = Math.min(fromIdx, toIdx);
        const end = Math.max(fromIdx, toIdx);
        const segment = route.stops.slice(start, end + 1);
        if (!bestSegment || segment.length < bestSegment.length) {
          bestSegment = segment;
        }
      }
    }
    if (bestSegment) {
      return bestSegment;
    }
    // Fallback: use northern route
    const northern = routeData.routes.northern.stops;
    return getWaypointsBetween(northern, fromId, toId);
  }

  // Find nearest stop to a lat/lon
  function nearestStop(lat, lon, stops) {
    let minDist = Infinity;
    let nearest = stops[0];
    for (const stop of stops) {
      const d = haversine(lat, lon, stop.lat, stop.lon);
      if (d < minDist) {
        minDist = d;
        nearest = stop;
      }
    }
    return nearest;
  }

  // ── Clustering ────────────────────────────────────────────────

  // Group route-sorted cameras within `thresholdKm` of each other.
  // Because cameras are already sorted by route position, nearby cameras
  // in the same physical location will be adjacent in the array.
  function clusterCameras(cameras, thresholdKm = 0.1) {
    if (cameras.length === 0) return [];
    const clusters = [];
    let current = { cameras: [cameras[0]], lat: cameras[0].lat, lon: cameras[0].lon };

    for (let i = 1; i < cameras.length; i++) {
      const cam = cameras[i];
      const dist = haversine(current.lat, current.lon, cam.lat, cam.lon);
      if (dist <= thresholdKm) {
        current.cameras.push(cam);
      } else {
        clusters.push(current);
        current = { cameras: [cam], lat: cam.lat, lon: cam.lon };
      }
    }
    clusters.push(current);
    return clusters;
  }

  // ── Direction Parsing ─────────────────────────────────────────

  // Map cardinal/intercardinal direction strings to bearings (degrees from north)
  const DIRECTION_BEARINGS = {
    'n': 0, 'north': 0, 'northbound': 0,
    'ne': 45, 'northeast': 45, 'northeastbound': 45,
    'e': 90, 'east': 90, 'eastbound': 90,
    'se': 135, 'southeast': 135, 'southeastbound': 135,
    's': 180, 'south': 180, 'southbound': 180,
    'sw': 225, 'southwest': 225, 'southwestbound': 225,
    'w': 270, 'west': 270, 'westbound': 270,
    'nw': 315, 'northwest': 315, 'northwestbound': 315,
  };

  function directionToBearing(dirStr) {
    if (!dirStr) return null;
    const key = dirStr.trim().toLowerCase();
    return DIRECTION_BEARINGS[key] ?? null;
  }

  // Bearing from point A to point B (degrees 0-360, 0 = north)
  function bearingBetween(lat1, lon1, lat2, lon2) {
    const dLon = toRad(lon2 - lon1);
    const y = Math.sin(dLon) * Math.cos(toRad(lat2));
    const x = Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) -
              Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(dLon);
    const brng = Math.atan2(y, x) * 180 / Math.PI;
    return (brng + 360) % 360;
  }

  // Smallest angular difference between two bearings (0-180)
  function angleDiff(a, b) {
    const diff = Math.abs(a - b) % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  // Compute the route's travel bearing at a given position along the waypoints.
  // Uses the two waypoints bracketing the cluster to determine forward direction.
  function travelBearingAt(lat, lon, waypoints) {
    if (waypoints.length < 2) return 0;
    const pos = routePosition(lat, lon, waypoints);
    const idx = Math.floor(pos);
    const safeIdx = Math.min(idx, waypoints.length - 2);
    const a = waypoints[safeIdx];
    const b = waypoints[safeIdx + 1];
    return bearingBetween(a.lat, a.lon, b.lat, b.lon);
  }

  // Sort cameras within a cluster so the one facing the travel direction comes first.
  // Cameras with unknown direction are pushed to the end.
  // When `reversed` is true, the user is traveling opposite to waypoint order.
  function sortClusterByTravelDirection(cluster, waypoints, reversed) {
    if (cluster.cameras.length <= 1) return;
    let bearing = travelBearingAt(cluster.lat, cluster.lon, waypoints);
    if (reversed) bearing = (bearing + 180) % 360;
    cluster.cameras.sort((a, b) => {
      const aBearing = directionToBearing(a.direction);
      const bBearing = directionToBearing(b.direction);
      // Unknown directions go last
      if (aBearing === null && bBearing === null) return 0;
      if (aBearing === null) return 1;
      if (bBearing === null) return -1;
      // Sort by closest to travel bearing
      return angleDiff(aBearing, bearing) - angleDiff(bBearing, bearing);
    });
  }

  return {
    normalizeAlberta,
    normalizeBC,
    normalizeWA,
    filterByCorridor,
    sortByRoute,
    clusterCameras,
    sortClusterByTravelDirection,
    findRoute,
    getAllStops,
    nearestStop,
    haversine,
  };
})();
