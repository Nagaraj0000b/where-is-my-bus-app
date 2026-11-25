// The API. Phase 5.
//
//   node api/src/server.ts        (or: npm run api)
//
// Deliberately small. The ETA logic lives in eta.ts and was proved correct
// by api/check-eta.ts before any of this existed - CLAUDE.md working
// convention #4, "script first, service second". This file only translates
// HTTP requests into calls to that logic and back.
//
// THE STOP BOARD
//
// /stops/:placeId/arrivals is the "what is coming to this stop" endpoint.
// It exists, but it does not pretend the recorder is running: with `at` it
// replays the matched stop passages, without it uses the newest non-empty
// frame plus passenger beacons, and routes with no bus fall back to
// observed frequency. See arrivals.ts and feed.ts.

import Fastify from 'fastify';
import cors from '@fastify/cors';
import { pool } from './db.ts';
import { estimateArrival } from './eta.ts';
import { planJourney, planByHour } from './journey.ts';
import { describeConfidence } from './confidence.ts';
import { feedStatus } from './feed.ts';
import { arrivalsForPlace, routeDetail, placeInfo, nearestPlace } from './arrivals.ts';
import type { Arrival, ArrivalsResult, PlaceInfo } from './arrivals.ts';
import { routeStops } from './routes.ts';
import {
  createAccount,
  checkLogin,
  findUserById,
  userIdFromToken,
  tokenFromAuthorizationHeader,
  type PublicUser,
} from './auth.ts';
import { crowdsourceStore } from './crowdsource.ts';
import { buildLocationProof, FAULT_MODES, parseFaultMode, selectRelayVehicle } from './location_proof.ts';
import type { FaultMode, RelayVehicleInput } from './location_proof.ts';
import type { GeoPoint } from './gnss.ts';

const app = Fastify({ logger: true });

// The Flutter web build runs on a different origin from the API. Without
// this the browser blocks every response and the web demo looks broken.
// Native Android/iOS builds are unaffected.
await app.register(cors, { origin: true });

/**
 * Height in metres used for demo coordinates, which carry no altitude.
 *
 * Both the vehicle fix and its point of interest are given as lat/lon only,
 * and the paper's geometry is three-dimensional (the four-sphere solve and
 * Algorithm 3 work in ECEF), so each needs a height. Delhi's average
 * elevation is the honest stand-in for "we do not know it".
 */
const DEMO_ALTITUDE_M = 216;

/**
 * Work out who is making this request, from the Authorization header.
 *
 * Returns null for anyone not logged in, which is a perfectly normal
 * answer here rather than an error - every bus-related endpoint in this
 * file works fine without an account, and only the /auth routes below
 * actually care. See db/schema_auth.sql for why it is that way round.
 */
async function currentUser(req: { headers: Record<string, unknown> }): Promise<PublicUser | null> {
  const header = req.headers['authorization'];
  const token = tokenFromAuthorizationHeader(typeof header === 'string' ? header : undefined);
  const userId = userIdFromToken(token);
  if (!userId) return null;
  return findUserById(userId);
}

function minutesText(seconds: number) {
  const m = Math.round(seconds / 60);
  if (m < 1) return 'under a minute';
  return `${m} min`;
}

/**
 * Build the range for the response, never letting the early end fall
 * before now.
 *
 * The statistical band is symmetric-ish around the estimate, so on a short
 * journey with sparse data the lower end can land in the past - a real
 * case seen on a thin route: estimate 358s, band low -402s, giving "the
 * bus may arrive 44 seconds ago". As a statistic that is meaningful ("it
 * could already be here"); as something to show a person waiting at a
 * stop it is nonsense, and worse, a client reading the number would get a
 * different answer from one reading the text.
 *
 * So the floor is applied once, here, to every representation at the same
 * time - seconds, timestamp and text alike. `couldBeArrivingNow` keeps the
 * information that the band ran into the past, rather than silently
 * discarding it.
 */
function rangeForResponse(
  eta: { range: { earliestSeconds: number; latestSeconds: number; latest: Date } },
  askedAt: Date,
) {
  const rawEarliest = eta.range.earliestSeconds;
  const earliestSeconds = Math.max(0, rawEarliest);
  const latestSeconds = Math.max(0, eta.range.latestSeconds);

  return {
    earliestSeconds: Math.round(earliestSeconds),
    latestSeconds: Math.round(latestSeconds),
    text: earliestSeconds === 0
      ? `any moment, up to ${minutesText(latestSeconds)}`
      : `${minutesText(earliestSeconds)} to ${minutesText(latestSeconds)}`,
    earliestAt: new Date(askedAt.getTime() + earliestSeconds * 1000).toISOString(),
    latestAt: eta.range.latest.toISOString(),
    // True when the honest band reached back before the moment asked -
    // i.e. the bus may already be arriving. Kept explicit so a caller can
    // say "look up" rather than counting down to a time already past.
    couldBeArrivingNow: rawEarliest <= 0,
  };
}

// ---------------------------------------------------------------------------
// GET /health - is the service up and can it reach its data?
// ---------------------------------------------------------------------------
app.get('/health', async (_req, reply) => {
  try {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS segments FROM route_segment_travel_time WHERE day_type = 'any'`,
    );
    return { ok: true, routeSegments: rows[0].segments };
  } catch (err) {
    reply.code(503);
    return { ok: false, error: 'database unreachable' };
  }
});

// ---------------------------------------------------------------------------
// GET /stats - what this app is actually built on.
//
// Feeds the home screen's "what this is built on" panel. It exists because
// of CLAUDE.md's sixth difference from One Delhi: "we are accountable - we
// measure our own error and publish the number." A panel of hardcoded
// figures in the app would be a claim; these are counted from the database
// each time, so they cannot quietly drift away from the truth.
//
// The accuracy figures are the exception and are deliberately constants:
// they came from the 7-fold cross-validation in docs/eta-design.md, which
// is a experiment that was run, not something countable from a live table.
// ---------------------------------------------------------------------------
app.get('/stats', async (_req, reply) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        (SELECT count(*) FROM routes
          WHERE snapshot_id = (SELECT max(snapshot_id) FROM routes))::int   AS routes,
        (SELECT count(*) FROM stops
          WHERE snapshot_id = (SELECT max(snapshot_id) FROM stops))::int    AS stops,
        (SELECT count(*) FROM route_segment_travel_time
          WHERE day_type = 'any')::int                                      AS segments,
        (SELECT count(*) FROM observed_stop_passage)::int                   AS passages,
        (SELECT count(DISTINCT vehicle_id) FROM observed_stop_passage)::int AS vehicles
    `);

    const counted = rows[0];

    return {
      ok: true,
      // Counted live from the database.
      measured: {
        routes: counted.routes,
        stops: counted.stops,
        routeSegments: counted.segments,
        stopPassages: counted.passages,
        vehiclesSeen: counted.vehicles,
        daysRecorded: 7,
        recordedFrom: '2026-08-10',
        recordedTo: '2026-08-16',
      },
      // From the cross-validation experiment, not from a table.
      accuracy: {
        weekdayTwentyHopErrorSeconds: 482,
        weekendTwentyHopErrorSeconds: 370,
        method: '7-fold cross-validation, each recorded day held out in turn',
      },
      honesty: [
        'Times come from one week of recorded buses, not a published timetable.',
        "Delhi's own timetable is generated by assuming constant speed, so it is not used.",
        'There is no live feed right now - the recorder was stopped on 19 Aug 2026.',
      ],
    };
  } catch {
    reply.code(503);
    return { ok: false, error: 'database unreachable' };
  }
});

// ---------------------------------------------------------------------------
// POST /auth/signup - create an account.
//
//   { "email": "...", "password": "...", "displayName": "..." }
//
// All the real decisions (password rules, how the hash is stored, how long
// a login lasts) live in auth.ts and were proved by api/check-auth.ts -
// 41 checks - before this endpoint existed. This is HTTP translation only,
// same as every other route in this file.
// ---------------------------------------------------------------------------
app.post<{
  Body: { email?: string; password?: string; displayName?: string };
}>('/auth/signup', async (req, reply) => {
  const { email, password, displayName } = req.body ?? {};

  if (!email || !password || !displayName) {
    reply.code(400);
    return { error: 'email, password and displayName are all required.' };
  }

  const result = await createAccount({ email, password, displayName });

  if (!result.ok) {
    // 409 Conflict for "that email is taken", 400 for "what you sent is
    // not acceptable". Different problems, and the app shows them
    // differently - one means "log in instead", the other "fix this field".
    reply.code(result.reason.includes('already exists') ? 409 : 400);
    return { ok: false, error: result.reason };
  }

  reply.code(201);
  return { ok: true, user: result.user, token: result.token };
});

// ---------------------------------------------------------------------------
// POST /auth/login - exchange an email and password for a token.
//
// Always answers 401 with the same wording whether the email is unknown or
// the password is wrong. That is deliberate and is explained in full in
// auth.ts (checkLogin) - saying which half was wrong would turn this into
// a way of discovering which addresses have accounts.
// ---------------------------------------------------------------------------
app.post<{
  Body: { email?: string; password?: string };
}>('/auth/login', async (req, reply) => {
  const { email, password } = req.body ?? {};

  if (!email || !password) {
    reply.code(400);
    return { error: 'email and password are both required.' };
  }

  const result = await checkLogin({ email, password });

  if (!result.ok) {
    reply.code(401);
    return { ok: false, error: result.reason };
  }

  return { ok: true, user: result.user, token: result.token };
});

// ---------------------------------------------------------------------------
// GET /auth/me - who does this token belong to?
//
// The app calls this on startup with whatever token it has saved, to find
// out whether that token is still good. It is the one place a stored login
// gets checked against the server rather than trusted blindly.
// ---------------------------------------------------------------------------
app.get('/auth/me', async (req, reply) => {
  const user = await currentUser(req);

  if (!user) {
    reply.code(401);
    return { ok: false, error: 'Not signed in.' };
  }

  return { ok: true, user };
});

// ---------------------------------------------------------------------------
// GET /eta - the core question this project exists to answer.
//
//   /eta?route=2251&from=2&to=12
//   /eta?route=2251&from=2&to=12&at=2026-08-19T13:30:00Z   (for testing)
//
// `from` is where the bus is now, `to` is the stop being asked about, both
// as positions along the route.
// ---------------------------------------------------------------------------
app.get<{
  Querystring: { route?: string; from?: string; to?: string; at?: string };
}>('/eta', async (req, reply) => {
  const { route, from, to, at } = req.query;

  if (!route || from === undefined || to === undefined) {
    reply.code(400);
    return { error: 'route, from and to are all required. Example: /eta?route=2251&from=2&to=12' };
  }

  const fromStopSequence = Number(from);
  const toStopSequence = Number(to);
  if (!Number.isInteger(fromStopSequence) || !Number.isInteger(toStopSequence)) {
    reply.code(400);
    return { error: 'from and to must be whole numbers (positions along the route)' };
  }

  let when: Date | undefined;
  if (at) {
    when = new Date(at);
    if (Number.isNaN(when.getTime())) {
      reply.code(400);
      return { error: 'at must be a valid date, e.g. 2026-08-19T13:30:00Z' };
    }
  }

  const eta = await estimateArrival({ routeId: route, fromStopSequence, toStopSequence, at: when });

  // Refuse rather than mislead. estimateArrival sets `unavailable` when the
  // answer would be knowably wrong (a stop behind the bus, or legs that
  // have never been observed and would make the total read too low).
  if (eta.unavailable) {
    reply.code(422);
    return {
      available: false,
      reason: eta.unavailable.reason,
      route,
      from: fromStopSequence,
      to: toStopSequence,
    };
  }

  const confidence = describeConfidence(eta.quality, eta.hops);

  return {
    available: true,
    route,
    from: fromStopSequence,
    to: toStopSequence,
    stopsAway: eta.hops,

    // Never a bare number: the estimate always travels with its range.
    estimate: {
      seconds: Math.round(eta.predictedSeconds),
      text: minutesText(eta.predictedSeconds),
      arrivesAt: eta.predictedArrival.toISOString(),
    },
    range: rangeForResponse(eta, when ?? new Date()),

    confidence,

    // Where the number came from, leg by leg. Exposed rather than hidden -
    // a caller that wants to show its own warning can, and it makes the
    // estimate auditable instead of a black box.
    basis: {
      source: 'historical',
      legsByDetail: eta.quality,
      dayType: eta.dayType,
      delhiHour: eta.hourOfDay,
    },

    caveats: [
      'Built from one week of recorded data (10-16 Aug 2026).',
      'No live vehicle position is included - this answers "if a bus is at ' +
        'stop ' + fromStopSequence + ' now, when does it reach stop ' + toStopSequence + '".',
      eta.dayType === 'weekend'
        ? 'Weekend estimates rest on only two recorded weekend days and are weaker.'
        : null,
    ].filter(Boolean),
  };
});

// ---------------------------------------------------------------------------
// GET /journey - the question the app actually exists to answer.
//
//   /journey?fromLat=28.6752&fromLon=77.1325&toLat=28.6761&toLon=77.1160
//
// Two locations, not stop ids: a phone knows its coordinates, and nobody
// knows they are standing at stop 1278. Returns ways to travel, ranked by
// TOTAL time - walk plus wait plus ride - because a faster ride on a rarer
// bus is a worse journey (see docs/journey-design.md).
// ---------------------------------------------------------------------------
app.get<{
  Querystring: {
    fromLat?: string; fromLon?: string; toLat?: string; toLon?: string; at?: string;
  };
}>('/journey', async (req, reply) => {
  const fromLat = Number(req.query.fromLat);
  const fromLon = Number(req.query.fromLon);
  const toLat = Number(req.query.toLat);
  const toLon = Number(req.query.toLon);

  if (![fromLat, fromLon, toLat, toLon].every(Number.isFinite)) {
    reply.code(400);
    return {
      error: 'fromLat, fromLon, toLat and toLon are all required. ' +
             'Example: /journey?fromLat=28.6752&fromLon=77.1325&toLat=28.6761&toLon=77.1160',
    };
  }
  if (Math.abs(fromLat) > 90 || Math.abs(toLat) > 90 ||
      Math.abs(fromLon) > 180 || Math.abs(toLon) > 180) {
    reply.code(400);
    return { error: 'latitude must be between -90 and 90, longitude between -180 and 180' };
  }

  let when: Date | undefined;
  if (req.query.at) {
    when = new Date(req.query.at);
    if (Number.isNaN(when.getTime())) {
      reply.code(400);
      return { error: 'at must be a valid date, e.g. 2026-08-19T03:30:00Z' };
    }
  }

  const result = await planJourney({ fromLat, fromLon, toLat, toLon, at: when });

  if (result.options.length === 0) {
    reply.code(422);
    return {
      available: false,
      reason: result.unavailable?.reason ?? 'No route found.',
      context: { dayType: result.dayType, delhiHour: result.hourOfDay },
    };
  }

  return {
    available: true,
    context: { dayType: result.dayType, delhiHour: result.hourOfDay },
    assumptions: {
      walkRadiusMetres: result.searched.walkRadiusMetres,
      walkSpeedMetresPerMin: result.searched.walkSpeedMetresPerMin,
      waitRule: 'Half the average gap between buses, assuming you arrive at the stop at random.',
    },
    options: result.options.map((o) => ({
      changes: o.changes,
      totalMinutes: o.totalMinutes,
      // Never a bare number: the range travels with the estimate.
      rangeMinutes: o.rangeMinutes,
      summary: o.changes === 0
        ? `Take route ${o.legs[0].routeName} from ${o.legs[0].boardPlace}`
        : `Route ${o.legs[0].routeName} to ${o.legs[0].alightPlace}, then route ${o.legs[1].routeName}`,
      breakdown: {
        walkMinutes: o.walkMinutes,
        waitMinutes: o.waitMinutes,
        rideMinutes: o.rideMinutes,
      },
      legs: o.legs,
      confidence: o.confidence,
    })),
    caveats: [
      'Built from one week of recorded data (10-16 Aug 2026), not a published timetable.',
      'Times are typical, not scheduled - Delhi buses do not run to a fixed timetable, ' +
        'and the official one is generated by assuming constant speed.',
      'At most one change is considered; about 13% of journeys need two or more.',
      result.dayType === 'weekend'
        ? 'Weekend figures rest on only two recorded weekend days and are weaker.'
        : null,
    ].filter(Boolean),
  };
});

// ---------------------------------------------------------------------------
// GET /journey/by-hour - "when should I travel?"
//
//   /journey/by-hour?fromLat=..&fromLon=..&toLat=..&toLon=..&dayType=weekday
//
// The same journey planned once for every service hour. Answers the
// question a traveller asks before leaving the house, which no bus app
// answers because it needs OBSERVED frequency - a published timetable
// generated by assuming constant speed cannot tell you that 14:00 is
// quieter than 09:00.
// ---------------------------------------------------------------------------
app.get<{
  Querystring: {
    fromLat?: string; fromLon?: string; toLat?: string; toLon?: string; dayType?: string;
  };
}>('/journey/by-hour', async (req, reply) => {
  const fromLat = Number(req.query.fromLat);
  const fromLon = Number(req.query.fromLon);
  const toLat = Number(req.query.toLat);
  const toLon = Number(req.query.toLon);

  if (![fromLat, fromLon, toLat, toLon].every(Number.isFinite)) {
    reply.code(400);
    return { error: 'fromLat, fromLon, toLat and toLon are all required.' };
  }
  if (Math.abs(fromLat) > 90 || Math.abs(toLat) > 90 ||
      Math.abs(fromLon) > 180 || Math.abs(toLon) > 180) {
    reply.code(400);
    return { error: 'latitude must be between -90 and 90, longitude between -180 and 180' };
  }

  const dayTypeRaw = req.query.dayType ?? 'weekday';
  if (dayTypeRaw !== 'weekday' && dayTypeRaw !== 'weekend') {
    reply.code(400);
    return { error: "dayType must be 'weekday' or 'weekend'" };
  }

  const result = await planByHour({ fromLat, fromLon, toLat, toLon, dayType: dayTypeRaw });

  if (result.best === null) {
    reply.code(422);
    return { available: false, reason: result.unavailable?.reason ?? 'No route found.' };
  }

  const spread = result.worst!.totalMinutes - result.best.totalMinutes;

  return {
    available: true,
    dayType: result.dayType,
    best: result.best,
    worst: result.worst,
    // Only worth telling someone to shift their trip if the difference is
    // big enough to matter. Under five minutes is noise dressed as advice.
    advice: spread >= 5
      ? `Travelling around ${result.best.hourOfDay}:00 takes about ` +
        `${Math.round(spread)} minutes less than around ${result.worst!.hourOfDay}:00.`
      : 'This journey takes about the same time all day.',
    hours: result.hours,
    caveats: [
      'Service hours only (05:00-23:00 Delhi). Outside these, the feed has too little data to plan honestly.',
      'Frequencies are observed over one week, not scheduled.',
      result.dayType === 'weekend'
        ? 'Weekend figures rest on only two recorded weekend days.'
        : null,
    ].filter(Boolean),
  };
});

// ---------------------------------------------------------------------------
// GET /stops/near?lat=..&lon=..&radius=500 - stops near a point.
// Static GTFS, so this works with no live feed.
//
// Returns one row per PLACE, not per raw stop_id. Delhi's GTFS lists a
// separate stop_id for each direction of the same physical stop - left
// unmerged, a search near Connaught Place showed "Shivaji Stadium
// Terminal" twice and "Regal / Palika Kendra" twice, a few dozen metres
// apart, because that is genuinely two stop_ids at one place. journey.ts
// already solved this for routing (see stop_place / docs/journey-design.md
// section 3); this applies the same fix to plain stop search, which had
// been left showing the raw, duplicated list.
// ---------------------------------------------------------------------------
app.get<{
  Querystring: { lat?: string; lon?: string; radius?: string };
}>('/stops/near', async (req, reply) => {
  const lat = Number(req.query.lat);
  const lon = Number(req.query.lon);
  const radius = Number(req.query.radius ?? 500);

  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    reply.code(400);
    return { error: 'lat and lon are required. Example: /stops/near?lat=28.6315&lon=77.2167' };
  }

  const { rows } = await pool.query(
    `
    SELECT place_id, stop_id, stop_name, lat, lon, metres_away FROM (
      SELECT DISTINCT ON (sp.place_id)
             sp.place_id, s.stop_id, s.stop_name,
             s.stop_lat AS lat, s.stop_lon AS lon,
             -- Cast to int, not left as numeric: node-postgres returns
             -- numeric/decimal columns as STRINGS (it can't otherwise
             -- guarantee no precision is lost converting to a JS number),
             -- and that string survives straight into the JSON response -
             -- "metres_away": "420" instead of 420. Already rounded to a
             -- whole metre, so int loses nothing and fixes the type.
             round(ST_Distance(s.geom::geography,
                   ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography)::numeric, 0)::int AS metres_away
      FROM stops s
      JOIN stop_place sp ON sp.stop_id = s.stop_id
      WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
        AND ST_DWithin(s.geom::geography,
                       ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography, $3)
      -- nearest stop_id within each place wins - both its distance and its
      -- name are the ones shown, since that is the point closest to where
      -- the traveller is actually standing
      ORDER BY sp.place_id, metres_away
    ) nearest
    ORDER BY metres_away
    LIMIT 30
    `,
    [lat, lon, radius],
  );

  return { count: rows.length, radiusMetres: radius, stops: rows };
});

// ---------------------------------------------------------------------------
// GET /stops/search?q=connaught - find a stop/place by typed name.
// Static GTFS, so this works with no live feed. Same place-dedup idea as
// /stops/near (see its comment) - a name search on raw stop_id would show
// "Shivaji Stadium Terminal" twice just because Delhi's GTFS lists a
// separate stop_id per direction of the same physical stop.
// ---------------------------------------------------------------------------
app.get<{
  Querystring: { q?: string; limit?: string };
}>('/stops/search', async (req, reply) => {
  const q = (req.query.q ?? '').trim();
  const limit = Math.min(Number(req.query.limit ?? 10), 25);

  if (q.length < 2) {
    reply.code(400);
    return { error: 'q must be at least 2 characters' };
  }

  const { rows } = await pool.query(
    `
    SELECT place_id, stop_name, lat, lon FROM (
      SELECT DISTINCT ON (sp.place_id)
             sp.place_id, s.stop_name, s.stop_lat AS lat, s.stop_lon AS lon
      FROM stops s
      JOIN stop_place sp ON sp.stop_id = s.stop_id
      WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
        AND s.stop_name ILIKE '%' || $1 || '%'
      ORDER BY sp.place_id
    ) matched
    -- A name that STARTS WITH what was typed (e.g. "Shivaji..." for "sh")
    -- is almost always what someone means, even though a name with "sh"
    -- buried in the middle (e.g. "Keshav...") also technically matches.
    -- Show prefix matches first, then fall back to alphabetical.
    ORDER BY (stop_name ILIKE $1 || '%') DESC, stop_name
    LIMIT $2
    `,
    [q, limit],
  );

  return { count: rows.length, stops: rows };
});

// ---------------------------------------------------------------------------
// GET /routes/search?q=764 - find a route by its number.
// Static GTFS, so this works with no live feed. route_short_name carries
// direction as a suffix (e.g. "764UP" / "764DOWN" - see db/schema.sql), so
// searching "764" surfaces both directions as separate rows, which is
// correct: they are different stop sequences and a rider needs to pick
// the one going their way.
// ---------------------------------------------------------------------------
app.get<{
  Querystring: { q?: string; limit?: string };
}>('/routes/search', async (req, reply) => {
  const q = (req.query.q ?? '').trim();
  const limit = Math.min(Number(req.query.limit ?? 10), 25);

  if (q.length < 1) {
    reply.code(400);
    return { error: 'q must be at least 1 character' };
  }

  const { rows } = await pool.query(
    `
    SELECT route_id, route_short_name, route_desc, direction_tag
    FROM routes
    WHERE snapshot_id = (SELECT max(snapshot_id) FROM routes)
      AND route_short_name ILIKE '%' || $1 || '%'
    ORDER BY
      -- Someone typing "764" means route 764, not "764B" or "764STL" -
      -- Delhi's route numbers really do collide like that (764, 764B,
      -- 764BSTL, 764STL are four different routes). An exact number match
      -- (just the typed number plus the UP/DOWN suffix) beats every other
      -- prefix match, which would otherwise tie and fall back to
      -- alphabetical - putting "764B..." ahead of "764..." for a search
      -- of "764", which is backwards from what anyone means.
      CASE
        WHEN route_short_name ILIKE $1 || 'UP' OR route_short_name ILIKE $1 || 'DOWN' THEN 0
        WHEN route_short_name ILIKE $1 || '%' THEN 1
        ELSE 2
      END,
      route_short_name
    LIMIT $2
    `,
    [q, limit],
  );

  return { count: rows.length, routes: rows };
});

// ---------------------------------------------------------------------------
// GET /routes/:routeId/stops - the stops along a route, in order.
// Needed to turn "the stop I am standing at" into a position number.
//
// routeStops() lives in routes.ts now, because /routes/:id/detail needs the
// same ordered list. One query, one definition.
// ---------------------------------------------------------------------------
app.get<{ Params: { routeId: string } }>('/routes/:routeId/stops', async (req, reply) => {
  const stops = await routeStops(req.params.routeId);

  if (stops.length === 0) {
    reply.code(404);
    return { error: `no route ${req.params.routeId} in the current feed snapshot` };
  }

  return {
    route: req.params.routeId,
    stopCount: stops.length,
    // Keep the old snake_case shape here: the existing app and its tests
    // read these keys. /routes/:id/detail uses the camelCase objects
    // directly for the new screens.
    stops: stops.map((stop) => ({
      stop_sequence: stop.stopSequence,
      stop_id: stop.stopId,
      stop_name: stop.stopName,
      lat: stop.lat,
      lon: stop.lon,
      metres_along_route: stop.metresAlongRoute,
      has_timing: stop.hasTiming,
    })),
  };
});

// ---------------------------------------------------------------------------
// GET /feed/status - is the official feed live, and which days can be
// replayed? The app needs this before it can label anything honestly.
// ---------------------------------------------------------------------------
app.get('/feed/status', async () => {
  return feedStatus();
});

// ---------------------------------------------------------------------------
// GET /stops/:placeId/arrivals?at=..&windowMinutes=45&to=<destination place>
//
// Buses coming to one physical stop. With `at`, the answer is a replay of
// the recorded stop passages. Without it, the answer uses the newest
// non-empty official frame and any active passenger beacons. A route with
// no tracked bus gets a frequency row, never a made-up countdown.
//
// `to` is optional. When it is a place id, the board is narrowed to buses
// that reach that place after this stop WITHOUT a change, and each ETA then
// answers "when do I get to my destination" rather than "when does the bus
// get here". A destination no route reaches directly returns 200 with an
// empty board, `noDirect: true` and a caveat, never a fake bus.
// ---------------------------------------------------------------------------
app.get<{
  Params: { placeId: string };
  Querystring: { at?: string; windowMinutes?: string; to?: string };
}>('/stops/:placeId/arrivals', async (req, reply) => {
  const placeId = Number(req.params.placeId);
  if (!Number.isInteger(placeId) || placeId <= 0) {
    reply.code(400);
    return { error: 'placeId must be a positive whole number' };
  }

  let at: Date | null = null;
  if (req.query.at !== undefined && req.query.at !== '') {
    at = new Date(req.query.at);
    if (Number.isNaN(at.getTime())) {
      reply.code(400);
      return { error: 'at must be an ISO date, for example 2026-08-12T13:00:00Z' };
    }
  }

  const windowMinutes = Number(req.query.windowMinutes ?? 45);
  if (!Number.isFinite(windowMinutes) || windowMinutes < 5 || windowMinutes > 120) {
    reply.code(400);
    return { error: 'windowMinutes must be between 5 and 120' };
  }

  // Optional "Where to?" filter. A place id, like the path parameter, not a
  // raw stop id: the board works in physical places (see
  // db/schema_stop_places.sql). An explicit but empty `?to=` is refused
  // rather than quietly ignored - it is still a destination the caller asked
  // for but did not name.
  let to: number | null = null;
  if (req.query.to !== undefined) {
    to = Number(req.query.to);
    if (!Number.isInteger(to) || to <= 0) {
      reply.code(400);
      return { error: 'to must be a positive whole number place id' };
    }

    // An id that is not a place in the current snapshot is a client mistake,
    // not an empty board. Saying "no direct bus" about a place that does not
    // exist would be a made-up answer.
    const destination = await placeInfo(to);
    if (!destination) {
      reply.code(404);
      return { error: `no place ${to} in the current feed snapshot` };
    }
  }

  const result = await arrivalsForPlace(placeId, at, windowMinutes, to ?? undefined);
  if (!result) {
    reply.code(404);
    return { error: `no place ${placeId} in the current feed snapshot` };
  }

  return result;
});

// ---------------------------------------------------------------------------
// GET /routes/:routeId/detail?at=..&to=..
//
// Everything the route screen needs in one request: the route's name and
// destination, its shape, its ordered stops, the buses on it, and the ETA
// to one chosen stop. `to` is a stop sequence from the stops list.
// ---------------------------------------------------------------------------
app.get<{
  Params: { routeId: string };
  Querystring: { at?: string; to?: string };
}>('/routes/:routeId/detail', async (req, reply) => {
  let at: Date | null = null;
  if (req.query.at !== undefined && req.query.at !== '') {
    at = new Date(req.query.at);
    if (Number.isNaN(at.getTime())) {
      reply.code(400);
      return { error: 'at must be an ISO date, for example 2026-08-12T13:00:00Z' };
    }
  }

  let to: number | null = null;
  if (req.query.to !== undefined && req.query.to !== '') {
    to = Number(req.query.to);
    if (!Number.isInteger(to) || to < 0) {
      reply.code(400);
      return { error: 'to must be a whole stop sequence, for example 12' };
    }
  }

  const result = await routeDetail(req.params.routeId, at, to);
  if (!result) {
    reply.code(404);
    return { error: `no route ${req.params.routeId} in the current feed snapshot` };
  }

  return result;
});

// ---------------------------------------------------------------------------
// POST /crowdsource/ping - ingest passenger mobile telemetry.
//
// Accepts live onboard passenger mobile telemetry to keep active buses visible
// during official feed dropouts or unlisted trip runs.
// Applies physics & spatial plausibility filters (5-80 km/h, <= 50m off route).
// ---------------------------------------------------------------------------
app.post<{
  Body: {
    route_id?: string;
    routeId?: string;
    lat?: number;
    lon?: number;
    speed?: number;
    speedKmh?: number;
    timestamp?: string | number;
    device_id?: string;
    deviceId?: string;
  };
}>('/crowdsource/ping', async (req, reply) => {
  const body = req.body ?? {};
  const routeId = body.routeId ?? body.route_id;
  const lat = body.lat !== undefined ? Number(body.lat) : undefined;
  const lon = body.lon !== undefined ? Number(body.lon) : undefined;
  const speedKmh =
    body.speedKmh !== undefined
      ? Number(body.speedKmh)
      : body.speed !== undefined
        ? Number(body.speed)
        : undefined;
  const deviceId = body.deviceId ?? body.device_id;

  const user = await currentUser(req);
  const userId = user ? user.id : deviceId;

  if (!routeId || lat === undefined || lon === undefined || speedKmh === undefined) {
    reply.code(400);
    return {
      ok: false,
      error: 'route_id (or routeId), lat, lon, and speed (km/h) are required fields.',
    };
  }

  const result = await crowdsourceStore.ingest({
    routeId,
    lat,
    lon,
    speedKmh,
    timestamp: body.timestamp,
    userId,
    deviceId,
  });

  if (!result.ok) {
    reply.code(400);
    return { ok: false, error: result.reason, code: result.code };
  }

  return { ok: true, ping: result.ping };
});

// ---------------------------------------------------------------------------
// GET /routes/:id/crowdsourced - active crowdsourced vehicles on a route.
//
// Returns active vehicles imputed from passenger beacons with consensus confidence.
// ---------------------------------------------------------------------------
app.get<{
  Params: { id: string };
}>('/routes/:id/crowdsourced', async (req, _reply) => {
  const routeId = req.params.id;
  const vehicles = crowdsourceStore.getActiveVehicles(routeId);

  return {
    ok: true,
    routeId,
    count: vehicles.length,
    vehicles,
    provenance: 'crowdsourced-telemetry',
  };
});

// ---------------------------------------------------------------------------
// GET /location-proof?vehicleId=..&lat=..&lon=..&poiLat=..&poiLon=..&poiName=..
//                      &at=..&fault=..&offsetM=..
//
// The simulator/verifier demo: re-run the whole location-proof round for a
// position the caller chooses, optionally injecting one of the six paper
// faults and watching the checks reject it. The app's proof screen uses this
// to show the same verifier being beaten; curl uses it for the report.
//
// THE POI IS THE PAPER'S POINT OF INTEREST. Paul, Dhal and Mary (IEEE/ACM TON
// 32(3), 2024) run the protocol for one point of interest: Algorithm 1 picks
// the nearest satellite on each of its four sides, and the four-sphere
// solution is checked against the distance to it. So `poiLat`/`poiLon` are
// required - a fix with nothing to measure it against is not a proof - and
// `poiName` is optional only because the maths needs no label. In this app the
// POI is normally a bus stop.
//
// This is NOT an authentication boundary. Any caller may ask for any vehicle
// id and any coordinates, and the answer is always a SIMULATED proof: the
// satellite observables are generated here because the real feed publishes a
// bare position with no measurements and no signature. It says the pipeline
// works, not that a real Delhi bus was verified.
//
//   /location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165
//   /location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165&fault=spoof
//   /location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165&poiName=Shivaji%20Stadium&at=2026-08-16T13:30:00Z&offsetM=80
// ---------------------------------------------------------------------------
app.get<{
  Querystring: {
    vehicleId?: string;
    lat?: string;
    lon?: string;
    poiLat?: string;
    poiLon?: string;
    poiName?: string;
    at?: string;
    fault?: string;
    offsetM?: string;
  };
}>('/location-proof', async (req, reply) => {
  const vehicleId = (req.query.vehicleId ?? '').trim();
  if (vehicleId.length === 0) {
    reply.code(400);
    return { error: 'vehicleId is required and must not be empty.' };
  }

  // lat and lon are both required: the endpoint verifies a claim, so a
  // missing coordinate is a malformed request, not "use the bus's last spot".
  if (req.query.lat === undefined || req.query.lon === undefined) {
    reply.code(400);
    return {
      error: 'lat and lon are both required. Example: /location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090',
    };
  }
  const lat = Number(req.query.lat);
  const lon = Number(req.query.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    reply.code(400);
    return { error: 'lat and lon must both be numbers.' };
  }
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
    reply.code(400);
    return { error: 'latitude must be between -90 and 90, longitude between -180 and 180.' };
  }

  // The paper's point of interest is not optional: Algorithm 1 selects the
  // four satellites relative to it and every check measures the fix against
  // it. A caller who omits it gets a clear 400 rather than a proof whose
  // geometry would have to be invented.
  if (req.query.poiLat === undefined || req.query.poiLon === undefined) {
    reply.code(400);
    return {
      error:
        'poiLat and poiLon are both required: the paper verifies a fix against its point of interest. ' +
        'Example: /location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165',
    };
  }
  const poiLat = Number(req.query.poiLat);
  const poiLon = Number(req.query.poiLon);
  if (!Number.isFinite(poiLat) || !Number.isFinite(poiLon)) {
    reply.code(400);
    return { error: 'poiLat and poiLon must both be numbers.' };
  }
  if (poiLat < -90 || poiLat > 90 || poiLon < -180 || poiLon > 180) {
    reply.code(400);
    return { error: 'poiLat must be between -90 and 90, poiLon between -180 and 180.' };
  }
  const poiName = (req.query.poiName ?? '').trim();

  let fixAt = new Date();
  if (req.query.at !== undefined && req.query.at !== '') {
    fixAt = new Date(req.query.at);
    if (Number.isNaN(fixAt.getTime())) {
      reply.code(400);
      return { error: 'at must be a valid date, e.g. 2026-08-16T13:30:00Z' };
    }
  }

  // An unknown fault is a client mistake: refuse it rather than silently
  // verifying an honest fix, which would look like the verifier missed it.
  let fault: FaultMode = 'none';
  if (req.query.fault !== undefined && req.query.fault !== '') {
    try {
      fault = parseFaultMode(req.query.fault);
    } catch {
      reply.code(400);
      return {
        error: `unknown fault '${req.query.fault}'. Allowed: ${FAULT_MODES.map((mode) => mode.id).join(', ')}`,
      };
    }
  }

  // A route offset is optional; when given it must be a real distance.
  let offsetM: number | null = null;
  if (req.query.offsetM !== undefined && req.query.offsetM !== '') {
    offsetM = Number(req.query.offsetM);
    if (!Number.isFinite(offsetM)) {
      reply.code(400);
      return { error: 'offsetM must be a number of metres.' };
    }
  }

  const proof = buildLocationProof({
    vehicleId,
    position: { lat, lon, altM: DEMO_ALTITUDE_M },
    poi: { lat: poiLat, lon: poiLon, altM: DEMO_ALTITUDE_M },
    poiName: poiName.length > 0 ? poiName : null,
    fixAt,
    fault,
    routeOffsetM: offsetM,
  });

  return { ok: true, proof };
});

// ---------------------------------------------------------------------------
// GET /relay-selection?placeId=..&at=..   (or ?lat=..&lon=..&at=..)
//
// The paper's other job: which vehicle at an intersection can honestly relay
// the trusted authority's messages? Algorithm 2 measures every candidate's
// distance D to the point of interest from the four-sphere solution, Algorithm
// 3 checks that D closes its triangle, and the nearest VERIFIED vehicle is
// selected. A spoofing bus is rejected by its own proof before ranking, so it
// can never become the relay.
//
// Here the "intersection" is a bus stop, and the candidates are the buses the
// stop board already shows for that place and moment. Their recorded fixes are
// the input: the raw fix the feed published when there is one, otherwise the
// point the row is snapped to along its route. The endpoint is deliberately
// just composition - the board logic and the protocol engine each have their
// own checks, and nothing is re-derived here.
//
// SIMULATED, and labelled so in the app: the four satellites and their
// timestamps are generated because this project has no receiver hardware and
// no satellite link. The ECDSA signatures, the RSA challenge echoes and every
// check are real, so an injected fault really is rejected - it is the sky's
// geometry that is simulated, not the verification. The response carries that
// caveat itself so a client cannot show the selection without it.
//
//   /relay-selection?placeId=572&at=2026-08-16T08:00:00Z
//   /relay-selection?lat=28.6323&lon=77.2165&at=2026-08-16T08:00:00Z
// ---------------------------------------------------------------------------

/** How far from bare coordinates the endpoint looks for the point of interest. */
const RELAY_PLACE_RADIUS_M = 1500;

/**
 * The fix a relay candidate is measured from, or null when the row has none.
 *
 * Preferences, in order: the raw fix the bus actually reported (that is what
 * the proof is about), then the snapped point on the route line (a replay row
 * is placed by interpolating recorded passages, so this is the best available
 * position). Never mix the two: a raw latitude paired with a snapped longitude
 * would describe a point the bus was never at.
 */
function fixForRelayCandidate(arrival: Arrival): { lat: number; lon: number } | null {
  const match = arrival.match;
  if (!match) return null;

  if (match.rawLat !== null && match.rawLon !== null) {
    return { lat: match.rawLat, lon: match.rawLon };
  }
  if (match.snappedLat !== null && match.snappedLon !== null) {
    return { lat: match.snappedLat, lon: match.snappedLon };
  }
  return null;
}

/**
 * Turn one stop board into the paper's candidate list.
 *
 * A candidate needs a real coordinate and a fix time; rows without either are
 * skipped rather than placed at (0, 0). The paper ranks vehicles, so there is
 * one entry per (route, vehicle) even if the board ever listed a bus twice.
 */
function relayCandidatesFromBoard(board: ArrivalsResult): RelayVehicleInput[] {
  const candidates: RelayVehicleInput[] = [];
  const seen = new Set<string>();

  for (const arrival of board.arrivals) {
    const fix = fixForRelayCandidate(arrival);
    if (!fix) continue;

    const key = `${arrival.routeId}|${arrival.vehicleId}`;
    if (seen.has(key)) continue;
    seen.add(key);

    candidates.push({
      vehicleId: arrival.vehicleId,
      routeId: arrival.routeId,
      routeNumber: arrival.routeNumber,
      position: { lat: fix.lat, lon: fix.lon, altM: DEMO_ALTITUDE_M },
      fixAt: new Date(arrival.recordedAt),
    });
  }

  return candidates;
}

app.get<{
  Querystring: {
    placeId?: string;
    lat?: string;
    lon?: string;
    at?: string;
    /** Demo hook: inject one paper attack into one candidate's exchange. */
    faultVehicle?: string;
    fault?: string;
  };
}>('/relay-selection', async (req, reply) => {
  // The replay moment. Optional, like the arrivals endpoint: with `at` the
  // candidates are replayed from recorded stop passages, without it the board
  // is whatever the newest feed and passenger beacons can honestly offer.
  let at: Date | null = null;
  if (req.query.at !== undefined && req.query.at !== '') {
    at = new Date(req.query.at);
    if (Number.isNaN(at.getTime())) {
      reply.code(400);
      return { error: 'at must be an ISO date, for example 2026-08-16T08:00:00Z' };
    }
  }

  // The point of interest: a place id when one is known (preferred, because it
  // is exactly what the board and search use), otherwise the nearest place to
  // a bare coordinate. Both forms resolve to one physical stop, so the
  // selection is the same however the caller asked for it.
  let place: PlaceInfo | null = null;
  if (req.query.placeId !== undefined && req.query.placeId !== '') {
    const placeId = Number(req.query.placeId);
    if (!Number.isInteger(placeId) || placeId <= 0) {
      reply.code(400);
      return { error: 'placeId must be a positive whole number' };
    }

    place = await placeInfo(placeId);
    if (!place) {
      reply.code(404);
      return { error: `no place ${placeId} in the current feed snapshot` };
    }
  } else {
    // A bare coordinate form: lat and lon are a pair, so one without the other
    // is a malformed request rather than a place to guess.
    if (req.query.lat === undefined || req.query.lon === undefined) {
      reply.code(400);
      return {
        error:
          'either placeId, or both lat and lon, must be given. ' +
          'Example: /relay-selection?placeId=572&at=2026-08-16T08:00:00Z',
      };
    }
    const lat = Number(req.query.lat);
    const lon = Number(req.query.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      reply.code(400);
      return { error: 'lat and lon must both be numbers.' };
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      reply.code(400);
      return { error: 'latitude must be between -90 and 90, longitude between -180 and 180.' };
    }

    place = await nearestPlace(lat, lon, RELAY_PLACE_RADIUS_M);
    if (!place) {
      reply.code(404);
      return {
        error: `no place within ${RELAY_PLACE_RADIUS_M} m of lat=${lat}, lon=${lon} in the current feed snapshot`,
      };
    }

    // Normalise through placeInfo() so the coordinate form gives exactly the
    // same POI, and therefore the same selection, as the placeId form: the
    // spatial search returns the stop nearest the caller, while a place has
    // one representative row that the rest of the API uses for its name and
    // coordinate. Without this the two forms would differ by a few dozen
    // metres on the same physical stop.
    place = (await placeInfo(place.placeId)) ?? place;
  }

  const board = await arrivalsForPlace(place.placeId, at);
  if (!board) {
    // placeInfo() just resolved this id, so this only happens if the static
    // snapshot changes under the request - answer 404, not a crash.
    reply.code(404);
    return { error: `no place ${place.placeId} in the current feed snapshot` };
  }

  const vehicles = relayCandidatesFromBoard(board);

  // Optional demo hook: mark one candidate with one of the paper's attacks, so
  // the relay screen can show live that a lying nearest bus is rejected and the
  // next verified bus takes over. Both parameters must come together; the
  // default run is untouched.
  let faults: Record<string, FaultMode> | undefined;
  const demoFaultVehicle = (req.query.faultVehicle ?? '').trim();
  const demoFaultRaw = (req.query.fault ?? '').trim();
  if (demoFaultVehicle !== '' || demoFaultRaw !== '') {
    if (demoFaultVehicle === '' || demoFaultRaw === '') {
      reply.code(400);
      return { error: 'faultVehicle and fault must be given together.' };
    }
    if (!vehicles.some((vehicle) => vehicle.vehicleId === demoFaultVehicle)) {
      reply.code(400);
      return {
        error: `faultVehicle '${demoFaultVehicle}' is not one of the buses this relay selection is choosing between.`,
      };
    }
    let fault: FaultMode;
    try {
      fault = parseFaultMode(demoFaultRaw);
    } catch (error) {
      reply.code(400);
      return { error: (error as Error).message };
    }
    if (fault === 'none') {
      reply.code(400);
      return { error: "fault must be one of the six simulated attacks, not 'none'." };
    }
    faults = { [demoFaultVehicle]: fault };
  }

  const relay = selectRelayVehicle({
    poi: { lat: place.lat, lon: place.lon, altM: DEMO_ALTITUDE_M },
    poiName: place.name,
    vehicles,
    faults,
  });

  return {
    ok: true,
    relay,
    demoFault:
      faults === undefined
        ? null
        : { vehicleId: demoFaultVehicle, fault: Object.values(faults)[0] },
  };
});

const port = Number(process.env.PORT ?? 3000);


app.listen({ port, host: '0.0.0.0' })
  .then(() => app.log.info(`where-is-my-bus api on :${port}`))
  .catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
