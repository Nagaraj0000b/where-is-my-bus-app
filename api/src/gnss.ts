// The four-satellite geometry of the paper, implemented as written.
//
// THE PAPER
//
// Paul, Dhal & Mary, "Relaying Vehicle Selection Protocol for a Road
// Intersection", IEEE/ACM Transactions on Networking 32(3), 2024.
//
// Its trusted side is four satellites: the nearest satellite on the EAST,
// WEST, NORTH and SOUTH side of the point of interest (POI). The paper calls
// them S_E, S_W, S_N and S_S and their distances from the POI Y_E, Y_W, Y_N
// and Y_S (Algorithm 1). A satellite timestamps the challenge and the reply;
// the trusted authority turns the round-trip time into a range with
//
//     Rad = C * (T_Y - T_X) / (2 * N * lambda)          (Algorithm 2, step 17)
//
// and solves the four sphere equations
//
//     (x-a_i)^2 + (y-b_i)^2 + (z-c_i)^2 - Rad_i^2 = 0   (equations 1-4)
//
// for the vehicle position (x,y,z). Algorithm 3 then checks the result with
// direction ratios and the triangle law of cosines:
//
//     L1 = x-g, M1 = y-h, N1 = z-i                     (POI g,h,i)
//     L2 = x-a1, M2 = y-b1, N2 = z-c1
//     cos(theta) = |L1*L2 + M1*M2 + N1*N2| / (|L1| * |L2|)   (equations 5-10)
//     Y_new = sqrt(Z1^2 + Z2^2 - 2*Z1*Z2*cos(theta))    (equation 11)
//
// and compares Y_new with the Y the authority already knows.
//
// WHAT IS SIMULATED, AND WHAT THIS FILE IS HONEST ABOUT
//
// The paper assumes geostationary satellites "on the East, West, North and
// South side" of the intersection. A real geostationary orbit above the
// equator cannot place a satellite north of Delhi, so the four-side geometry
// is the paper's model assumption, not real orbital mechanics. We reproduce
// that model: twelve candidate satellites at the paper's 36,000 km scale,
// three per side, with slightly different positions so Algorithm 1 really has
// to pick the nearest one per side. The four chosen coordinates and the Y_E,
// Y_W, Y_N, Y_S values that come out of Algorithm 1 are what the rest of the
// protocol uses - exactly as the paper describes.
//
// Every number below comes from the paper's symbols. This file does no
// cryptography; api/src/location_proof.ts runs the message flow.

export interface GeoPoint {
  lat: number;
  lon: number;
  altM: number;
}

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

/** The four sides of the point of interest used by Algorithm 1. */
export type Side = 'E' | 'W' | 'N' | 'S';

export const SIDES: Side[] = ['E', 'W', 'N', 'S'];

/** Satellite coordinate (a, b, c) at the fix time. */
export interface Satellite {
  id: string;
  prn: number;
  side: Side;
  ecef: Vec3;
}

/** One row of Algorithm 1: the nearest satellite of one side. */
export interface SideSelection {
  side: Side;
  satellite: Satellite;
  /** The paper's Y_E / Y_W / Y_N / Y_S: distance from satellite to POI. */
  distanceToPoiM: number;
  /** How many candidates existed on this side (3 in this simulation). */
  candidatesConsidered: number;
}

export interface FourSphereSolution {
  point: GeoPoint;
  ecef: Vec3;
  /** max | |P - C_i| - Rad_i |, in metres. Zero for perfect data. */
  residualM: number;
  /** False when the linear system (equations 1-4 linearised) is singular. */
  solved: boolean;
}

/** One side of Algorithm 3 (equations 5-11). */
export interface Algorithm3Side {
  side: Side;
  /** Z1: distance from the solved vehicle position to the POI. */
  z1M: number;
  /** Z2: distance from the solved vehicle position to the satellite. */
  z2M: number;
  /** Angle between the two lines of equations (5) and (7), in degrees. */
  angleDeg: number;
  /** Y known to the authority from Algorithm 1. */
  yeKnownM: number;
  /** Y recomputed from the vehicle data with equation (11). */
  yeComputedM: number;
  differenceM: number;
  passed: boolean;
}

export interface Algorithm3Result {
  sides: Algorithm3Side[];
  maxDifferenceM: number;
  toleranceM: number;
  passed: boolean;
}

// ---------------------------------------------------------------------------
// Constants from the paper / its physical setting
// ---------------------------------------------------------------------------

export const SPEED_OF_LIGHT = 299792458;

/** The paper's satellites are geostationary, about 36,000 km above the ground. */
export const GEO_ALTITUDE_M = 36_000_000;
const EARTH_RADIUS_M = 6378137;
const ORBIT_RADIUS_M = EARTH_RADIUS_M + GEO_ALTITUDE_M;

const WGS84_F = 1 / 298.257223563;
const WGS84_E2 = WGS84_F * (2 - WGS84_F);

/**
 * Engineering tolerance for Algorithm 3 step 5 / equation (11), in metres.
 *
 * The paper says "if Y_new != Y exit"; with real numbers that can never be an
 * exact equality, so a tolerance is needed. 500 m is far below the errors a
 * falsified position or an inflated round-trip produces (kilometres), while
 * an honest solve agrees to a few metres.
 */
export const RANGE_TOLERANCE_M = 500;

/** Per-side base offsets and candidate spread of the simulated constellation. */
const SIDE_BASE_SCALE: Record<Side, number> = { E: 0.55, W: 0.70, N: 0.60, S: 0.75 };
const CANDIDATE_SCALE_STEPS = [0, 0.05, 0.10];
const CANDIDATE_AZIMUTH_STEPS = [0, 5, -5];

// ---------------------------------------------------------------------------
// Geographic <-> Earth-centred coordinates (same WGS84 conversions as before)
// ---------------------------------------------------------------------------

export function geoToEcef(point: GeoPoint): Vec3 {
  const lat = (point.lat * Math.PI) / 180;
  const lon = (point.lon * Math.PI) / 180;
  const sinLat = Math.sin(lat);
  const cosLat = Math.cos(lat);
  const n = EARTH_RADIUS_M / Math.sqrt(1 - WGS84_E2 * sinLat * sinLat);
  const height = point.altM ?? 0;
  return {
    x: (n + height) * cosLat * Math.cos(lon),
    y: (n + height) * cosLat * Math.sin(lon),
    z: (n * (1 - WGS84_E2) + height) * sinLat,
  };
}

export function ecefToGeo(v: Vec3): GeoPoint {
  const lon = Math.atan2(v.y, v.x);
  const p = Math.sqrt(v.x * v.x + v.y * v.y);

  let lat = Math.atan2(v.z, p * (1 - WGS84_E2));
  let height = 0;
  for (let i = 0; i < 6; i++) {
    const sinLat = Math.sin(lat);
    const n = EARTH_RADIUS_M / Math.sqrt(1 - WGS84_E2 * sinLat * sinLat);
    height = p / Math.cos(lat) - n;
    lat = Math.atan2(v.z, p * (1 - (WGS84_E2 * n) / (n + height)));
  }
  return {
    lat: (lat * 180) / Math.PI,
    lon: (lon * 180) / Math.PI,
    altM: height,
  };
}

/** Great-circle distance in metres. */
export function distanceMeters(a: GeoPoint, b: GeoPoint): number {
  const r = 6371000;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLon = ((b.lon - a.lon) * Math.PI) / 180;
  const h =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((a.lat * Math.PI) / 180) *
      Math.cos((b.lat * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  return r * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

/** Straight-line distance between two Earth-centred points, in metres. */
function distanceVec(a: Vec3, b: Vec3): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  const dz = a.z - b.z;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

/** The local East/North/Up unit vectors at a point, in ECEF. */
function localBasis(point: GeoPoint): { east: Vec3; north: Vec3; up: Vec3 } {
  const lat = (point.lat * Math.PI) / 180;
  const lon = (point.lon * Math.PI) / 180;
  const sinLat = Math.sin(lat);
  const cosLat = Math.cos(lat);
  const sinLon = Math.sin(lon);
  const cosLon = Math.cos(lon);
  return {
    east: { x: -sinLon, y: cosLon, z: 0 },
    north: { x: -sinLat * cosLon, y: -sinLat * sinLon, z: cosLat },
    up: { x: cosLat * cosLon, y: cosLat * sinLon, z: sinLat },
  };
}

function scale(v: Vec3, factor: number): Vec3 {
  return { x: v.x * factor, y: v.y * factor, z: v.z * factor };
}

function add(a: Vec3, b: Vec3): Vec3 {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

function norm(v: Vec3): number {
  return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

// ---------------------------------------------------------------------------
// Algorithm 1: the twelve candidates and the four nearest satellites
// ---------------------------------------------------------------------------

/**
 * Twelve simulated satellite positions at the paper's geostationary scale.
 *
 * Three candidates per side, each slightly further from the POI than the last
 * one, plus a small azimuth wobble. That gives Algorithm 1 an actual choice to
 * make: only the nearest of each side is accepted downstream.
 *
 * The positions are fixed (geostationary satellites do not move relative to
 * the ground), so this function needs no time.
 */
export function satelliteCandidates(poi: GeoPoint): Satellite[] {
  const poiEcef = geoToEcef(poi);
  const radial = scale(poiEcef, 1 / norm(poiEcef));
  const basis = localBasis(poi);

  const horizontal: Record<Side, Vec3> = {
    E: basis.east,
    W: scale(basis.east, -1),
    N: basis.north,
    S: scale(basis.north, -1),
  };

  const satellites: Satellite[] = [];
  const prnBase: Record<Side, number> = { E: 101, W: 111, N: 121, S: 131 };
  let prn = 0;

  for (const side of SIDES) {
    const baseSide = horizontal[side];
    for (let candidate = 0; candidate < 3; candidate++) {
      const scaleOffset = SIDE_BASE_SCALE[side] + CANDIDATE_SCALE_STEPS[candidate];
      const azimuthDeg = CANDIDATE_AZIMUTH_STEPS[candidate];
      // Rotate the horizontal side direction by the candidate's wobble.
      const wobble = (azimuthDeg * Math.PI) / 180;
      const sideDir = {
        x: baseSide.x * Math.cos(wobble) - basis.up.x * Math.sin(wobble),
        y: baseSide.y * Math.cos(wobble) - basis.up.y * Math.sin(wobble),
        z: baseSide.z * Math.cos(wobble) - basis.up.z * Math.sin(wobble),
      };
      // Satellite sits mostly radially outward, tilted towards its side, at
      // the geostationary orbital radius.
      const direction = scale(add(radial, scale(sideDir, scaleOffset)), 1);
      const unit = scale(direction, 1 / norm(direction));
      const ecef = scale(unit, ORBIT_RADIUS_M);
      prn = prnBase[side] + candidate;
      satellites.push({ id: `GEO-${side}${candidate + 1}`, prn, side, ecef });
    }
  }

  return satellites;
}

/**
 * Algorithm 1, verbatim: compute every satellite's distance from the POI,
 * keep the minimum on each side (Y_E, Y_W, Y_N, Y_S), and record the
 * coordinates of those four satellites (S_E, S_W, S_N, S_S).
 */
export function selectNearestSatellites(poi: GeoPoint): {
  sides: SideSelection[];
  candidates: Satellite[];
} {
  const candidates = satelliteCandidates(poi);
  const poiEcef = geoToEcef(poi);

  const sides: SideSelection[] = [];
  for (const side of SIDES) {
    const ofSide = candidates.filter((candidate) => candidate.side === side);
    let best: { satellite: Satellite; distance: number } | null = null;
    for (const satellite of ofSide) {
      const distance = distanceVec(satellite.ecef, poiEcef);
      if (best === null || distance < best.distance) {
        best = { satellite, distance };
      }
    }
    if (best === null) throw new Error(`no satellite candidate on side ${side}`);
    sides.push({
      side,
      satellite: best.satellite,
      distanceToPoiM: best.distance,
      candidatesConsidered: ofSide.length,
    });
  }

  return { sides, candidates };
}

// ---------------------------------------------------------------------------
// Algorithm 2: timestamps into a range (Rad)
// ---------------------------------------------------------------------------

/**
 * The paper's range formula, Algorithm 2 step 17:
 *   Rad = C * (T_Y - T_X) / (2 * N * lambda)
 *
 * The timestamps are integer nanoseconds relative to the session's T_SAT, not
 * epoch milliseconds: epoch milliseconds (~1.8e12) cannot hold nanosecond
 * precision in a double, so subtracting them would lose the very signal the
 * paper depends on. T_X/T_Y are still recorded per satellite as required; only
 * their representation inside the verifier is relative.
 *
 * N*lambda is the paper's propagation correction factor; the simulation uses 1
 * so an honest timestamp pair gives exactly the geometric range. A malicious
 * delay is added to T_Y and therefore really inflates Rad.
 */
export function radFromTimestamps(txNs: number, tyNs: number, nLambda = 1): number {
  return (SPEED_OF_LIGHT * (tyNs - txNs)) / (1e9 * 2 * nLambda);
}

/**
 * Small deterministic noise on the range, in metres. Same seed -> same noise.
 */
function seededRangeNoiseM(seedText: string): number {
  let hash = 2166136261;
  for (let i = 0; i < seedText.length; i++) {
    hash ^= seedText.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  hash >>>= 0;
  return (hash % 3001) / 1000 - 1.5; // [-1.5, +1.5] m
}

/**
 * Simulate one satellite's round trip for one vehicle.
 *
 * T_X is when that satellite broadcast its random value; T_Y is when the
 * reply reached it again. For an honest vehicle the gap is exactly
 * 2 * range / C plus a little timestamp noise. `delayNs` is the paper's
 * "vehicle delays the response" attack: T_Y arrives later, Rad is too large,
 * and the four-sphere solve is inconsistent.
 *
 * Returns both the integer nanosecond pair used for the arithmetic (relative
 * to T_SAT) and the ISO strings included in the signed Info message.
 */
export function simulateTimestamps(
  satellite: Satellite,
  vehicle: GeoPoint,
  challengeTxMs: number,
  options: { delayNs?: number; seed?: string } = {},
): {
  txMs: number;
  tyMs: number;
  txNs: number;
  tyNs: number;
  rttNs: number;
  radM: number;
  tx: string;
  ty: string;
} {
  const rangeM = distanceVec(satellite.ecef, geoToEcef(vehicle));
  const noiseNs = Math.round((2 * seededRangeNoiseM(options.seed ?? satellite.id) * 1e9) / SPEED_OF_LIGHT);
  const rttNs = Math.round((2 * rangeM * 1e9) / SPEED_OF_LIGHT) + noiseNs + (options.delayNs ?? 0);
  const txNs = 0;
  const tyNs = rttNs;
  const radM = radFromTimestamps(txNs, tyNs, 1);
  const txMs = challengeTxMs + txNs / 1e6;
  const tyMs = challengeTxMs + tyNs / 1e6;

  return {
    txMs,
    tyMs,
    txNs,
    tyNs,
    rttNs,
    radM,
    tx: new Date(txMs).toISOString(),
    ty: new Date(tyMs).toISOString(),
  };
}

// ---------------------------------------------------------------------------
// Algorithm 2, step 21: solve equations (1)-(4)
// ---------------------------------------------------------------------------

/** Invert a small square matrix by Gauss-Jordan with partial pivoting. */
function invertMatrix(matrix: number[][]): number[][] | null {
  const size = matrix.length;
  const work = matrix.map((row, index) => [
    ...row,
    ...Array.from({ length: size }, (_, column) => (column === index ? 1 : 0)),
  ]);

  for (let column = 0; column < size; column++) {
    let pivotRow = column;
    for (let row = column + 1; row < size; row++) {
      if (Math.abs(work[row][column]) > Math.abs(work[pivotRow][column])) {
        pivotRow = row;
      }
    }
    if (Math.abs(work[pivotRow][column]) < 1e-12) return null;
    [work[column], work[pivotRow]] = [work[pivotRow], work[column]];

    const pivot = work[column][column];
    for (let k = 0; k < size * 2; k++) work[column][k] /= pivot;

    for (let row = 0; row < size; row++) {
      if (row === column) continue;
      const factor = work[row][column];
      if (factor === 0) continue;
      for (let k = 0; k < size * 2; k++) work[row][k] -= factor * work[column][k];
    }
  }

  return work.map((row) => row.slice(size));
}

/**
 * Solve equations (1)-(4) exactly as the paper states them.
 *
 * Subtracting equation (1) from equations (2)-(4) removes every squared term
 * and leaves three linear equations in (x, y, z); solving that 3x3 gives the
 * point the four spheres share (the radical centre). Coordinates are centred
 * and scaled around the satellite constellation before solving, so the huge
 * geostationary numbers do not lose precision.
 */
export function solveFourSpheres(
  satellites: Satellite[],
  radiiM: number[],
  poi: GeoPoint,
): FourSphereSolution {
  if (satellites.length !== 4 || radiiM.length !== 4) {
    throw new Error('four satellites and four ranges are required (equations 1-4)');
  }

  // Work relative to the constellation centre and in units of its own size.
  const centre: Vec3 = {
    x: (satellites[0].ecef.x + satellites[1].ecef.x + satellites[2].ecef.x + satellites[3].ecef.x) / 4,
    y: (satellites[0].ecef.y + satellites[1].ecef.y + satellites[2].ecef.y + satellites[3].ecef.y) / 4,
    z: (satellites[0].ecef.z + satellites[1].ecef.z + satellites[2].ecef.z + satellites[3].ecef.z) / 4,
  };
  const sizeM = Math.max(...satellites.map((satellite) => distanceVec(satellite.ecef, centre)));
  const scaledCentres = satellites.map((satellite) => scale(
    { x: satellite.ecef.x - centre.x, y: satellite.ecef.y - centre.y, z: satellite.ecef.z - centre.z },
    1 / sizeM,
  ));
  const scaledRadii = radiiM.map((radius) => radius / sizeM);

  // Equation (i) minus equation (0), in scaled units:
  //   A*x + B*y + C*z = D  (the paper's equations 1-4, linearised)
  const matrix: number[][] = [];
  const right: number[] = [];
  const base = scaledCentres[0];
  const baseRadius = scaledRadii[0];
  for (let i = 1; i < 4; i++) {
    const centreI = scaledCentres[i];
    const a = centreI.x - base.x;
    const b = centreI.y - base.y;
    const c = centreI.z - base.z;
    matrix.push([2 * a, 2 * b, 2 * c]);
    right.push(
      a * a + b * b + c * c -
        (scaledRadii[i] * scaledRadii[i] - baseRadius * baseRadius),
    );
  }

  const inverse = invertMatrix(matrix);
  if (inverse === null) {
    return { point: poi, ecef: geoToEcef(poi), residualM: Number.POSITIVE_INFINITY, solved: false };
  }
  const relative = [0, 0, 0].map((_, row) =>
    inverse[row][0] * right[0] + inverse[row][1] * right[1] + inverse[row][2] * right[2],
  );
  // The linear system is written relative to satellite 0 (the base sphere),
  // so put that satellite's position back.
  const solvedEcef: Vec3 = {
    x: satellites[0].ecef.x + relative[0] * sizeM,
    y: satellites[0].ecef.y + relative[1] * sizeM,
    z: satellites[0].ecef.z + relative[2] * sizeM,
  };

  // How well the four equations are actually satisfied (the paper's step 21
  // has no residual, but a real solver needs to report its error).
  let residualM = 0;
  for (let i = 0; i < 4; i++) {
    const error = Math.abs(distanceVec(solvedEcef, satellites[i].ecef) - radiiM[i]);
    residualM = Math.max(residualM, error);
  }

  const point = ecefToGeo(solvedEcef);
  return { point, ecef: solvedEcef, residualM, solved: Number.isFinite(point.lat) };
}

// ---------------------------------------------------------------------------
// Algorithm 3: direction ratios, angle, equation (11)
// ---------------------------------------------------------------------------

/**
 * Algorithm 3 for all four sides.
 *
 * For each side: direction ratios from the POI to the solved vehicle position
 * (L1, M1, N1) and from the satellite to the solved position (L2, M2, N2); the
 * angle between those lines with the cosine formula (equation 9); then the
 * law-of-cosines recomputation of the satellite-to-POI distance (equation 11).
 * The recomputed Y must match the Y that Algorithm 1 already gave the
 * authority, or the vehicle's data is rejected.
 */
export function algorithm3Check(
  solved: GeoPoint,
  poi: GeoPoint,
  selections: SideSelection[],
  radiiM: number[],
): Algorithm3Result {
  const solvedEcef = geoToEcef(solved);
  const poiEcef = geoToEcef(poi);
  void radiiM; // the ranges already did their work in the four-sphere solve

  const sides: Algorithm3Side[] = [];
  for (const selection of selections) {
    const satelliteEcef = selection.satellite.ecef;
    const l1: Vec3 = {
      x: solvedEcef.x - poiEcef.x,
      y: solvedEcef.y - poiEcef.y,
      z: solvedEcef.z - poiEcef.z,
    };
    const l2: Vec3 = {
      x: solvedEcef.x - satelliteEcef.x,
      y: solvedEcef.y - satelliteEcef.y,
      z: solvedEcef.z - satelliteEcef.z,
    };
    const z1M = norm(l1);
    const z2M = norm(l2);
    // Equation (9): cos(theta) from the two direction vectors.
    const dot = l1.x * l2.x + l1.y * l2.y + l1.z * l2.z;
    const cosTheta = z1M === 0 || z2M === 0 ? 1 : Math.max(-1, Math.min(1, dot / (z1M * z2M)));
    const angleDeg = (Math.acos(cosTheta) * 180) / Math.PI;

    // Equation (11): Y_new = sqrt(Z1^2 + Z2^2 - 2*Z1*Z2*cos(theta))
    const yeComputedM = Math.sqrt(
      Math.max(0, z1M * z1M + z2M * z2M - 2 * z1M * z2M * cosTheta),
    );
    const yeKnownM = selection.distanceToPoiM;
    const differenceM = Math.abs(yeComputedM - yeKnownM);

    sides.push({
      side: selection.side,
      z1M,
      z2M,
      angleDeg,
      yeKnownM,
      yeComputedM,
      differenceM,
      passed: differenceM <= RANGE_TOLERANCE_M,
    });
  }

  const maxDifferenceM = Math.max(...sides.map((side) => side.differenceM));
  return {
    sides,
    maxDifferenceM,
    toleranceM: RANGE_TOLERANCE_M,
    passed: sides.every((side) => side.passed),
  };
}

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

/** Elevation, azimuth and range from a ground point to each satellite. */
export function lookAngles(
  point: GeoPoint,
  satellites: Satellite[],
): { elevationDeg: number; azimuthDeg: number; rangeM: number }[] {
  const receiver = geoToEcef(point);
  const basis = localBasis(point);
  return satellites.map((satellite) => {
    const line = {
      x: satellite.ecef.x - receiver.x,
      y: satellite.ecef.y - receiver.y,
      z: satellite.ecef.z - receiver.z,
    };
    const rangeM = norm(line);
    const unit = scale(line, 1 / rangeM);
    const up = unit.x * basis.up.x + unit.y * basis.up.y + unit.z * basis.up.z;
    const east = unit.x * basis.east.x + unit.y * basis.east.y + unit.z * basis.east.z;
    const north = unit.x * basis.north.x + unit.y * basis.north.y + unit.z * basis.north.z;
    return {
      elevationDeg: (Math.asin(Math.max(-1, Math.min(1, up))) * 180) / Math.PI,
      azimuthDeg: ((Math.atan2(east, north) * 180) / Math.PI + 360) % 360,
      rangeM,
    };
  });
}

/**
 * DOP figures for the four satellites (the usual satellite-geometry quality
 * numbers). Needed for the proof's "how well was the sky arranged" line; the
 * paper itself does not use DOP, so it is optional information only.
 */
export function dopFigures(
  satellites: Satellite[],
  point: GeoPoint,
): { hdop: number; vdop: number; gdop: number } {
  const basis = localBasis(point);
  const receiver = geoToEcef(point);
  const rows: number[][] = [];
  for (const satellite of satellites) {
    const line = {
      x: satellite.ecef.x - receiver.x,
      y: satellite.ecef.y - receiver.y,
      z: satellite.ecef.z - receiver.z,
    };
    const rangeM = norm(line);
    const unit = scale(line, 1 / rangeM);
    rows.push([
      -(unit.x * basis.east.x + unit.y * basis.east.y + unit.z * basis.east.z),
      -(unit.x * basis.north.x + unit.y * basis.north.y + unit.z * basis.north.z),
      -(unit.x * basis.up.x + unit.y * basis.up.y + unit.z * basis.up.z),
      1,
    ]);
  }

  const normal = [
    [0, 0, 0, 0],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
  ];
  for (const row of rows) {
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) normal[i][j] += row[i] * row[j];
    }
  }
  const inverse = invertMatrix(normal);
  if (inverse === null) {
    return { hdop: Number.POSITIVE_INFINITY, vdop: Number.POSITIVE_INFINITY, gdop: Number.POSITIVE_INFINITY };
  }

  const variance = (index: number) => Math.max(0, inverse[index][index]);
  return {
    hdop: Math.sqrt(variance(0) + variance(1)),
    vdop: Math.sqrt(variance(2)),
    gdop: Math.sqrt(variance(0) + variance(1) + variance(2) + variance(3)),
  };
}

/** Convenience wrapper used by the proof: horizontal DOP only. */
export function horizontalDop(satellites: Satellite[], point: GeoPoint): number {
  return dopFigures(satellites, point).hdop;
}
