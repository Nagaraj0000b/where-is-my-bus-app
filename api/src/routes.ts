// Static route data: the route's name, its ordered stops, and the shape
// the bus actually follows. All of this comes from the static GTFS and the
// pre-computed stop offsets, so it works with no live feed.
//
// The new screens need this in one place. The old /routes/:id/stops
// endpoint had its own copy of the stop query; it now uses routeStops()
// below so there is only one definition of "the stops on this route".

import { pool } from './db.ts';

export interface RouteMeta {
  routeId: string;
  /** The GTFS name, e.g. "764DOWN". Kept for debugging and links. */
  routeShortName: string;
  /** The number a rider recognises, e.g. "764" (UP/DOWN stripped). */
  routeNumber: string;
  routeDesc: string;
  routeLongName: string;
  directionTag: string | null;
  /** The end of route_desc after "to", e.g. "Jharoda Kalan". */
  destination: string;
}

export interface RouteStop {
  stopSequence: number;
  stopId: string;
  stopName: string;
  lat: number | null;
  lon: number | null;
  metresAlongRoute: number;
  /** False when the hop into this stop was never observed. */
  hasTiming: boolean;
}

export interface RouteShapePoint {
  lat: number;
  lon: number;
  /** Distance along the shape in metres, from GTFS shape_dist_traveled. */
  distM: number;
}

export interface RouteShape {
  routeId: string;
  shapeId: string;
  lengthM: number;
  points: RouteShapePoint[];
}

/**
 * "764DOWN" -> "764". The direction is already in the destination, and
 * the board should read like the number painted on the bus.
 */
export function displayRouteNumber(shortName: string): string {
  return shortName.replace(/(UP|DOWN)$/i, '');
}

/**
 * "Nehru Place Terminal to Jharoda Kalan" -> "Jharoda Kalan".
 * Delhi's route_desc is direction-specific, so the second half is the
 * destination a rider is looking for.
 */
export function destinationOf(routeDesc: string): string {
  const parts = routeDesc.split(/\s+to\s+/i);
  if (parts.length > 1) return parts[parts.length - 1].trim();
  return routeDesc.trim();
}

/** One route's row from the latest static snapshot. Null if it is not there. */
export async function routeMeta(routeId: string): Promise<RouteMeta | null> {
  const { rows } = await pool.query<{
    route_id: string;
    route_short_name: string;
    route_long_name: string;
    route_desc: string;
    direction_tag: string | null;
  }>(
    `
    SELECT route_id, route_short_name, route_long_name, route_desc, direction_tag
    FROM routes
    WHERE route_id = $1
      AND snapshot_id = (SELECT max(snapshot_id) FROM routes)
    LIMIT 1
    `,
    [routeId],
  );

  const row = rows[0];
  if (!row) return null;

  return {
    routeId: row.route_id,
    routeShortName: row.route_short_name,
    routeNumber: displayRouteNumber(row.route_short_name),
    routeDesc: row.route_desc ?? '',
    routeLongName: row.route_long_name ?? '',
    directionTag: row.direction_tag,
    destination: destinationOf(row.route_desc ?? row.route_short_name),
  };
}

/**
 * The ordered stops on a route, with the distance along the shape and
 * whether the hop into each stop has ever been observed.
 *
 * The query is the same one the API has always used; it is here so the
 * route-detail endpoint and the old stops endpoint cannot drift apart.
 */
export async function routeStops(routeId: string): Promise<RouteStop[]> {
  const { rows } = await pool.query<{
    stop_sequence: number;
    stop_id: string;
    stop_name: string;
    lat: number;
    lon: number;
    metres_along_route: number;
    has_timing: boolean;
  }>(
    `
    SELECT DISTINCT ON (st.stop_sequence)
           st.stop_sequence,
           st.stop_id,
           s.stop_name,
           s.stop_lat AS lat,
           s.stop_lon AS lon,
           round(st.dist_along_shape_m::numeric, 0)::int AS metres_along_route,
           EXISTS (
             SELECT 1 FROM route_segment_travel_time rs
             WHERE rs.route_id = $1
               AND rs.day_type = 'any'
               AND rs.to_stop_sequence = st.stop_sequence
           ) AS has_timing
    FROM stop_times st
    JOIN trips t ON t.snapshot_id = st.snapshot_id AND t.trip_id = st.trip_id
    JOIN stops s ON s.snapshot_id = st.snapshot_id AND s.stop_id = st.stop_id
    WHERE t.route_id = $1
      AND st.snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
    ORDER BY st.stop_sequence, st.stop_id
    `,
    [routeId],
  );

  return rows.map((row) => ({
    stopSequence: row.stop_sequence,
    stopId: row.stop_id,
    stopName: row.stop_name,
    lat: row.lat,
    lon: row.lon,
    metresAlongRoute: row.metres_along_route,
    hasTiming: row.has_timing,
  }));
}

// Shapes never change between requests, so one fetch per route is enough.
const shapeCache = new Map<string, RouteShape | null>();

const MAX_SHAPE_POINTS = 300;

/** Keep every nth point plus the last, so the line stays readable and small. */
function downsample(points: RouteShapePoint[]): RouteShapePoint[] {
  if (points.length <= MAX_SHAPE_POINTS) return points;

  const step = Math.ceil(points.length / MAX_SHAPE_POINTS);
  const kept: RouteShapePoint[] = [];
  for (let i = 0; i < points.length; i += step) kept.push(points[i]);

  const last = points[points.length - 1];
  if (kept[kept.length - 1] !== last) kept.push(last);
  return kept;
}

/**
 * The route's line, as points with their distance along it.
 *
 * The distance is what lets the app place a bus exactly between two stops
 * without another request: progress metres -> point on this list.
 */
export async function routeShape(routeId: string): Promise<RouteShape | null> {
  if (shapeCache.has(routeId)) return shapeCache.get(routeId) ?? null;

  const lookup = await pool.query<{
    shape_id: string;
    snapshot_id: number;
    route_length_m: number;
  }>(
    `
    SELECT shape_id, snapshot_id, route_length_m
    FROM route_shape_lookup
    WHERE route_id = $1
    LIMIT 1
    `,
    [routeId],
  );

  const row = lookup.rows[0];
  if (!row) {
    shapeCache.set(routeId, null);
    return null;
  }

  const { rows } = await pool.query<{
    shape_pt_lat: number;
    shape_pt_lon: number;
    shape_dist_traveled: number | null;
  }>(
    `
    SELECT shape_pt_lat, shape_pt_lon, shape_dist_traveled
    FROM shape_points
    WHERE snapshot_id = $1 AND shape_id = $2
    ORDER BY shape_pt_sequence
    `,
    [row.snapshot_id, row.shape_id],
  );

  // Older snapshots sometimes omit shape_dist_traveled. Fall back to a
  // cumulative straight-line distance so the field is never null; it is
  // only used for placing a marker, not for the ETA.
  let running = 0;
  let previous: { lat: number; lon: number } | null = null;
  const points: RouteShapePoint[] = rows.map((point) => {
    if (point.shape_dist_traveled !== null) {
      running = point.shape_dist_traveled;
    } else if (previous) {
      running += haversineMeters(previous.lat, previous.lon, point.shape_pt_lat, point.shape_pt_lon);
    }
    previous = { lat: point.shape_pt_lat, lon: point.shape_pt_lon };
    return {
      lat: point.shape_pt_lat,
      lon: point.shape_pt_lon,
      distM: running,
    };
  });

  const shape: RouteShape = {
    routeId,
    shapeId: row.shape_id,
    lengthM: row.route_length_m,
    points: downsample(points),
  };
  shapeCache.set(routeId, shape);
  return shape;
}

/** Great-circle distance, used only for the missing-distance fallback above. */
function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
