// The paper's secure location protocol, run for one reported bus position.
//
// THE PAPER
//
// Paul, Dhal & Mary, "Relaying Vehicle Selection Protocol for a Road
// Intersection", IEEE/ACM Transactions on Networking 32(3), 2024.
//
// Trusted Authority (TA), four satellites - the nearest on the East, West,
// North and South sides of the point of interest (Algorithm 1) - and an
// untrusted vehicle. The TA:
//
//   1. accepts only those four satellite IDs, and only if the signed info is
//      fresh: (Current_TA - T_SAT) <= delta_T            Algorithm 2, 9-15
//   2. verifies each satellite's digital signature over
//      Info = (R, E_inf, T_X, T_Y, SID, T_SAT)            Algorithm 2, 11-12
//   3. turns each round-trip time into a range
//      Rad = C * (T_Y - T_X) / (2 * N * lambda)           Algorithm 2, 17
//   4. solves the four sphere equations (1)-(4) for the vehicle position
//      and computes its distance to the POI                    Algorithm 2, 21-22
//   5. runs Algorithm 3: direction ratios, the angle between the two lines,
//      and equation (11) to recompute the satellite-to-POI distance, then
//      compares it with the Y that Algorithm 1 already gave the TA.
//
// The relay vehicle is the verified vehicle with the smallest distance D to
// the POI (Algorithm 2 step 24); a vehicle whose proof fails can never be
// selected. That is the paper's actual goal, and it is implemented here as
// selectRelayVehicle().
//
// WHAT IS SIMULATED (and must stay labelled in the UI)
//
//   - The four satellites and their timestamps are generated (the paper's GEO
//     four-side model; see api/src/gnss.ts).
//   - The signatures and the encrypted reply are REAL cryptography: ECDSA
//     P-256 for the satellites' DS(Info), RSA-OAEP for the vehicle's
//     E(R, VID, k_pub_TA). A tampered or replayed message really fails.
//   - The demo keys are generated in-process; they are not infrastructure.
//
// WHAT IS AN APP-LEVEL ADDITION (and is labelled as such)
//
// The paper's TA derives the position itself and never checks a vehicle's own
// claim. Our app is fed a claimed GPS position by Delhi's public feed, so the
// proof additionally checks that the claim matches the position the protocol
// derives. That check is ours, not the paper's, and the checks list says so.

import {
  createHash,
  generateKeyPairSync,
  privateDecrypt,
  publicEncrypt,
  randomBytes,
  sign,
  verify,
  type KeyObject,
} from 'node:crypto';

import {
  SIDES,
  algorithm3Check,
  distanceMeters,
  dopFigures,
  geoToEcef,
  lookAngles,
  radFromTimestamps,
  selectNearestSatellites,
  simulateTimestamps,
  solveFourSpheres,
  type Algorithm3Result,
  type GeoPoint,
  type Side,
  type SideSelection,
  type Vec3,
} from './gnss.ts';

// ---------------------------------------------------------------------------
// Constants from the paper / the simulation
// ---------------------------------------------------------------------------

/** The paper's freshness window delta_T (Algorithm 2, 9-15). */
export const DELTA_T_SECONDS = 30;

/** The TA's clock when it verifies a fix whose T_SAT is marked below. */
const TA_CLOCK_AFTER_FIX_MS = 400;

/** T_SAT sits just before the fix, so an honest archived proof stays fresh. */
const TSAT_BEFORE_FIX_MS = 50;

/** How far the app's claimed position may be from the protocol solution. */
export const CLAIM_TOLERANCE_M = 25;

/** How well equations (1)-(4) must be satisfied, in metres. */
export const FOUR_SPHERE_TOLERANCE_M = 250;

/** Plausible geostationary ranges, in metres. */
export const MIN_PLAUSIBLE_RANGE_M = 30_000_000;
export const MAX_PLAUSIBLE_RANGE_M = 60_000_000;

/** A 2 ms delayed reply inflates Rad by about 300 km. */
const DELAY_FAULT_NS = 2_000_000;

// ---------------------------------------------------------------------------
// Types (frozen contract - see scratch/paper-fidelity-contract.md)
// ---------------------------------------------------------------------------

export type ProofStatus = 'verified' | 'weak' | 'rejected';

export type FaultMode = 'none' | 'spoof' | 'replay' | 'tamper' | 'delay' | 'freeze';

export interface ProofCheck {
  id: string;
  label: string;
  detail: string;
  passed: boolean;
  required: boolean;
}

export interface ProofMessageView {
  side: Side;
  satelliteId: string;
  randomValue: string;
  tx: string;
  ty: string;
  tsat: string;
  txNs: number;
  tyNs: number;
  rttNs: number;
  radM: number;
  signatureValid: boolean;
  replyMatchesCurrentChallenge: boolean;
}

export interface LocationProof {
  method: 'paper-protocol-location-proof';
  protocol: 'Paul-Dhal-Mary-2024';
  simulated: true;
  verificationMode: 'live' | 'archived';
  status: ProofStatus;
  label: string;
  headline: string;
  because: string;
  vehicleId: string;
  fixAt: string;
  verifiedAt: string;
  ageSeconds: number;
  poi: { lat: number; lon: number; altM: number; name: string | null };
  /** The position the feed claims for this vehicle, and its error. */
  claim: { lat: number; lon: number; altM: number; horizontalErrorM: number };
  challenge: { id: string; tsat: string; deltaTSeconds: number; alreadyUsed: boolean };
  satelliteSelection: {
    candidatesConsidered: number;
    sides: { side: Side; satelliteId: string; prn: number; ecef: Vec3; distanceToPoiM: number }[];
  };
  messages: ProofMessageView[];
  solved: {
    lat: number;
    lon: number;
    altM: number;
    residualM: number;
    dToPoiM: number;
    hdop: number;
  };
  algorithm3: {
    toleranceM: number;
    maxDifferenceM: number;
    passed: boolean;
    sides: {
      side: Side;
      z1M: number;
      z2M: number;
      angleDeg: number;
      yeKnownM: number;
      yeComputedM: number;
      differenceM: number;
      passed: boolean;
    }[];
  };
  checks: ProofCheck[];
  satellites: {
    id: string;
    prn: number;
    side: Side;
    elevationDeg: number;
    azimuthDeg: number;
    snrDbHz: number;
    rangeM: number;
    used: boolean;
  }[];
  geometry: {
    satellitesVisible: number;
    satellitesUsed: number;
    hdop: number;
    gdop: number;
    maxBaselineErrorM: number;
  };
  attestation: { algorithm: string; keyId: string; signature: string };
  encryption: { algorithm: string; keyId: string };
  fault: { injected: FaultMode; description: string | null };
}

export interface ProofSummary {
  method: string;
  simulated: true;
  verificationMode: 'live' | 'archived';
  status: ProofStatus;
  label: string;
  because: string;
  satellitesUsed: number;
  hdop: number;
  horizontalErrorM: number;
  fixAt: string;
  verifiedAt: string;
  failedCheck: string | null;
  checksPassed: number;
  checksTotal: number;
  position: { lat: number; lon: number };
  poi: { lat: number; lon: number };
  vehicleId: string;
}

export interface ProofInput {
  vehicleId: string;
  position: GeoPoint;
  poi: GeoPoint;
  poiName?: string | null;
  fixAt: Date;
  fault?: FaultMode;
  routeOffsetM?: number | null;
  verificationMode?: 'live' | 'archived';
  now?: Date;
  /** Test/demo hooks so the detection thresholds can be measured. */
  spoofOffsetM?: number;
  freezeOffsetM?: number;
  delayNs?: number;
}

export interface RelayCandidate {
  vehicleId: string;
  routeId: string;
  routeNumber: string;
  claim: { lat: number; lon: number };
  solved: { lat: number; lon: number };
  dToPoiM: number;
  status: ProofStatus;
  rejectedCheck: string | null;
  algorithm3Passed: boolean | null;
}

export interface RelaySelection {
  protocol: 'Algorithm 2 + Algorithm 3';
  simulated: true;
  poi: { lat: number; lon: number; altM: number; name: string | null };
  deltaTSeconds: number;
  satellites: { side: Side; satelliteId: string; ecef: Vec3; distanceToPoiM: number }[];
  candidates: RelayCandidate[];
  selected: RelayCandidate | null;
  selectedAlgorithm3: Algorithm3Result | null;
  caveat: string;
}

export interface RelayVehicleInput {
  vehicleId: string;
  routeId: string;
  routeNumber: string;
  position: GeoPoint;
  fixAt: Date;
}

export interface RelaySelectionInput {
  poi: GeoPoint;
  poiName?: string | null;
  vehicles: RelayVehicleInput[];
  now?: Date;
  /** Test/demo hook: inject a paper attack into one candidate's exchange. */
  faults?: Record<string, FaultMode>;
}

/** The six attacks the paper's threat model names. */
export const FAULT_MODES: { id: FaultMode; label: string; description: string }[] = [
  { id: 'none', label: 'Normal fix', description: 'An honest bus unit answering the challenge.' },
  { id: 'spoof', label: 'Spoofed location', description: 'The feed claims a position 1.5 km from the real fix.' },
  { id: 'replay', label: 'Replayed information', description: 'A signed exchange from 10 minutes ago is presented again.' },
  { id: 'tamper', label: 'Tampered message', description: 'One character of a satellite signature is changed.' },
  { id: 'delay', label: 'Delayed response', description: 'The reply arrives 2 ms late, inflating the measured range.' },
  { id: 'freeze', label: 'Frozen old position', description: 'The unit reports where the bus was 10 minutes ago.' },
];

// ---------------------------------------------------------------------------
// Demo keys (real cryptography, demo infrastructure)
// ---------------------------------------------------------------------------

const taKeys = generateKeyPairSync('rsa', { modulusLength: 2048 });
const satelliteKeys = new Map<Side, { publicKey: KeyObject; privateKey: KeyObject }>(
  SIDES.map((side) => [side, generateKeyPairSync('ec', { namedCurve: 'prime256v1' })]),
);

function keyId(publicKey: KeyObject): string {
  const der = publicKey.export({ type: 'spki', format: 'der' });
  return createHash('sha256').update(der).digest('hex').slice(0, 8);
}

const TA_KEY_ID = keyId(taKeys.publicKey);
const SATELLITE_KEY_IDS = new Map<Side, string>(
  SIDES.map((side) => [side, keyId(satelliteKeys.get(side)!.publicKey)]),
);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function round(value: number, digits = 1): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function hashSeed(text: string): number {
  let hash = 2166136261;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

/** Move a point a given distance in a compass direction (for the faults). */
function offsetPoint(point: GeoPoint, bearingDeg: number, meters: number): GeoPoint {
  const earthRadius = 6371000;
  const bearing = (bearingDeg * Math.PI) / 180;
  const dLat = (meters * Math.cos(bearing)) / earthRadius;
  const dLon =
    (meters * Math.sin(bearing)) / (earthRadius * Math.cos((point.lat * Math.PI) / 180));
  return {
    lat: point.lat + (dLat * 180) / Math.PI,
    lon: point.lon + (dLon * 180) / Math.PI,
    altM: point.altM,
  };
}

function canonicalInfo(message: {
  randomValue: string;
  eInf: string;
  txNs: number;
  tyNs: number;
  satelliteId: string;
  tsat: string;
}): string {
  // The exact bytes the satellite signs. T_X and T_Y are in the paper's role;
  // they are carried as integer nanoseconds relative to T_SAT because epoch
  // milliseconds cannot hold the precision (see gnss.ts radFromTimestamps).
  return [
    message.randomValue,
    message.eInf,
    String(message.txNs),
    String(message.tyNs),
    message.satelliteId,
    message.tsat,
  ].join('\n');
}

function decryptReply(eInfBase64: string): string | null {
  try {
    const plain = privateDecrypt(
      { key: taKeys.privateKey, padding: 4 /* RSA_PKCS1_OAEP_PADDING */, oaepHash: 'sha256' },
      Buffer.from(eInfBase64, 'base64'),
    );
    return plain.toString('utf8');
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Building the signed exchange (Algorithm 2 messages)
// ---------------------------------------------------------------------------

interface WireMessage {
  side: Side;
  satelliteId: string;
  randomValue: string;
  eInf: string;
  txNs: number;
  tyNs: number;
  tx: string;
  ty: string;
  tsat: string;
  rttNs: number;
  radM: number;
  signature: string;
}

/**
 * One satellite's challenge, the vehicle's encrypted reply, and the signed
 * Info message - the paper's Algorithm 2 steps 3-8.
 *
 * Each satellite broadcasts its own random R (the paper: "a vehicle receives
 * different R values from different satellites"), and the vehicle answers each
 * with E(R, VID, k_pub_TA). If `delayNs` is set the reply arrives late, which
 * is the paper's delayed-response attack.
 */
function buildWireMessages(
  vehicleId: string,
  vehiclePosition: GeoPoint,
  selections: SideSelection[],
  sessionTsatMs: number,
  delayNs: number,
  randomValues: Map<Side, string>,
): WireMessage[] {
  return selections.map((selection, index) => {
    const side = selection.side;
    const randomValue = randomValues.get(side) ?? randomBytes(16).toString('hex');
    const eInf = publicEncrypt(
      {
        key: taKeys.publicKey,
        padding: 4 /* RSA_PKCS1_OAEP_PADDING */,
        oaepHash: 'sha256',
      },
      Buffer.from(`${randomValue}|${vehicleId}`, 'utf8'),
    ).toString('base64');

    const timestamps = simulateTimestamps(
      selection.satellite,
      vehiclePosition,
      sessionTsatMs + index * 3, // each satellite broadcasts at its own T_X
      { delayNs, seed: `${vehicleId}|${side}|${sessionTsatMs}` },
    );
    const tsat = new Date(sessionTsatMs).toISOString();
    const info = canonicalInfo({
      randomValue,
      eInf,
      txNs: timestamps.txNs,
      tyNs: timestamps.tyNs,
      satelliteId: selection.satellite.id,
      tsat,
    });
    const keys = satelliteKeys.get(side)!;
    const signature = sign('sha256', Buffer.from(info, 'utf8'), keys.privateKey).toString('hex');

    return {
      side,
      satelliteId: selection.satellite.id,
      randomValue,
      eInf,
      txNs: timestamps.txNs,
      tyNs: timestamps.tyNs,
      tx: timestamps.tx,
      ty: timestamps.ty,
      tsat,
      rttNs: timestamps.rttNs,
      radM: timestamps.radM,
      signature,
    };
  });
}

interface VerifiedWire {
  message: WireMessage;
  signatureValid: boolean;
  replyMatchesCurrentChallenge: boolean;
}

/**
 * The trusted authority's side of Algorithm 2: signature check, freshness,
 * decryption of the reply and the Rad computation. `currentChallenges` holds
 * the R values the TA issued for THIS session - an old signed message cannot
 * match them, which is how a replay is caught even though a replay of an old
 * exchange carries a valid old signature.
 */
function verifyWireMessages(
  messages: WireMessage[],
  sessionTsatMs: number,
  taClockMs: number,
  currentChallenges: Map<Side, string>,
  vehicleId: string,
): VerifiedWire[] {
  return messages.map((message) => {
    const keys = satelliteKeys.get(message.side)!;
    const signatureValid = verify(
      'sha256',
      Buffer.from(
        canonicalInfo({
          randomValue: message.randomValue,
          eInf: message.eInf,
          txNs: message.txNs,
          tyNs: message.tyNs,
          satelliteId: message.satelliteId,
          tsat: message.tsat,
        }),
        'utf8',
      ),
      keys.publicKey,
      Buffer.from(message.signature, 'hex'),
    );

    const plain = decryptReply(message.eInf);
    const expected = `${currentChallenges.get(message.side)}|${vehicleId}`;
    return {
      message,
      signatureValid,
      replyMatchesCurrentChallenge: plain !== null && plain === expected,
    };
  });
}

// ---------------------------------------------------------------------------
// The verdict
// ---------------------------------------------------------------------------

function statusFor(checks: ProofCheck[]): ProofStatus {
  if (checks.some((check) => check.required && !check.passed)) return 'rejected';
  if (checks.some((check) => !check.passed)) return 'weak';
  return 'verified';
}

function wordsFor(status: ProofStatus, checks: ProofCheck[]): {
  label: string;
  headline: string;
  because: string;
} {
  if (status === 'verified') {
    return {
      label: 'GPS verified',
      headline: 'Fix confirmed by 4 satellites (one per side)',
      because:
        'The four nearest satellites - one on each side of the point of interest - agree with ' +
        'the claimed position, and the freshness, signature, encryption, four-sphere and ' +
        'Algorithm 3 checks all passed.',
    };
  }

  if (status === 'weak') {
    const failed = checks.find((check) => !check.required && !check.passed);
    return {
      label: 'Weak GPS fix',
      headline: 'Verified by four satellites, with one caveat',
      because: failed?.detail ?? 'The paper protocol passed, but one optional check did not.',
    };
  }

  const first = checks.find((check) => check.required && !check.passed);
  switch (first?.id) {
    case 'tsat-fresh':
      return {
        label: 'GPS check failed',
        headline: 'Replayed or stale message rejected',
        because:
          'T_SAT is older than the freshness window delta_T, so the TA refuses this exchange ' +
          'before using any of its numbers (Algorithm 2, steps 10-14).',
      };
    case 'signature-valid':
      return {
        label: 'GPS check failed',
        headline: 'The signed message was altered',
        because:
          "One of the satellites' digital signatures no longer matches Info, so the exchange " +
          'was changed after signing (Algorithm 2, steps 11-12).',
      };
    case 'challenge-echo':
      return {
        label: 'GPS check failed',
        headline: 'The reply does not answer this challenge',
        because:
          'Decrypting E_inf did not give the random value R that this satellite broadcast in ' +
          'this session, so the answer is not to our challenge.',
      };
    case 'ranges-plausible':
      return {
        label: 'GPS check failed',
        headline: 'The measured ranges are not physically possible',
        because:
          'At least one Rad = C(T_Y-T_X)/(2N lambda) falls outside the geostationary range, so ' +
          'the timestamps cannot belong to an honest exchange.',
      };
    case 'four-spheres-consistent':
      return {
        label: 'GPS check failed',
        headline: 'The four spheres do not meet',
        because:
          'Equations (1)-(4) do not have a consistent solution: the four ranges disagree with ' +
          'each other, which is what a delayed reply produces.',
      };
    case 'claim-matches-solution':
      return {
        label: 'GPS check failed',
        headline: 'Claimed position does not match the protocol solution',
        because:
          'The position solved from the four trusted ranges is far from the position the feed ' +
          'claimed, so the claimed location is not supported by the satellites.',
      };
    case 'algorithm3-consistent':
      return {
        label: 'GPS check failed',
        headline: 'Algorithm 3 does not close',
        because:
          'Equation (11) does not reproduce the satellite-to-POI distances in Algorithm 1, so ' +
          'the exchange is internally inconsistent.',
      };
    default:
      return {
        label: 'GPS check failed',
        headline: 'The location proof failed',
        because: first?.detail ?? 'A required protocol check failed.',
      };
  }
}

// ---------------------------------------------------------------------------
// Building a proof
// ---------------------------------------------------------------------------

/**
 * Run the paper's protocol for one reported bus position and return a proof.
 *
 * The sequence follows the algorithms: Algorithm 1 picks the four satellites,
 * Algorithm 2 exchanges fresh random values and signed timestamps, the TA
 * solves equations (1)-(4), and Algorithm 3 cross-checks with equation (11).
 */
export function buildLocationProof(input: ProofInput): LocationProof {
  const fault: FaultMode = input.fault ?? 'none';
  const now = input.now ?? new Date();
  const fixAt = input.fixAt;
  const vehicleId = input.vehicleId;

  const verificationMode: 'live' | 'archived' =
    input.verificationMode ??
    (now.getTime() - fixAt.getTime() > 60 * 60 * 1000 ? 'archived' : 'live');

  // -- Algorithm 1 ----------------------------------------------------------
  const poi = input.poi;
  const selection = selectNearestSatellites(poi);
  const selections = selection.sides;

  // -- Algorithm 2: challenge, reply, signed Info ---------------------------
  const currentTsatMs = fixAt.getTime() - TSAT_BEFORE_FIX_MS;
  const taClockMs = fixAt.getTime() + TA_CLOCK_AFTER_FIX_MS;
  const challengeId = randomBytes(6).toString('hex');

  // The TA issues a fresh random value per satellite. These are the values a
  // reply must answer; a replayed exchange carries old ones and fails.
  const currentChallenges = new Map<Side, string>(
    SIDES.map((side) => [side, randomBytes(16).toString('hex')]),
  );

  let sessionTsatMs = currentTsatMs;
  let alreadyUsed = false;
  let delayNs = 0;
  let claim: GeoPoint = { ...input.position };
  let oldSessionMessages: WireMessage[] | null = null;

  if (fault === 'spoof') {
    claim = offsetPoint(claim, 0, input.spoofOffsetM ?? 1500);
  } else if (fault === 'freeze') {
    claim = offsetPoint(claim, 240, input.freezeOffsetM ?? 800);
  } else if (fault === 'delay') {
    delayNs = input.delayNs ?? DELAY_FAULT_NS;
  } else if (fault === 'replay') {
    // A complete signed exchange from ten minutes ago is presented again.
    sessionTsatMs = fixAt.getTime() - 10 * 60 * 1000;
    alreadyUsed = true;
    // Its own (old) R values: the exchange is internally consistent, but it
    // cannot know the R values the TA issued for this session.
    const oldRandomValues = new Map<Side, string>(
      SIDES.map((side) => [side, randomBytes(16).toString('hex')]),
    );
    oldSessionMessages = buildWireMessages(
      vehicleId,
      input.position,
      selections,
      sessionTsatMs,
      0,
      oldRandomValues,
    );
  }

  // The current-session messages (always built: the replay fault simply
  // presents the old ones to the TA instead).
  let messages: WireMessage[];
  if (oldSessionMessages !== null) {
    messages = oldSessionMessages;
  } else {
    messages = buildWireMessages(
      vehicleId,
      input.position,
      selections,
      sessionTsatMs,
      delayNs,
      currentChallenges,
    );
  }

  // Tamper: one character of one satellite's signature is changed in transit.
  if (fault === 'tamper' && messages.length > 0) {
    const signature = messages[0].signature;
    const index = 5;
    const flipped = signature[index] === '0' ? '1' : '0';
    messages[0] = {
      ...messages[0],
      signature: signature.slice(0, index) + flipped + signature.slice(index + 1),
    };
  }

  // The TA verifies the exchange. The current-session challenges are used for
  // the reply check even for a replay, which is the point: an old exchange
  // cannot contain the fresh R values.
  const verified = verifyWireMessages(
    messages,
    sessionTsatMs,
    taClockMs,
    currentChallenges,
    vehicleId,
  );

  // -- Algorithm 2, step 17: Rad from the timestamps ------------------------
  const radiiM = verified.map((entry) => entry.message.radM);
  const satellites = selections.map((selectionsItem) => selectionsItem.satellite);

  // -- Equations (1)-(4) ----------------------------------------------------
  const solution = solveFourSpheres(satellites, radiiM, poi);
  const solved = solution.point;

  // -- Algorithm 2, step 22: distance to the POI ----------------------------
  const dToPoiM = distanceMeters(solved, poi);

  // -- Algorithm 3 ----------------------------------------------------------
  const algorithm3 = algorithm3Check(solved, poi, selections, radiiM);

  // -- The checks -----------------------------------------------------------
  const freshnessSeconds = (taClockMs - sessionTsatMs) / 1000;
  const signatureFailures = verified.filter((entry) => !entry.signatureValid).length;
  const echoFailures = verified.filter((entry) => !entry.replyMatchesCurrentChallenge).length;
  const badRanges = radiiM.filter(
    (radius) => radius < MIN_PLAUSIBLE_RANGE_M || radius > MAX_PLAUSIBLE_RANGE_M,
  ).length;
  const horizontalErrorM = distanceMeters(claim, solved);
  const routeOffsetM = input.routeOffsetM ?? null;

  const checks: ProofCheck[] = [
    {
      id: 'tsat-fresh',
      label: 'Signed exchange is fresh (Algorithm 2, 9-15)',
      detail:
        !alreadyUsed && freshnessSeconds <= DELTA_T_SECONDS
          ? `T_SAT is ${freshnessSeconds.toFixed(2)} s before the TA clock, inside the ${DELTA_T_SECONDS} s window, and this exchange has not been used before.`
          : `T_SAT is ${freshnessSeconds.toFixed(2)} s before the TA clock (window ${DELTA_T_SECONDS} s)${alreadyUsed ? ', and this exchange was already used' : ''}.`,
      passed: !alreadyUsed && freshnessSeconds <= DELTA_T_SECONDS,
      required: true,
    },
    {
      id: 'signature-valid',
      label: 'Satellite signatures verify (Algorithm 2, 11-12)',
      detail:
        signatureFailures === 0
          ? `All four Info messages carry a valid ECDSA P-256 signature from their satellite.`
          : `${signatureFailures} of ${verified.length} Info messages fail their signature check.`,
      passed: signatureFailures === 0,
      required: true,
    },
    {
      id: 'challenge-echo',
      label: 'Replies answer this session\'s R values',
      detail:
        echoFailures === 0
          ? 'RSA-OAEP decryption of each E_inf gives this session\'s R plus the vehicle id.'
          : `${echoFailures} of ${verified.length} encrypted replies do not contain the R this satellite broadcast in this session.`,
      passed: echoFailures === 0,
      required: true,
    },
    {
      id: 'ranges-plausible',
      label: 'Ranges are geostationary-plausible',
      detail:
        badRanges === 0
          ? `All four Rad values from C(T_Y-T_X)/(2N lambda) are between ${Math.round(MIN_PLAUSIBLE_RANGE_M / 1000)} km and ${Math.round(MAX_PLAUSIBLE_RANGE_M / 1000)} km.`
          : `${badRanges} of four Rad values fall outside the geostationary range.`,
      passed: badRanges === 0,
      required: true,
    },
    {
      id: 'four-spheres-consistent',
      label: 'Four sphere equations (1)-(4) agree',
      detail: solution.solved
        ? `Solved positions satisfy equations (1)-(4) to a worst-case ${solution.residualM.toFixed(1)} m (limit ${FOUR_SPHERE_TOLERANCE_M} m).`
        : 'The four sphere equations have no stable solution.',
      passed: solution.solved && solution.residualM <= FOUR_SPHERE_TOLERANCE_M,
      required: true,
    },
    {
      id: 'claim-matches-solution',
      label: 'Claimed position matches the protocol solution',
      detail:
        horizontalErrorM <= CLAIM_TOLERANCE_M
          ? `The feed's claim is ${horizontalErrorM.toFixed(1)} m from the position solved from the four ranges (limit ${CLAIM_TOLERANCE_M} m).`
          : `The four ranges place the vehicle ${Math.round(horizontalErrorM)} m from the claimed position (limit ${CLAIM_TOLERANCE_M} m). This check is the app's addition: the paper's TA derives the position itself and has no claim to compare.`,
      passed: horizontalErrorM <= CLAIM_TOLERANCE_M,
      required: true,
    },
    {
      id: 'algorithm3-consistent',
      label: 'Algorithm 3 closes on all four sides',
      detail: algorithm3.passed
        ? `Equation (11) reproduces Y_E/Y_W/Y_N/Y_S within ${algorithm3.maxDifferenceM.toFixed(2)} m (tolerance ${algorithm3.toleranceM} m).`
        : `Equation (11) differs from the known satellite-to-POI distances by up to ${Math.round(algorithm3.maxDifferenceM)} m (tolerance ${algorithm3.toleranceM} m).`,
      passed: algorithm3.passed,
      required: true,
    },
    {
      id: 'route-plausible',
      label: 'Fix is close to the bus route',
      detail:
        routeOffsetM == null
          ? 'No route line was supplied for this fix, so this check was skipped.'
          : routeOffsetM <= 50
            ? `The fix is ${Math.round(routeOffsetM)} m from the bus route line (limit 50 m).`
            : `The fix is ${Math.round(routeOffsetM)} m from the bus route line, further than the 50 m limit.`,
      passed: routeOffsetM == null ? true : routeOffsetM <= 50,
      required: false,
    },
  ];

  const status = statusFor(checks);
  const words = wordsFor(status, checks);

  const looks = lookAngles(input.position, satellites);
  const dop = dopFigures(satellites, input.position);
  const visualSatellites = selections.map((selectionItem, index) => ({
    id: selectionItem.satellite.id,
    prn: selectionItem.satellite.prn,
    side: selectionItem.side,
    elevationDeg: round(looks[index].elevationDeg, 1),
    azimuthDeg: round(looks[index].azimuthDeg, 1),
    snrDbHz: Math.round(20 + 30 * Math.sin((looks[index].elevationDeg * Math.PI) / 180)),
    rangeM: round(radiiM[index], 1),
    used: true,
  }));

  const faultDescription =
    fault === 'none'
      ? null
      : FAULT_MODES.find((mode) => mode.id === fault)?.description ?? null;

  const attestation = verified[0];

  return {
    method: 'paper-protocol-location-proof',
    protocol: 'Paul-Dhal-Mary-2024',
    simulated: true,
    verificationMode,
    status,
    label: words.label,
    headline: words.headline,
    because: words.because,
    vehicleId,
    fixAt: fixAt.toISOString(),
    verifiedAt: new Date(taClockMs).toISOString(),
    ageSeconds: Math.max(0, Math.round((now.getTime() - fixAt.getTime()) / 1000)),
    poi: {
      lat: poi.lat,
      lon: poi.lon,
      altM: poi.altM,
      name: input.poiName ?? null,
    },
    claim: {
      lat: claim.lat,
      lon: claim.lon,
      altM: claim.altM,
      horizontalErrorM: round(horizontalErrorM, 1),
    },
    challenge: {
      id: challengeId,
      tsat: new Date(sessionTsatMs).toISOString(),
      deltaTSeconds: DELTA_T_SECONDS,
      alreadyUsed,
    },
    satelliteSelection: {
      candidatesConsidered: selection.candidates.length,
      sides: selections.map((selectionItem) => ({
        side: selectionItem.side,
        satelliteId: selectionItem.satellite.id,
        prn: selectionItem.satellite.prn,
        ecef: selectionItem.satellite.ecef,
        distanceToPoiM: round(selectionItem.distanceToPoiM, 1),
      })),
    },
    messages: verified.map((entry) => ({
      side: entry.message.side,
      satelliteId: entry.message.satelliteId,
      randomValue: entry.message.randomValue,
      tx: entry.message.tx,
      ty: entry.message.ty,
      tsat: entry.message.tsat,
      txNs: entry.message.txNs,
      tyNs: entry.message.tyNs,
      rttNs: entry.message.rttNs,
      radM: round(entry.message.radM, 1),
      signatureValid: entry.signatureValid,
      replyMatchesCurrentChallenge: entry.replyMatchesCurrentChallenge,
    })),
    solved: {
      lat: solved.lat,
      lon: solved.lon,
      altM: solved.altM,
      residualM: round(solution.residualM, 2),
      dToPoiM: round(dToPoiM, 1),
      hdop: Number.isFinite(dop.hdop) ? round(dop.hdop, 2) : Number.MAX_SAFE_INTEGER,
    },
    algorithm3: {
      toleranceM: algorithm3.toleranceM,
      maxDifferenceM: round(algorithm3.maxDifferenceM, 2),
      passed: algorithm3.passed,
      sides: algorithm3.sides.map((side) => ({
        side: side.side,
        z1M: round(side.z1M, 1),
        z2M: round(side.z2M, 1),
        angleDeg: round(side.angleDeg, 3),
        yeKnownM: round(side.yeKnownM, 1),
        yeComputedM: round(side.yeComputedM, 1),
        differenceM: round(side.differenceM, 2),
        passed: side.passed,
      })),
    },
    checks,
    satellites: visualSatellites,
    geometry: {
      satellitesVisible: visualSatellites.length,
      satellitesUsed: 4,
      hdop: Number.isFinite(dop.hdop) ? round(dop.hdop, 2) : Number.MAX_SAFE_INTEGER,
      gdop: Number.isFinite(dop.gdop) ? round(dop.gdop, 2) : Number.MAX_SAFE_INTEGER,
      maxBaselineErrorM: round(algorithm3.maxDifferenceM, 2),
    },
    attestation: {
      algorithm: 'ECDSA-P256-SHA256',
      keyId: SATELLITE_KEY_IDS.get(attestation.message.side) ?? 'unknown',
      signature: attestation.message.signature,
    },
    encryption: {
      algorithm: 'RSA-OAEP-SHA256',
      keyId: TA_KEY_ID,
    },
    fault: { injected: fault, description: faultDescription },
  };
}

/**
 * The compact proof carried on a board row.
 *
 * `failedCheck` is only set for a rejection, so a `weak` verdict is not
 * worded like a failure. `poweredBy` keeps the paper's four satellites visible
 * in the summary.
 */
export function summarizeProof(proof: LocationProof): ProofSummary {
  const firstRequiredFailure = proof.checks.find(
    (check) => check.required && !check.passed,
  );

  return {
    method: proof.method,
    simulated: true,
    verificationMode: proof.verificationMode,
    status: proof.status,
    label: proof.label,
    because: proof.because,
    satellitesUsed: proof.geometry.satellitesUsed,
    hdop: proof.geometry.hdop,
    horizontalErrorM: proof.claim.horizontalErrorM,
    fixAt: proof.fixAt,
    verifiedAt: proof.verifiedAt,
    failedCheck: proof.status === 'rejected' ? (firstRequiredFailure?.id ?? null) : null,
    checksPassed: proof.checks.filter((check) => check.passed).length,
    checksTotal: proof.checks.length,
    position: { lat: proof.claim.lat, lon: proof.claim.lon },
    poi: { lat: proof.poi.lat, lon: proof.poi.lon },
    vehicleId: proof.vehicleId,
  };
}

// ---------------------------------------------------------------------------
// Relay-vehicle selection (the paper's actual objective)
// ---------------------------------------------------------------------------

/**
 * Securely select the relaying vehicle: the verified vehicle nearest the
 * point of interest.
 *
 * This is the paper's end goal. Every candidate's position is derived by the
 * TA from the trusted four-satellite exchange (Algorithm 2), so a vehicle
 * cannot win by lying about its coordinates; a candidate whose proof fails is
 * never eligible, so a malicious nearest vehicle is skipped and the next
 * verified one becomes the relay. Algorithm 3's result is reported for the
 * chosen vehicle.
 */
export function selectRelayVehicle(input: RelaySelectionInput): RelaySelection {
  const now = input.now ?? new Date();
  const selection = selectNearestSatellites(input.poi);

  const proved = input.vehicles.map((vehicle) => {
    const fault = input.faults?.[vehicle.vehicleId] ?? 'none';
    const proof = buildLocationProof({
      vehicleId: vehicle.vehicleId,
      position: vehicle.position,
      poi: input.poi,
      poiName: input.poiName,
      fixAt: vehicle.fixAt,
      fault,
      now,
    });
    return { vehicle, proof };
  });

  const candidates: RelayCandidate[] = proved.map(({ vehicle, proof }) => ({
    vehicleId: vehicle.vehicleId,
    routeId: vehicle.routeId,
    routeNumber: vehicle.routeNumber,
    // The claim the relay table shows must be the claim the protocol judged,
    // not the underlying true position - otherwise a spoofed candidate would
    // be listed as if its lie had never happened.
    claim: { lat: proof.claim.lat, lon: proof.claim.lon },
    solved: { lat: proof.solved.lat, lon: proof.solved.lon },
    dToPoiM: round(proof.solved.dToPoiM, 1),
    status: proof.status,
    rejectedCheck:
      proof.status === 'rejected'
        ? (proof.checks.find((check) => check.required && !check.passed)?.id ?? null)
        : null,
    algorithm3Passed: proof.algorithm3.sides.every((side) => side.passed),
  }));

  candidates.sort((a, b) => a.dToPoiM - b.dToPoiM);

  // The paper only accepts a vehicle whose checks passed, so a weak proof is
  // not eligible either: the relay must be verified.
  const selected = candidates.find((candidate) => candidate.status === 'verified') ?? null;
  const selectedProof = selected
    ? proved.find(({ vehicle }) => vehicle.vehicleId === selected.vehicleId)?.proof ?? null
    : null;

  return {
    protocol: 'Algorithm 2 + Algorithm 3',
    simulated: true,
    poi: {
      lat: input.poi.lat,
      lon: input.poi.lon,
      altM: input.poi.altM,
      name: input.poiName ?? null,
    },
    deltaTSeconds: DELTA_T_SECONDS,
    satellites: selection.sides.map((side) => ({
      side: side.side,
      satelliteId: side.satellite.id,
      ecef: side.satellite.ecef,
      distanceToPoiM: round(side.distanceToPoiM, 1),
    })),
    candidates,
    selected,
    selectedAlgorithm3: selectedProof?.algorithm3 ?? null,
    caveat:
      'Simulated: the four satellites and their timestamps are generated for the demo. ' +
      'The signatures, encryption and checks are real, so a lying or delayed candidate is ' +
      'genuinely rejected - but this does not prove anything about Delhi\u2019s real feed.',
  };
}

/**
 * Read a fault mode from a query string. Empty means "no fault"; anything
 * unknown is an error rather than silently becoming 'none'.
 */
export function parseFaultMode(value: unknown): FaultMode {
  if (value === undefined || value === null || value === '') return 'none';
  if (typeof value !== 'string') {
    throw new Error(`fault must be one of: ${FAULT_MODES.map((mode) => mode.id).join(', ')}`);
  }
  const match = FAULT_MODES.find((mode) => mode.id === value);
  if (!match) {
    throw new Error(
      `unknown fault '${value}'. Allowed: ${FAULT_MODES.map((mode) => mode.id).join(', ')}`,
    );
  }
  return match.id;
}

// Unused-but-exported geometry helper used by tests to show the paper's POI
// positioning; keeping the import surface stable for the check script.
export { hashSeed, geoToEcef };
