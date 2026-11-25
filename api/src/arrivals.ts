// Buses coming to a stop, and buses on a route.
//
// This is the read layer the new screens are built on. It answers one
// question in two ways:
//
//   - at a recorded time (replay), from the matched stop passages that
//     already power the ETA model;
//   - now, from the latest non-empty realtime frame and its matched
//     progress, with passenger beacons merged in.
//
// The ETA itself is still eta.ts. This file only decides which buses are
// candidates and then calls the same hop statistics for each of them,
// batched so a board of twenty buses does not mean twenty round trips.

import { pool } from './db.ts';
import {
  delhiTimeParts,
  rangeForHops,
  resolveHop,
  type HopRow,
  type HopSource,
} from './eta.ts';
import { describeConfidence, type Confidence } from './confidence.ts';
import { feedStatus, LIVE_TTL_SECONDS, LAST_SEEN_TTL_SECONDS, type FeedStatus } from './feed.ts';
import {
  routeMeta,
  routeShape,
  routeStops,
  type RouteMeta,
  type RouteShape,
  type RouteStop,
} from './routes.ts';
import { crowdsourceStore } from './crowdsource.ts';
import { buildLocationProof, summarizeProof } from './location_proof.ts';
import type { ProofSummary } from './location_proof.ts';

export type ArrivalSource = 'official' | 'passenger' | 'replay';
export type ArrivalsMode = 'live' | 'replay';

export interface ArrivalMatch {
  accepted: boolean;
  offsetM: number | null;
  rawLat: number | null;
  rawLon: number | null;
  snappedLat: number | null;
  snappedLon: number | null;
}

export interface Arrival {
  routeId: string;
  routeShortName: string;
  routeNumber: string;
  destination: string;
  vehicleId: string;
  source: ArrivalSource;
  /** Official position is older than LIVE_TTL_SECONDS. UI shows LAST SEEN. */
  stale: boolean;
  currentStopSequence: number;
  targetStopSequence: number | null;
  stopsAway: number | null;
  progressM: number;
  progressFraction: number;
  routeLengthM: number;
  recordedAt: string;
  lastSeen: string;
  eta: { seconds: number; text: string; at: string } | null;
  range: {
    lowSeconds: number;
    highSeconds: number;
    text: string;
    lowAt: string;
    highAt: string;
    couldBeArrivingNow: boolean;
  } | null;
  confidence: Confidence | null;
  match: ArrivalMatch | null;
  crowd: { passengers: number; confidence: 'high' | 'medium' } | null;
  /**
   * One-line result of the simulated GPS verification for this position.
   *
   * Null on passenger rows (a phone is not the bus's GPS unit) and on replay
   * rows where the archive has no raw recorded fix to verify. The full proof
   * (checklist, satellites) comes from GET /location-proof.
   */
  proof: ProofSummary | null;
  unavailable?: { reason: string; missingHops: number };
}

export interface FrequencyRow {
  routeId: string;
  routeShortName: string;
  routeNumber: string;
  destination: string;
  headwayMinutes: number;
  daysSeen: number;
  samplePassages: number;
}

export interface PlaceInfo {
  placeId: number;
  name: string;
  lat: number;
  lon: number;
}

export interface ArrivalsResult {
  place: PlaceInfo;
  mode: ArrivalsMode;
  at: string;
  feed: FeedStatus;
  /**
   * The place the rider asked to reach, when the request carried `to`.
   *
   * Null means "no destination filter": the board lists every bus arriving
   * at this stop, whichever direction it carries on in.
   */
  destination: PlaceInfo | null;
  /**
   * True only when a destination was asked for and no single route from
   * this stop reaches it. The board is then honestly empty of buses; the
   * app points the rider at the Plan tab instead of inventing rows.
   */
  noDirect: boolean;
  arrivals: Arrival[];
  frequency: FrequencyRow[];
  caveats: string[];
}

export interface RouteDetailResult {
  route: RouteMeta;
  shape: RouteShape | null;
  stops: RouteStop[];
  runs: Arrival[];
  frequency: FrequencyRow | null;
  targetStopSequence: number | null;
  mode: ArrivalsMode;
  at: string;
  feed: FeedStatus;
  firstDeparture: string | null;
  lastDeparture: string | null;
  caveats: string[];
}

interface PlaceRoute {
  routeId: string;
  stopSequence: number;
  routeShortName: string;
  routeDesc: string;
  destination: string;
  routeNumber: string;
}

interface Candidate {
  routeId: string;
  routeNumber: string;
  routeShortName: string;
  destination: string;
  vehicleId: string;
  source: ArrivalSource;
  stale: boolean;
  currentStopSequence: number;
  targetStopSequence: number;
  progressM: number;
  routeLengthM: number;
  recordedAt: Date;
  lastSeen: Date;
  match: ArrivalMatch | null;
  crowd: { passengers: number; confidence: 'high' | 'medium' } | null;
}

// ---------------------------------------------------------------------------
// Small text helpers
// ---------------------------------------------------------------------------

function minutesText(seconds: number): string {
  if (seconds <= 0) return 'at this stop';
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return 'under a minute';
  return `${minutes} min`;
}

function rangeText(lowSeconds: number, highSeconds: number): string {
  if (highSeconds <= 0) return 'at this stop';
  if (lowSeconds < 60) return `now to ${minutesText(highSeconds)}`;
  return `${minutesText(lowSeconds)} to ${minutesText(highSeconds)}`;
}

function round(value: number): number {
  return Math.round(value);
}

// ---------------------------------------------------------------------------
// Static lookups
// ---------------------------------------------------------------------------

/** The physical place, one row even when Delhi lists several stop_ids there. */
export async function placeInfo(placeId: number): Promise<PlaceInfo | null> {
  const { rows } = await pool.query<{
    place_id: number;
    stop_name: string;
    lat: number;
    lon: number;
  }>(
    `
    SELECT DISTINCT ON (sp.place_id)
           sp.place_id, s.stop_name, s.stop_lat AS lat, s.stop_lon AS lon
    FROM stop_place sp
    JOIN stops s ON s.stop_id = sp.stop_id
    WHERE sp.place_id = $1
      AND s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
    ORDER BY sp.place_id, s.stop_id
    LIMIT 1
    `,
    [placeId],
  );

  const row = rows[0];
  if (!row) return null;
  return {
    placeId: row.place_id,
    name: row.stop_name,
    lat: row.lat,
    lon: row.lon,
  };
}

/**
 * The nearest physical place to a coordinate, within a radius.
 *
 * GET /relay-selection accepts either a place id or a bare lat/lon. The paper's
 * relay selection is done for a POINT OF INTEREST, so a caller who only knows
 * coordinates still needs the same physical stop the stop search would find -
 * this resolves it with the same DISTINCT ON / spatial pattern as
 * GET /stops/near, so a place resolves identically however it was asked for.
 *
 * Returns null when there is no stop within `radiusM`; the endpoint turns that
 * into a 404 rather than inventing a point of interest in the middle of a road.
 */
export async function nearestPlace(
  lat: number,
  lon: number,
  radiusM: number,
): Promise<PlaceInfo | null> {
  const { rows } = await pool.query<{
    place_id: number;
    stop_name: string;
    lat: number;
    lon: number;
  }>(
    `
    SELECT place_id, stop_name, lat, lon FROM (
      SELECT DISTINCT ON (sp.place_id)
             sp.place_id, s.stop_name, s.stop_lat AS lat, s.stop_lon AS lon,
             round(ST_Distance(s.geom::geography,
                   ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography)::numeric, 0)::int AS metres_away
      FROM stops s
      JOIN stop_place sp ON sp.stop_id = s.stop_id
      WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
        AND ST_DWithin(s.geom::geography,
                       ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography, $3)
      -- nearest stop_id within each place wins, exactly as in /stops/near
      ORDER BY sp.place_id, metres_away
    ) nearest
    ORDER BY metres_away
    LIMIT 1
    `,
    [lat, lon, radiusM],
  );

  const row = rows[0];
  if (!row) return null;
  return {
    placeId: row.place_id,
    name: row.stop_name,
    lat: row.lat,
    lon: row.lon,
  };
}

/** Every route that calls at a place, and the first stop sequence there. */
export async function routesAtPlace(placeId: number): Promise<PlaceRoute[]> {
  const { rows } = await pool.query<{
    route_id: string;
    stop_sequence: number;
    route_short_name: string;
    route_desc: string;
  }>(
    `
    SELECT DISTINCT ON (rp.route_id)
           rp.route_id, rp.stop_sequence, r.route_short_name, r.route_desc
    FROM route_place rp
    JOIN routes r
      ON r.route_id = rp.route_id
     AND r.snapshot_id = (SELECT max(snapshot_id) FROM routes)
    WHERE rp.place_id = $1
    ORDER BY rp.route_id, rp.stop_sequence
    `,
    [placeId],
  );

  return rows.map((row) => ({
    routeId: row.route_id,
    stopSequence: row.stop_sequence,
    routeShortName: row.route_short_name,
    routeDesc: row.route_desc ?? '',
    destination: destinationFromDesc(row.route_desc ?? row.route_short_name),
    routeNumber: row.route_short_name.replace(/(UP|DOWN)$/i, ''),
  }));
}

function destinationFromDesc(routeDesc: string): string {
  const parts = routeDesc.split(/\s+to\s+/i);
  return (parts.length > 1 ? parts[parts.length - 1] : routeDesc).trim();
}

/**
 * Which of the routes at a stop reach a destination place, and where.
 *
 * "Direct" here means one route with no change: the destination place must
 * appear LATER in the route's own stop order than the place the rider is
 * boarding at. A route that only serves the destination before the boarding
 * stop is running the other way and is not a direct bus for this trip, so it
 * is simply left out of the returned map.
 *
 * The value is the smallest destination stop_sequence that is strictly after
 * the boarding sequence - i.e. the first time this route reaches the
 * destination after picking the rider up.
 */
async function destinationSequences(
  routes: PlaceRoute[],
  destinationPlaceId: number,
): Promise<Map<string, number>> {
  const result = new Map<string, number>();
  if (routes.length === 0) return result;

  const boardingSequence = new Map(routes.map((route) => [route.routeId, route.stopSequence]));
  const routeIds = routes.map((route) => route.routeId);

  const { rows } = await pool.query<{ route_id: string; stop_sequence: number }>(
    `
    SELECT route_id, stop_sequence
    FROM route_place
    WHERE place_id = $1
      AND route_id = ANY($2::text[])
    ORDER BY route_id, stop_sequence
    `,
    [destinationPlaceId, routeIds],
  );

  for (const row of rows) {
    const boardSequence = boardingSequence.get(row.route_id);
    if (boardSequence === undefined) continue;
    if (row.stop_sequence <= boardSequence) continue;
    // Rows come back in stop order, so the first one after the boarding stop
    // is the first time the route reaches the destination.
    if (!result.has(row.route_id)) result.set(row.route_id, row.stop_sequence);
  }

  return result;
}

/** Route lengths for a set of routes, in one query. */
async function routeLengths(routeIds: string[]): Promise<Map<string, number>> {
  if (routeIds.length === 0) return new Map();
  const { rows } = await pool.query<{ route_id: string; route_length_m: number }>(
    `
    SELECT route_id, route_length_m
    FROM route_shape_lookup
    WHERE route_id = ANY($1::text[])
    `,
    [routeIds],
  );
  return new Map(rows.map((row) => [row.route_id, row.route_length_m]));
}

/**
 * Stop distances along each route. Needed only for live/crowd positions,
 * where the map matcher gives us metres and we have to turn that into a
 * stop sequence. Replay already has the sequence from the passage.
 */
async function stopDistances(routeIds: string[]): Promise<Map<string, { seq: number; dist: number }[]>> {
  if (routeIds.length === 0) return new Map();
  const { rows } = await pool.query<{
    route_id: string;
    stop_sequence: number;
    dist_along_shape_m: number;
  }>(
    `
    SELECT DISTINCT ON (t.route_id, st.stop_sequence)
           t.route_id, st.stop_sequence, st.dist_along_shape_m
    FROM stop_times st
    JOIN trips t ON t.snapshot_id = st.snapshot_id AND t.trip_id = st.trip_id
    WHERE t.route_id = ANY($1::text[])
      AND st.snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
    ORDER BY t.route_id, st.stop_sequence
    `,
    [routeIds],
  );

  const byRoute = new Map<string, { seq: number; dist: number }[]>();
  for (const row of rows) {
    if (row.dist_along_shape_m === null) continue;
    const list = byRoute.get(row.route_id) ?? [];
    list.push({ seq: row.stop_sequence, dist: row.dist_along_shape_m });
    byRoute.set(row.route_id, list);
  }
  return byRoute;
}

/** The last stop the bus has passed, and the next one it will reach. */
function stopPosition(
  stops: { seq: number; dist: number }[],
  progressM: number,
): { current: number; next: number } | null {
  if (stops.length === 0) return null;

  let current = stops[0].seq;
  let next = stops[1]?.seq ?? stops[0].seq + 1;

  for (let i = 0; i < stops.length; i++) {
    if (stops[i].dist <= progressM) {
      current = stops[i].seq;
      next = stops[i + 1]?.seq ?? current + 1;
    } else {
      break;
    }
  }
  return { current, next };
}

// ---------------------------------------------------------------------------
// Replay positions from matched stop passages
// ---------------------------------------------------------------------------

interface PassageRow {
  route_id: string;
  vehicle_id: string;
  stop_sequence: number;
  dist_along_route_m: number;
  passage_time: Date;
}

/**
 * Put every bus on its route at a recorded moment.
 *
 * The matched passage says "this bus crossed stop 7 at 18:29:40" and
 * "stop 8 at 18:31:10". At 18:30:20 the bus is between them; we place it
 * between them in proportion to time. This is a replay of what the matcher
 * recorded, not a new position guess.
 */
async function replayCandidates(
  routes: PlaceRoute[],
  at: Date,
  routeLength: Map<string, number>,
): Promise<Candidate[]> {
  if (routes.length === 0) return [];

  const routeIds = [...new Set(routes.map((route) => route.routeId))];
  const { rows } = await pool.query<PassageRow>(
    `
    SELECT route_id, vehicle_id, stop_sequence, dist_along_route_m, passage_time
    FROM observed_stop_passage
    WHERE day = ($2::timestamptz AT TIME ZONE 'Asia/Kolkata')::date
      AND route_id = ANY($1::text[])
      AND passage_time BETWEEN $2::timestamptz - interval '20 minutes'
                           AND $2::timestamptz + interval '5 minutes'
    ORDER BY route_id, vehicle_id, passage_time
    `,
    [routeIds, at.toISOString()],
  );

  // One list per (route, vehicle), in time order. The query already sorts.
  const byVehicle = new Map<string, PassageRow[]>();
  for (const row of rows) {
    const key = `${row.route_id}|${row.vehicle_id}`;
    const list = byVehicle.get(key) ?? [];
    list.push(row);
    byVehicle.set(key, list);
  }

  const routeInfo = new Map(routes.map((route) => [route.routeId, route]));
  const candidates: Candidate[] = [];

  for (const passages of byVehicle.values()) {
    const first = passages[0];
    const route = routeInfo.get(first.route_id);
    if (!route) continue;

    // The last passage at or before the requested moment.
    let last: PassageRow | null = null;
    let next: PassageRow | null = null;
    for (const passage of passages) {
      if (passage.passage_time.getTime() <= at.getTime()) {
        last = passage;
      } else {
        next = passage;
        break;
      }
    }
    if (!last) continue;

    const ageSeconds = (at.getTime() - last.passage_time.getTime()) / 1000;
    // A vehicle that has not been seen for 15 minutes is not a useful
    // arrival; it may have finished its trip.
    if (ageSeconds > 15 * 60) continue;

    // A bus that already crossed the stop is not "coming" to it. The one
    // exception is a passage in the last three minutes: it may still be
    // standing at the stop, and showing "at this stop" is useful.
    if (last.stop_sequence > route.stopSequence) continue;
    if (last.stop_sequence === route.stopSequence && ageSeconds > 3 * 60) continue;

    let progressM = last.dist_along_route_m;
    if (next) {
      const gapSeconds = (next.passage_time.getTime() - last.passage_time.getTime()) / 1000;
      const moved = next.dist_along_route_m - last.dist_along_route_m;
      // A negative jump means the route restarted a lap. Do not
      // interpolate across that boundary; use the last known point.
      if (gapSeconds > 0 && moved >= 0 && gapSeconds <= 10 * 60) {
        const fraction = Math.min(1, Math.max(0, (at.getTime() - last.passage_time.getTime()) / 1000 / gapSeconds));
        progressM = last.dist_along_route_m + moved * fraction;
      }
    }

    const lengthM = routeLength.get(first.route_id) ?? 0;
    candidates.push({
      routeId: first.route_id,
      routeNumber: route.routeNumber,
      routeShortName: route.routeShortName,
      destination: route.destination,
      vehicleId: first.vehicle_id,
      source: 'replay',
      stale: false,
      currentStopSequence: last.stop_sequence,
      targetStopSequence: route.stopSequence,
      progressM,
      routeLengthM: lengthM,
      recordedAt: last.passage_time,
      lastSeen: last.passage_time,
      // A passage is already on the route line, so there is no raw dot to
      // show. The snapped point is derived from progress on the client.
      match: null,
      crowd: null,
    });
  }

  return candidates;
}

// ---------------------------------------------------------------------------
// Live positions from the official feed
// ---------------------------------------------------------------------------

interface LiveRow {
  route_id: string;
  vehicle_id: string;
  lat: number;
  lon: number;
  position_timestamp: Date;
  accepted: boolean | null;
  accepted_dist_along_route_m: number | null;
  raw_dist_along_route_m: number | null;
  reject_reason: string | null;
}

/**
 * The newest non-empty frame, even if the very latest frame was empty.
 *
 * An empty response is a silent tick, not an empty fleet. Using the last
 * non-empty frame and reporting its age is the honest degradation.
 */
async function newestUsableFrame(): Promise<{ frameId: number; at: Date; ageSeconds: number } | null> {
  const { rows } = await pool.query<{ frame_id: number; feed_timestamp: Date }>(
    `
    SELECT frame_id, feed_timestamp
    FROM realtime_frame
    WHERE vehicle_count > 0
      AND feed_timestamp <= now()
    ORDER BY feed_timestamp DESC
    LIMIT 1
    `,
  );

  const row = rows[0];
  if (!row) return null;

  const ageSeconds = Math.max(0, (Date.now() - row.feed_timestamp.getTime()) / 1000);
  if (ageSeconds > LAST_SEEN_TTL_SECONDS) return null;

  return { frameId: row.frame_id, at: row.feed_timestamp, ageSeconds };
}

async function liveCandidates(
  routes: PlaceRoute[],
  routeLength: Map<string, number>,
): Promise<{ candidates: Candidate[]; frameAt: Date | null }> {
  if (routes.length === 0) return { candidates: [], frameAt: null };

  const frame = await newestUsableFrame();
  if (!frame) return { candidates: [], frameAt: null };

  const routeIds = [...new Set(routes.map((route) => route.routeId))];
  const routeInfo = new Map(routes.map((route) => [route.routeId, route]));

  const [positions, distances, shapes] = await Promise.all([
    pool.query<LiveRow>(
      `
      SELECT vp.route_id, vp.vehicle_id, vp.lat, vp.lon, vp.position_timestamp,
             vpr.accepted, vpr.accepted_dist_along_route_m,
             vpr.raw_dist_along_route_m, vpr.reject_reason
      FROM vehicle_position vp
      LEFT JOIN vehicle_progress vpr
        ON vpr.frame_id = vp.frame_id AND vpr.vehicle_id = vp.vehicle_id
      WHERE vp.frame_id = $1
        AND vp.route_id = ANY($2::text[])
      `,
      [frame.frameId, routeIds],
    ),
    stopDistances(routeIds),
    Promise.all(routeIds.map(async (routeId) => [routeId, await routeShape(routeId)] as const)),
  ]);

  const shapeByRoute = new Map(shapes);

  const candidates: Candidate[] = [];
  for (const row of positions.rows) {
    const route = routeInfo.get(row.route_id);
    if (!route) continue;

    // Rejected readings are not a position. Keep them out rather than
    // showing a bus where the matcher says it is not.
    if (!row.accepted || row.accepted_dist_along_route_m === null) continue;

    const stops = distances.get(row.route_id);
    if (!stops) continue;
    const position = stopPosition(stops, row.accepted_dist_along_route_m);
    if (!position) continue;

    const shape = shapeByRoute.get(row.route_id) ?? null;
    const snapped = shape ? pointAtDistance(shape, row.accepted_dist_along_route_m) : null;
    const offsetM = snapped
      ? haversineMeters(row.lat, row.lon, snapped.lat, snapped.lon)
      : null;

    candidates.push({
      routeId: row.route_id,
      routeNumber: route.routeNumber,
      routeShortName: route.routeShortName,
      destination: route.destination,
      vehicleId: row.vehicle_id,
      source: 'official',
      stale: frame.ageSeconds > LIVE_TTL_SECONDS,
      currentStopSequence: position.current,
      targetStopSequence: route.stopSequence,
      progressM: row.accepted_dist_along_route_m,
      routeLengthM: routeLength.get(row.route_id) ?? 0,
      recordedAt: row.position_timestamp,
      lastSeen: row.position_timestamp,
      match: {
        accepted: true,
        offsetM: offsetM === null ? null : Math.round(offsetM),
        rawLat: row.lat,
        rawLon: row.lon,
        snappedLat: snapped?.lat ?? null,
        snappedLon: snapped?.lon ?? null,
      },
      crowd: null,
    });
  }

  return { candidates, frameAt: frame.at };
}

// ---------------------------------------------------------------------------
// Passenger beacons
// ---------------------------------------------------------------------------

/**
 * Merge active passenger reports as positions. Only when the app is live:
 * a beacon is an event now, not something that belongs to a recorded day.
 *
 * An official bus wins when a beacon is within 300 m and 3 minutes of it;
 * otherwise the beacon becomes its own arrival, marked PASSENGER.
 */
async function passengerCandidates(
  routes: PlaceRoute[],
  routeLength: Map<string, number>,
  official: Candidate[],
): Promise<Candidate[]> {
  const routeIds = [...new Set(routes.map((route) => route.routeId))];
  const routeInfo = new Map(routes.map((route) => [route.routeId, route]));
  const [distances, shapes] = await Promise.all([
    stopDistances(routeIds),
    Promise.all(routeIds.map(async (routeId) => [routeId, await routeShape(routeId)] as const)),
  ]);
  const shapeByRoute = new Map(shapes);

  const candidates: Candidate[] = [];
  for (const routeId of routeIds) {
    const route = routeInfo.get(routeId);
    if (!route) continue;

    for (const vehicle of crowdsourceStore.getActiveVehicles(routeId)) {
      const alreadyOfficial = official.some(
        (candidate) =>
          candidate.routeId === routeId &&
          haversineMeters(vehicle.lat, vehicle.lon, candidate.match?.rawLat ?? vehicle.lat, candidate.match?.rawLon ?? vehicle.lon) < 300 &&
          Math.abs(candidate.recordedAt.getTime() - new Date(vehicle.lastUpdated).getTime()) < 3 * 60 * 1000,
      );
      if (alreadyOfficial) continue;

      const shape = shapeByRoute.get(routeId) ?? null;
      const progressM = shape ? progressAtPoint(shape, vehicle.lat, vehicle.lon) : null;
      const stops = distances.get(routeId);
      if (progressM === null || !stops) continue;

      const position = stopPosition(stops, progressM);
      if (!position) continue;

      const snapped = shape ? pointAtDistance(shape, progressM) : null;
      const lastUpdated = new Date(vehicle.lastUpdated);
      candidates.push({
        routeId,
        routeNumber: route.routeNumber,
        routeShortName: route.routeShortName,
        destination: route.destination,
        vehicleId: `crowd-${routeId}`,
        source: 'passenger',
        stale: false,
        currentStopSequence: position.current,
        targetStopSequence: route.stopSequence,
        progressM,
        routeLengthM: routeLength.get(routeId) ?? 0,
        recordedAt: lastUpdated,
        lastSeen: lastUpdated,
        match: {
          accepted: true,
          offsetM: snapped ? Math.round(haversineMeters(vehicle.lat, vehicle.lon, snapped.lat, snapped.lon)) : null,
          rawLat: vehicle.lat,
          rawLon: vehicle.lon,
          snappedLat: snapped?.lat ?? null,
          snappedLon: snapped?.lon ?? null,
        },
        crowd: {
          passengers: vehicle.activePassengerCount,
          confidence: vehicle.confidence,
        },
      });
    }
  }
  return candidates;
}

// ---------------------------------------------------------------------------
// Batched ETA
// ---------------------------------------------------------------------------

/**
 * Cost many buses on the same route against one target stop.
 *
 * `estimateArrival` does one bus at a time. A stop board has twenty, so
 * this fetches the hop rows once and sums the same resolved hops for each
 * bus. The maths is deliberately identical; check-arrivals compares the
 * two answers.
 */
async function estimateBatch(
  candidates: Candidate[],
  at: Date,
): Promise<Map<string, { arrival: Arrival; etaSeconds: number }>> {
  const result = new Map<string, { arrival: Arrival; etaSeconds: number }>();
  if (candidates.length === 0) return result;

  const routeIds = [...new Set(candidates.map((candidate) => candidate.routeId))];
  const maxTarget = Math.max(...candidates.map((candidate) => candidate.targetStopSequence));
  const { hourOfDay, dayType } = delhiTimeParts(at);

  const { rows } = await pool.query<HopRow & { route_id: string }>(
    `
    SELECT route_id, to_stop_sequence, day_type, hour_of_day, sample_count, mean_seconds
    FROM route_segment_travel_time
    WHERE route_id = ANY($1::text[])
      AND to_stop_sequence <= $2
      AND (   (day_type = $3 AND hour_of_day = $4)
           OR (day_type = $3 AND hour_of_day = -1)
           OR (day_type = 'any' AND hour_of_day = -1) )
    `,
    [routeIds, maxTarget, dayType, hourOfDay],
  );

  // routeId -> toStopSequence -> the three candidate rows.
  const byRoute = new Map<string, Map<number, HopRow[]>>();
  for (const row of rows) {
    const bySequence = byRoute.get(row.route_id) ?? new Map<number, HopRow[]>();
    const list = bySequence.get(row.to_stop_sequence) ?? [];
    list.push({
      to_stop_sequence: row.to_stop_sequence,
      day_type: row.day_type,
      hour_of_day: row.hour_of_day,
      sample_count: row.sample_count,
      mean_seconds: row.mean_seconds,
    });
    bySequence.set(row.to_stop_sequence, list);
    byRoute.set(row.route_id, bySequence);
  }

  for (const candidate of candidates) {
    const hops = candidate.targetStopSequence - candidate.currentStopSequence;
    if (hops < 0) continue;

    const bySequence = byRoute.get(candidate.routeId) ?? new Map<number, HopRow[]>();
    const quality: Record<HopSource, number> = {
      'this-hour-this-daytype': 0,
      'any-hour-this-daytype': 0,
      'any-day-any-hour': 0,
      missing: 0,
    };

    let seconds = 0;
    for (let seq = candidate.currentStopSequence + 1; seq <= candidate.targetStopSequence; seq++) {
      const resolved = resolveHop(bySequence.get(seq) ?? [], dayType, hourOfDay);
      quality[resolved.source]++;
      seconds += resolved.seconds;
    }

    const band = hops === 0 ? { low: 0, high: 0 } : rangeForHops(hops, dayType);

    // A bus reported by a passenger, or last seen several minutes ago, is
    // less certain than a fresh official reading. Widen the window and
    // cap the confidence instead of pretending it is the same.
    const ageSeconds = Math.max(0, (at.getTime() - candidate.lastSeen.getTime()) / 1000);
    const staleExtra = candidate.source === 'official' && candidate.stale ? 0.15 : 0;
    const passengerExtra = candidate.source === 'passenger' ? 0.25 : 0;
    const extra = 1 + staleExtra + passengerExtra;

    const low = Math.max(0, seconds + band.low * extra);
    const high = Math.max(low, seconds + band.high * extra);
    const confidence = confidenceFor(candidate, quality, hops, ageSeconds);
    const arrivalAt = new Date(at.getTime() + seconds * 1000);
    const lowAt = new Date(at.getTime() + low * 1000);
    const highAt = new Date(at.getTime() + high * 1000);

    const arrival: Arrival = {
      routeId: candidate.routeId,
      routeShortName: candidate.routeShortName,
      routeNumber: candidate.routeNumber,
      destination: candidate.destination,
      vehicleId: candidate.vehicleId,
      source: candidate.source,
      stale: candidate.stale,
      currentStopSequence: candidate.currentStopSequence,
      targetStopSequence: candidate.targetStopSequence,
      stopsAway: hops,
      progressM: candidate.progressM,
      progressFraction: candidate.routeLengthM > 0
        ? Math.min(1, Math.max(0, candidate.progressM / candidate.routeLengthM))
        : 0,
      routeLengthM: candidate.routeLengthM,
      recordedAt: candidate.recordedAt.toISOString(),
      lastSeen: candidate.lastSeen.toISOString(),
      eta: {
        seconds: round(seconds),
        text: minutesText(seconds),
        at: arrivalAt.toISOString(),
      },
      range: {
        lowSeconds: round(low),
        highSeconds: round(high),
        text: rangeText(low, high),
        lowAt: lowAt.toISOString(),
        highAt: highAt.toISOString(),
        couldBeArrivingNow: seconds + band.low * extra < 0,
      },
      confidence,
      match: candidate.match,
      crowd: candidate.crowd,
      // Filled in by attachLocationProofs() once the board is final, so the
      // verifier runs once per shown bus rather than once per candidate.
      proof: null,
    };

    if (quality.missing > 0) {
      arrival.unavailable = {
        reason:
          `${quality.missing} of ${hops} stop-to-stop legs have never been observed, ` +
          'so this estimate would be too low. Showing it as unavailable rather than wrong.',
        missingHops: quality.missing,
      };
    }

    result.set(`${candidate.routeId}|${candidate.vehicleId}`, {
      arrival,
      etaSeconds: seconds,
    });
  }

  return result;
}

function confidenceFor(
  candidate: Candidate,
  quality: Record<HopSource, number>,
  hops: number,
  ageSeconds: number,
): Confidence {
  const base = describeConfidence(quality, hops);

  if (candidate.source === 'passenger') {
    return {
      level: base.level === 'high' ? 'medium' : base.level,
      because: 'Reported by a passenger on the bus, not by the official GPS feed. ' + base.because,
    };
  }

  if (candidate.stale && ageSeconds > 5 * 60) {
    return {
      level: 'low',
      because: 'The official feed has not updated this bus for several minutes, so its position may have moved on. ' + base.because,
    };
  }

  return base;
}

// ---------------------------------------------------------------------------
// Location proofs (simulated)
//
// Every non-passenger bus position can carry the result of the paper's
// verification round for one point of interest: Algorithm 1 picks the nearest
// satellite on each of the four sides of that POI, Algorithm 2 turns the
// satellite timestamps into ranges and solves the four-sphere equations for
// the vehicle, and Algorithm 3 checks the solved distance against the known
// one. The satellite observables are SIMULATED (the real feed publishes none),
// so a proof says the checking pipeline works - never that Delhi's feed is
// honest.
//
// This lives here, in one helper, because both the stop board and the route
// detail (the ride screen polls it) must show the same verdict for the same
// bus. It is deliberately the ONLY place proofs are attached.
// ---------------------------------------------------------------------------

/** The caveat shown when a replay row has no raw archive fix to verify. */
const NO_RAW_FIX_CAVEAT =
  'No recorded GPS fix was attached to this position, so no location proof is shown.';

/** Height used for proofs built from DB rows, which carry no altitude. */
const PROOF_ALTITUDE_M = 216;

/**
 * The paper's point of interest (POI) for one board or route screen.
 *
 * In Paul, Dhal and Mary (IEEE/ACM TON 32(3), 2024) the whole protocol is run
 * for one POI: Algorithm 1 picks the nearest satellite on each side OF IT,
 * Algorithm 2 measures every vehicle's distance from it, and Algorithm 3
 * checks that distance. In this app the POI is always a bus stop - the place
 * the board is about, or the stop the route screen is costing against - so
 * every proof on one screen is about the same physical spot.
 *
 * `name` is only for the UI ("Point of interest: Shivaji Stadium"); the
 * geometry needs the coordinates.
 */
export interface ProofPoi {
  lat: number;
  lon: number;
  name: string | null;
}

/** The physical place a stop sequence on a route belongs to, if known. */
async function placeForRouteStop(
  routeId: string,
  stopSequence: number,
): Promise<PlaceInfo | null> {
  const { rows } = await pool.query<{ place_id: number }>(
    `
    SELECT place_id
    FROM route_place
    WHERE route_id = $1 AND stop_sequence = $2
    LIMIT 1
    `,
    [routeId, stopSequence],
  );

  const placeId = rows[0]?.place_id;
  if (placeId === undefined) return null;
  return placeInfo(placeId);
}

/**
 * The POI a route screen's proofs belong to.
 *
 * With a chosen target stop, that stop is the point of interest: the place it
 * belongs to when the stop has one (that row carries the name a rider knows
 * and the coordinate the paper's geometry uses), otherwise the stop's own
 * coordinates and name. Without a target stop, the route's first stop is the
 * POI, so every bus on the route is still checked against somewhere real.
 *
 * Returns null only when the chosen stop carries no coordinates at all; the
 * caller then attaches no proofs rather than inventing a point of interest.
 */
async function proofPoiForRoute(
  routeId: string,
  stops: RouteStop[],
  targetStopSequence: number | null,
): Promise<ProofPoi | null> {
  if (stops.length === 0) return null;

  const chosen = targetStopSequence === null
    ? stops[0]
    : stops.find((stop) => stop.stopSequence === targetStopSequence) ?? stops[0];

  const place = await placeForRouteStop(routeId, chosen.stopSequence);
  if (place) return { lat: place.lat, lon: place.lon, name: place.name };

  if (chosen.lat === null || chosen.lon === null) return null;
  return { lat: chosen.lat, lon: chosen.lon, name: chosen.stopName };
}

/** One raw recorded GPS fix from the archive, with the row's own timestamp. */
interface RawFixRow {
  route_id: string;
  vehicle_id: string;
  lat: number;
  lon: number;
  position_timestamp: Date;
}

/**
 * One batched query for the nearest recorded raw fix of many buses.
 *
 * A replay arrival is placed by interpolating the matched stop passages. The
 * proof, however, must be built from the ACTUAL GPS reading the bus sent -
 * otherwise it would prove a position we made up. So for every (route, bus)
 * on the board we ask the archive for its closest real reading within three
 * minutes, in a single query (one indexed lookup per bus, not one round trip
 * per bus: vehicle_position holds 21.8M rows).
 */
async function nearestRawFixes(
  pairs: { routeId: string; vehicleId: string }[],
  at: Date,
): Promise<Map<string, RawFixRow>> {
  if (pairs.length === 0) return new Map();

  const { rows } = await pool.query<RawFixRow>(
    `
    SELECT pair.route_id, pair.vehicle_id, fix.lat, fix.lon, fix.position_timestamp
    FROM unnest($1::text[], $2::text[]) AS pair(route_id, vehicle_id)
    CROSS JOIN LATERAL (
      SELECT vp.lat, vp.lon, vp.position_timestamp
      FROM vehicle_position vp
      WHERE vp.vehicle_id = pair.vehicle_id
        AND vp.route_id = pair.route_id
        AND vp.position_timestamp BETWEEN $3::timestamptz - interval '3 minutes'
                                     AND $3::timestamptz + interval '3 minutes'
      -- Closest in time wins; the index on (vehicle_id, position_timestamp)
      -- makes this one short index read per bus.
      ORDER BY abs(extract(epoch FROM (vp.position_timestamp - $3::timestamptz)))
      LIMIT 1
    ) fix
    `,
    [pairs.map((pair) => pair.routeId), pairs.map((pair) => pair.vehicleId), at.toISOString()],
  );

  return new Map(rows.map((row) => [`${row.route_id}|${row.vehicle_id}`, row]));
}

/** The confidence levels from best to worst, so a cap is a simple min(). */
const CONFIDENCE_ORDER: Record<Confidence['level'], number> = {
  low: 0,
  medium: 1,
  high: 2,
};

/** Lower a confidence level so it never sits above the proof's limit. */
function cappedConfidenceLevel(
  level: Confidence['level'],
  maximum: Confidence['level'],
): Confidence['level'] {
  return CONFIDENCE_ORDER[level] <= CONFIDENCE_ORDER[maximum] ? level : maximum;
}

/**
 * Attach the proof summary to each arrival and, when the verifier distrusts
 * the fix, step the confidence down. Never touches the ETA numbers: they were
 * measured on the same recorded buses either way.
 */
function applyProofToConfidence(arrival: Arrival): void {
  const proof = arrival.proof;
  if (!proof || !arrival.confidence) return;

  if (proof.status === 'rejected') {
    arrival.confidence = {
      level: 'low',
      because: "The bus's GPS check failed. " + arrival.confidence.because,
    };
    return;
  }
  if (proof.status === 'weak') {
    arrival.confidence = {
      level: cappedConfidenceLevel(arrival.confidence.level, 'medium'),
      because: 'The GPS fix is weak. ' + arrival.confidence.because,
    };
  }
}

/**
 * Attach a ProofSummary to every arrival that can honestly carry one.
 *
 * - passenger: null (a passenger's phone has no bus-GPS proof)
 * - official: from the raw position the feed reported at recordedAt
 * - replay: from the nearest ACTUAL archive fix within +/-3 minutes of the
 *   board moment; null plus a caveat when the archive has none
 *
 * `poi` is the point of interest every proof on this screen belongs to: the
 * board's place, or the route screen's target stop. The paper has no proof
 * without one - the four satellites are selected relative to it - so a null
 * POI means no proofs rather than an invented position.
 *
 * `shapes` gives the route line each replay row belongs to. The route check
 * then measures how far the ARCHIVED fix sits from that line: the "off the
 * route" distance, not how far the bus moved between the fix and the board
 * moment. (Those are different numbers - a bus can be exactly on its line and
 * still be hundreds of metres from the interpolated board point.)
 */
async function attachLocationProofs(
  arrivals: Arrival[],
  at: Date,
  shapes: Map<string, RouteShape | null>,
  poi: ProofPoi | null,
): Promise<{ caveats: string[] }> {
  const caveats: string[] = [];

  // Algorithm 1 is run relative to the POI, so without one there is nothing
  // for the verifier to measure the fix against. Leave every proof null
  // instead of quietly making up a point of interest.
  if (poi === null) return { caveats };

  const replayArrivals = arrivals.filter((arrival) => arrival.source === 'replay');
  const rawFixes = await nearestRawFixes(
    replayArrivals.map((arrival) => ({
      routeId: arrival.routeId,
      vehicleId: arrival.vehicleId,
    })),
    at,
  );

  let replayWithoutFix = 0;

  for (const arrival of arrivals) {
    if (arrival.source === 'passenger') {
      // The UI labels this row "No bus GPS proof"; it is not a failure.
      arrival.proof = null;
      continue;
    }

    if (arrival.source === 'official') {
      const rawLat = arrival.match?.rawLat ?? null;
      const rawLon = arrival.match?.rawLon ?? null;
      if (rawLat !== null && rawLon !== null) {
        // A live fix younger than an hour is checked as live; older ones are
        // checked as archived (buildLocationProof applies that default).
        arrival.proof = summarizeProof(
          buildLocationProof({
            vehicleId: arrival.vehicleId,
            position: { lat: rawLat, lon: rawLon, altM: PROOF_ALTITUDE_M },
            // The paper's POI: the four nearest satellites are chosen around
            // this stop, one per side, and the check is "does the fix sit
            // where the ranges put it relative to here".
            poi: { lat: poi.lat, lon: poi.lon, altM: PROOF_ALTITUDE_M },
            poiName: poi.name,
            fixAt: new Date(arrival.recordedAt),
            routeOffsetM: arrival.match?.offsetM ?? null,
          }),
        );
      }
      applyProofToConfidence(arrival);
      continue;
    }

    // Replay: verify the real archived GPS reading, not the interpolated
    // position the board is showing.
    const rawFix = rawFixes.get(`${arrival.routeId}|${arrival.vehicleId}`);
    if (!rawFix) {
      replayWithoutFix++;
      arrival.proof = null;
      continue;
    }

    // How far is the archived fix itself from its route line? Snap the fix to
    // the shape at the fix's OWN position, then measure the leftover distance.
    // Measuring it against the board point instead would count how far the bus
    // drove between the two moments, which is not an off-route distance.
    const shape = shapes.get(arrival.routeId) ?? null;
    let routeOffsetM: number | null = null;
    if (shape) {
      const progress = progressAtPoint(shape, rawFix.lat, rawFix.lon);
      const closest = pointAtDistance(shape, progress);
      routeOffsetM = haversineMeters(rawFix.lat, rawFix.lon, closest.lat, closest.lon);
    }

    arrival.proof = summarizeProof(
      buildLocationProof({
        vehicleId: arrival.vehicleId,
        position: { lat: rawFix.lat, lon: rawFix.lon, altM: PROOF_ALTITUDE_M },
        // Same POI as every other row on this screen: the archived fix is
        // checked against the stop the board is about.
        poi: { lat: poi.lat, lon: poi.lon, altM: PROOF_ALTITUDE_M },
        poiName: poi.name,
        fixAt: rawFix.position_timestamp,
        routeOffsetM,
        verificationMode: 'archived',
      }),
    );

    // Keep the sheet honest where there is a match object: the bus marker and
    // the raw dot then agree about which GPS reading the proof belongs to.
    if (arrival.match) {
      arrival.match.rawLat = rawFix.lat;
      arrival.match.rawLon = rawFix.lon;
    }
    applyProofToConfidence(arrival);
  }

  if (replayWithoutFix > 0) caveats.push(NO_RAW_FIX_CAVEAT);
  return { caveats };
}

// ---------------------------------------------------------------------------
// Frequency fallback
// ---------------------------------------------------------------------------

/**
 * For routes with no tracked bus, the honest answer is how often the route
 * normally comes, not a made-up countdown.
 */
export async function frequencyForPlace(
  placeId: number,
  at: Date,
  excludeRouteIds: string[] = [],
): Promise<FrequencyRow[]> {
  const { hourOfDay, dayType } = delhiTimeParts(at);
  const { rows } = await pool.query<{
    route_id: string;
    avg_gap_minutes: string | number | null;
    days_seen: string | number;
    passages: string | number;
    route_short_name: string;
    route_desc: string;
  }>(
    `
    SELECT f.route_id, f.avg_gap_minutes, f.days_seen, f.passages,
           r.route_short_name, r.route_desc
    FROM place_route_frequency f
    JOIN routes r
      ON r.route_id = f.route_id
     AND r.snapshot_id = (SELECT max(snapshot_id) FROM routes)
    WHERE f.place_id = $1
      AND f.day_type = $2
      AND f.hour_of_day = $3
      AND f.days_seen >= 2
      AND f.avg_gap_minutes IS NOT NULL
      AND f.avg_gap_minutes > 0
      AND NOT (f.route_id = ANY($4::text[]))
    ORDER BY f.days_seen DESC, f.avg_gap_minutes ASC
    LIMIT 8
    `,
    [placeId, dayType, hourOfDay, excludeRouteIds],
  );

  return rows.map((row) => ({
    routeId: row.route_id,
    routeShortName: row.route_short_name,
    routeNumber: row.route_short_name.replace(/(UP|DOWN)$/i, ''),
    destination: destinationFromDesc(row.route_desc ?? row.route_short_name),
    headwayMinutes: Math.round(Number(row.avg_gap_minutes) * 10) / 10,
    daysSeen: Number(row.days_seen),
    samplePassages: Number(row.passages),
  }));
}

// ---------------------------------------------------------------------------
// The public reads
// ---------------------------------------------------------------------------

/**
 * Buses coming to one physical stop.
 *
 * With `toPlaceId` the answer narrows to "buses from here to there": only
 * routes that reach that destination place AFTER the place the rider is
 * boarding at count as direct, and every bus is costed to the destination
 * stop instead of to the boarding stop. Without it the board is exactly what
 * it always was.
 *
 * Returns null when the boarding place - or a requested destination place -
 * is not in the current static snapshot.
 */
export async function arrivalsForPlace(
  placeId: number,
  at: Date | null,
  windowMinutes = 45,
  toPlaceId?: number,
): Promise<ArrivalsResult | null> {
  const place = await placeInfo(placeId);
  if (!place) return null;

  // A destination filter needs the destination place too. server.ts looks it
  // up first so it can say WHICH id was unknown; doing it again here stops a
  // direct caller from getting a board that silently ignores a destination
  // it could not resolve.
  const destination = toPlaceId === undefined ? null : await placeInfo(toPlaceId);
  if (toPlaceId !== undefined && destination === null) return null;

  let routes = await routesAtPlace(placeId);

  // Which routes actually carry the rider from here to the destination with
  // no change? Routes that do not are not direct buses for this trip, so drop
  // them before fetching positions, shapes or frequency for them.
  let destinationSeq = new Map<string, number>();
  if (toPlaceId !== undefined) {
    destinationSeq = await destinationSequences(routes, toPlaceId);
    routes = routes.filter((route) => destinationSeq.has(route.routeId));
  }

  // A destination was asked for but no single route reaches it after this
  // stop. That is a real answer: an empty board plus the caveat below, never
  // buses that would take the rider somewhere else.
  const noDirect = toPlaceId !== undefined && destinationSeq.size === 0;

  const routeIds = [...new Set(routes.map((route) => route.routeId))];
  const routeLength = await routeLengths(routeIds);
  const feed = await feedStatus();
  const moment = at ?? new Date();
  const mode: ArrivalsMode = at ? 'replay' : 'live';

  let candidates: Candidate[];
  if (at) {
    candidates = await replayCandidates(routes, at, routeLength);
  } else {
    const live = await liveCandidates(routes, routeLength);
    const passengers = await passengerCandidates(routes, routeLength, live.candidates);
    candidates = [...live.candidates, ...passengers];
  }

  // With a destination, retarget each bus at the destination stop. Every ETA,
  // stopsAway and range below then answers "when do I get there", not "when
  // does the bus reach this stop". A bus that already passed the boarding
  // stop is dropped first: its target, set when the candidate was built, is
  // still the boarding sequence at this point.
  if (toPlaceId !== undefined) {
    const directOnly: Candidate[] = [];
    for (const candidate of candidates) {
      if (candidate.currentStopSequence > candidate.targetStopSequence) continue;
      const target = destinationSeq.get(candidate.routeId);
      if (target === undefined) continue;
      candidate.targetStopSequence = target;
      directOnly.push(candidate);
    }
    candidates = directOnly;
  }

  // A route may have many buses. Keep the two nearest to the stop, then
  // cost at most thirty of them. A board cannot show more than twenty.
  const byRoute = new Map<string, Candidate[]>();
  for (const candidate of candidates) {
    if (candidate.currentStopSequence > candidate.targetStopSequence) continue;
    const list = byRoute.get(candidate.routeId) ?? [];
    list.push(candidate);
    byRoute.set(candidate.routeId, list);
  }

  const nearest: Candidate[] = [];
  for (const list of byRoute.values()) {
    list.sort((a, b) => a.targetStopSequence - a.currentStopSequence - (b.targetStopSequence - b.currentStopSequence));
    nearest.push(...list.slice(0, 2));
  }
  // Fill the candidate budget with buses that are still approaching
  // before buses already standing at the stop. At a terminal like
  // Connaught Place there can be a dozen of the latter, and they would
  // otherwise crowd out every useful arrival.
  nearest.sort((a, b) => {
    const aAtStop = a.currentStopSequence === a.targetStopSequence ? 1 : 0;
    const bAtStop = b.currentStopSequence === b.targetStopSequence ? 1 : 0;
    if (aAtStop !== bAtStop) return aAtStop - bAtStop;
    return a.targetStopSequence - a.currentStopSequence - (b.targetStopSequence - b.currentStopSequence);
  });

  const estimated = await estimateBatch(nearest.slice(0, 30), moment);
  const all = [...estimated.values()]
    .map((entry) => entry.arrival)
    .filter((arrival) => !arrival.eta || arrival.eta.seconds <= windowMinutes * 60);

  // A big interchange can have a dozen buses standing at the stop at the
  // same moment. Showing all of them buries the buses that are actually
  // approaching, so keep at most three "at this stop" rows and fill the
  // rest of the board with real arrivals.
  const atStop = all
    .filter((arrival) => arrival.stopsAway === 0)
    .sort((a, b) => new Date(b.recordedAt).getTime() - new Date(a.recordedAt).getTime())
    .slice(0, 3);
  const approaching = all
    .filter((arrival) => (arrival.stopsAway ?? 0) > 0)
    .sort((a, b) => {
      const aLow = a.range?.lowSeconds ?? Number.MAX_SAFE_INTEGER;
      const bLow = b.range?.lowSeconds ?? Number.MAX_SAFE_INTEGER;
      return aLow - bLow;
    });
  const arrivals = [...approaching, ...atStop].slice(0, 20);

  // The map needs a point for each marker. A live or passenger arrival
  // already carries its snapped point; a replay arrival only has progress
  // along the route, so place it on the route's shape here. Shapes are
  // cached per route, and the route screen will reuse the same ones.
  const markerRoutes = [...new Set(arrivals.map((arrival) => arrival.routeId))];
  const markerShapes = new Map(
    await Promise.all(markerRoutes.map(async (routeId) => [routeId, await routeShape(routeId)] as const)),
  );
  for (const arrival of arrivals) {
    if (arrival.match !== null) continue;
    const shape = markerShapes.get(arrival.routeId);
    if (!shape) continue;
    const point = pointAtDistance(shape, arrival.progressM);
    arrival.match = {
      accepted: true,
      offsetM: null,
      rawLat: null,
      rawLon: null,
      snappedLat: point.lat,
      snappedLon: point.lon,
    };
  }

  // Attach the simulated GPS proof to each final row, and step the confidence
  // down when the verifier does not trust the fix. One shared helper means the
  // stop board and the ride screen cannot show different verdicts.
  //
  // The point of interest is the board's own place: the paper's four nearest
  // satellites are chosen around the stop the rider is standing at, and every
  // proof on this screen is "is this bus really where it says relative to this
  // stop".
  const poi: ProofPoi = { lat: place.lat, lon: place.lon, name: place.name };
  const proofAttachments = await attachLocationProofs(arrivals, moment, markerShapes, poi);

  // Only routes with no tracked bus get a frequency row. A route with a
  // bus already has a real arrival, even if it is far away. With a
  // destination, a frequency row is only honest for a route that actually
  // carries the rider there, so non-direct routes are filtered out too.
  // When there is no direct route at all the frequency list is empty too.
  const routesWithArrivals = new Set(arrivals.map((arrival) => arrival.routeId));
  let frequency: FrequencyRow[] = [];
  if (!noDirect) {
    frequency = await frequencyForPlace(placeId, moment, [...routesWithArrivals]);
    if (toPlaceId !== undefined) {
      frequency = frequency.filter((row) => destinationSeq.has(row.routeId));
    }
  }

  const caveats: string[] = [];
  if (noDirect && destination !== null) {
    // The contract's honest fallback. The app shows this instead of an empty
    // list with no explanation; the Plan tab can find a trip with a change.
    caveats.push(
      `No direct bus from this stop to ${destination.name}. ` +
        'The Plan tab can look for a trip with one change.',
    );
  }
  if (mode === 'replay') {
    caveats.push('Replay: buses are placed from recorded stop passages, not live GPS.');
  } else if (!feed.live) {
    caveats.push(feed.reason);
  }
  caveats.push(...proofAttachments.caveats);
  if (frequency.length > 0) {
    caveats.push('Routes with no tracked bus show observed frequency, not an arrival time.');
  }
  if (delhiTimeParts(moment).dayType === 'weekend') {
    caveats.push('Weekend timing rests on two recorded days, so the range is wider.');
  }

  return {
    place,
    mode,
    at: moment.toISOString(),
    feed,
    destination,
    noDirect,
    arrivals,
    frequency,
    caveats,
  };
}

/** One route's static detail plus the buses on it, optionally for one stop. */
export async function routeDetail(
  routeId: string,
  at: Date | null,
  targetStopSequence: number | null,
): Promise<RouteDetailResult | null> {
  const meta = await routeMeta(routeId);
  if (!meta) return null;

  const [shape, stops, feed, window] = await Promise.all([
    routeShape(routeId),
    routeStops(routeId),
    feedStatus(),
    serviceWindow(routeId),
  ]);

  const moment = at ?? new Date();
  const mode: ArrivalsMode = at ? 'replay' : 'live';
  const target = targetStopSequence ?? null;

  // The POI the proofs on this screen belong to: the chosen target stop when
  // the caller picked one, otherwise the route's first stop. Looked up before
  // the buses are costed so the proof helper needs no extra query per row.
  const poi = await proofPoiForRoute(routeId, stops, target);

  const routeAsPlace: PlaceRoute = {
    routeId,
    // Without a chosen stop, cost every bus against the end of the route
    // so none are dropped by the "target must be ahead" filter. The ETA is
    // stripped again below; the target is only a placeholder for costing.
    stopSequence: target ?? stops[stops.length - 1]?.stopSequence ?? 0,
    routeShortName: meta.routeShortName,
    routeDesc: meta.routeDesc,
    destination: meta.destination,
    routeNumber: meta.routeNumber,
  };

  const routeLength = await routeLengths([routeId]);
  let candidates: Candidate[];
  if (at) {
    candidates = await replayCandidates([routeAsPlace], at, routeLength);
  } else {
    const live = await liveCandidates([routeAsPlace], routeLength);
    const passengers = await passengerCandidates([routeAsPlace], routeLength, live.candidates);
    candidates = [...live.candidates, ...passengers];
  }

  // A route screen with a chosen stop only cares about buses that have not
  // passed it yet. Without a target, show every bus on the route.
  const relevant = target === null
    ? candidates
    : candidates.filter((candidate) => candidate.currentStopSequence <= target);

  const nearest = relevant
    .sort((a, b) => a.currentStopSequence - b.currentStopSequence)
    .slice(0, 20);

  const estimated = await estimateBatch(nearest, moment);
  const runs = [...estimated.values()]
    .map((entry) => entry.arrival)
    .map((arrival) => {
      // Without a target stop there is no ETA to show. Do not leave the
      // first stop's ETA attached to a card that never named a target.
      if (target !== null) return arrival;
      return {
        ...arrival,
        targetStopSequence: null,
        stopsAway: null,
        eta: null,
        range: null,
        confidence: null,
      };
    })
    .sort((a, b) => (a.range?.lowSeconds ?? Number.MAX_SAFE_INTEGER) - (b.range?.lowSeconds ?? Number.MAX_SAFE_INTEGER));

  // The ride screen reads the same proof summaries as the stop board: the
  // same helper, the same rules, so the two screens cannot disagree about a
  // bus's GPS check. The POI is the target stop (else the route's first stop).
  const proofAttachments = await attachLocationProofs(
    runs,
    moment,
    new Map<string, RouteShape | null>([[routeId, shape]]),
    poi,
  );

  // Frequency at the target stop, if it belongs to a place.
  let frequency: FrequencyRow | null = null;
  if (target !== null) {
    const { rows } = await pool.query<{ place_id: number }>(
      `SELECT place_id FROM route_place WHERE route_id = $1 AND stop_sequence = $2 LIMIT 1`,
      [routeId, target],
    );
    if (rows[0]?.place_id !== undefined) {
      const rowsForPlace = await frequencyForPlace(rows[0].place_id, moment);
      frequency = rowsForPlace.find((row) => row.routeId === routeId) ?? null;
    }
  }

  const caveats: string[] = [];
  if (mode === 'replay') {
    caveats.push('Replay: buses are placed from recorded stop passages, not live GPS.');
  } else if (!feed.live) {
    caveats.push(feed.reason);
  }
  caveats.push(...proofAttachments.caveats);

  return {
    route: meta,
    shape,
    stops,
    runs,
    frequency,
    targetStopSequence: target,
    mode,
    at: moment.toISOString(),
    feed,
    firstDeparture: window.firstDeparture,
    lastDeparture: window.lastDeparture,
    caveats,
  };
}

/** The first and last scheduled departure at the route's first stop. */
async function serviceWindow(
  routeId: string,
): Promise<{ firstDeparture: string | null; lastDeparture: string | null }> {
  const { rows } = await pool.query<{ first_s: number | null; last_s: number | null }>(
    `
    SELECT min(st.departure_s)::int AS first_s,
           max(st.departure_s)::int AS last_s
    FROM stop_times st
    JOIN trips t
      ON t.snapshot_id = st.snapshot_id
     AND t.trip_id = st.trip_id
    WHERE t.route_id = $1
      AND st.stop_sequence = 1
      AND st.snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
    `,
    [routeId],
  );
  const row = rows[0];
  return {
    firstDeparture: clockLabel(row?.first_s ?? null),
    lastDeparture: clockLabel(row?.last_s ?? null),
  };
}

/** 05:30. GTFS times can pass 24:00; wrap them for display. */
function clockLabel(seconds: number | null): string | null {
  if (seconds === null || seconds === undefined) return null;
  const wrapped = ((seconds % 86400) + 86400) % 86400;
  const hours = Math.floor(wrapped / 3600).toString().padStart(2, '0');
  const minutes = Math.floor((wrapped % 3600) / 60).toString().padStart(2, '0');
  return `${hours}:${minutes}`;
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/** The point a given distance along a route's shape. */
function pointAtDistance(shape: RouteShape, distanceM: number): { lat: number; lon: number } {
  if (shape.points.length === 0) return { lat: 0, lon: 0 };
  if (distanceM <= shape.points[0].distM) {
    return { lat: shape.points[0].lat, lon: shape.points[0].lon };
  }

  for (let i = 1; i < shape.points.length; i++) {
    const previous = shape.points[i - 1];
    const current = shape.points[i];
    if (distanceM <= current.distM && current.distM > previous.distM) {
      const fraction = (distanceM - previous.distM) / (current.distM - previous.distM);
      return {
        lat: previous.lat + (current.lat - previous.lat) * fraction,
        lon: previous.lon + (current.lon - previous.lon) * fraction,
      };
    }
  }

  const last = shape.points[shape.points.length - 1];
  return { lat: last.lat, lon: last.lon };
}

/** The distance along the shape nearest to a raw point. Used for beacons. */
function progressAtPoint(shape: RouteShape, lat: number, lon: number): number {
  if (shape.points.length < 2) return 0;

  // Work in a local flat plane around the point. Over a few hundred metres
  // this is accurate enough to choose a segment, which is all we need.
  const cosLat = Math.cos((lat * Math.PI) / 180);
  const project = (p: { lat: number; lon: number }) => ({
    x: (p.lon - lon) * cosLat,
    y: p.lat - lat,
  });

  let best = { distanceSq: Number.POSITIVE_INFINITY, progress: 0 };
  for (let i = 1; i < shape.points.length; i++) {
    const a = project(shape.points[i - 1]);
    const b = project(shape.points[i]);
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const lengthSq = dx * dx + dy * dy;
    if (lengthSq === 0) continue;

    const t = Math.min(1, Math.max(0, -(a.x * dx + a.y * dy) / lengthSq));
    const closestX = a.x + dx * t;
    const closestY = a.y + dy * t;
    const distanceSq = closestX * closestX + closestY * closestY;

    if (distanceSq < best.distanceSq) {
      const start = shape.points[i - 1].distM;
      const end = shape.points[i].distM;
      best = { distanceSq, progress: start + (end - start) * t };
    }
  }
  return best.progress;
}

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
