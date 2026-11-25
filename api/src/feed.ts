// What the app needs to know before it can be honest about the data:
// is the official feed live, how old is the newest frame, and which
// recorded days can be replayed?
//
// This is read-only. It never touches the ETA model or the matcher.

import { pool } from './db.ts';

export interface ReplayDay {
  day: string;
  firstAt: string;
  lastAt: string;
}

export interface RawPositionDay {
  day: string;
  frames: number;
  lastAt: string;
}

export interface FeedStatus {
  live: boolean;
  reason: string;
  checkedAt: string;
  newestFrameAt: string | null;
  newestNonEmptyFrameAt: string | null;
  /** Age of the newest non-empty frame, in seconds. Null if none exists. */
  newestNonEmptyAgeSeconds: number | null;
  /** Days that have matched stop passages and can be replayed. */
  replayDays: ReplayDay[];
  /** Days that still have raw vehicle positions loaded (needed for the raw-vs-snapped demo). */
  rawPositionDays: RawPositionDay[];
}

// The app polls this, but the answer only changes when a frame is loaded.
// A short cache keeps the two aggregate queries off the hot path.
const CACHE_MS = 30_000;
let cached: { at: number; value: FeedStatus } | null = null;

/** How old a frame may be before the app must stop calling it live. */
export const LIVE_TTL_SECONDS = 90;

/** How old a frame may be before the last known position is too stale to use. */
export const LAST_SEEN_TTL_SECONDS = 10 * 60;

function asIso(value: Date | string | null): string | null {
  if (value === null || value === undefined) return null;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

async function loadFeedStatus(): Promise<FeedStatus> {
  const now = new Date();

  const [frames, rawDays, replayDays] = await Promise.all([
    pool.query<{
      newest_frame_at: Date | null;
      newest_nonempty_at: Date | null;
    }>(
      `
      SELECT max(feed_timestamp) AS newest_frame_at,
             max(feed_timestamp) FILTER (WHERE vehicle_count > 0) AS newest_nonempty_at
      FROM realtime_frame
      `,
    ),
    pool.query<{ day: string; frames: number; last_at: Date }>(
      `
      SELECT day::text AS day, count(*)::int AS frames, max(feed_timestamp) AS last_at
      FROM realtime_frame
      GROUP BY day
      ORDER BY day DESC
      `,
    ),
    // Seven days of passages, but only their first and last moment are
    // needed to build the replay picker. Counting every row here made the
    // first app launch wait four seconds; min/max is under half a second.
    pool.query<{
      day: string;
      first_at: Date;
      last_at: Date;
    }>(
      `
      SELECT day::text AS day,
             min(passage_time) AS first_at,
             max(passage_time) AS last_at
      FROM observed_stop_passage
      GROUP BY day
      ORDER BY day DESC
      `,
    ),
  ]);

  const newestFrameAt = asIso(frames.rows[0]?.newest_frame_at ?? null);
  const newestNonEmptyFrameAt = asIso(frames.rows[0]?.newest_nonempty_at ?? null);

  const newestNonEmptyAgeSeconds = newestNonEmptyFrameAt
    ? Math.max(0, Math.round((now.getTime() - new Date(newestNonEmptyFrameAt).getTime()) / 1000))
    : null;

  const live =
    newestNonEmptyAgeSeconds !== null && newestNonEmptyAgeSeconds <= LIVE_TTL_SECONDS;

  let reason: string;
  if (live) {
    reason = `Official feed is live; the newest non-empty frame is ${newestNonEmptyAgeSeconds}s old.`;
  } else if (newestNonEmptyFrameAt) {
    reason =
      'Official feed is not running. Newest recorded frame is ' +
      `${newestNonEmptyFrameAt}; replay is available for the recorded days below.`;
  } else {
    reason = 'No realtime frame has ever been loaded. Only recorded passages and the offline pack are available.';
  }

  return {
    live,
    reason,
    checkedAt: now.toISOString(),
    newestFrameAt,
    newestNonEmptyFrameAt,
    newestNonEmptyAgeSeconds,
    replayDays: replayDays.rows.map((row) => ({
      day: row.day,
      firstAt: asIso(row.first_at) as string,
      lastAt: asIso(row.last_at) as string,
    })),
    rawPositionDays: rawDays.rows.map((row) => ({
      day: row.day,
      frames: row.frames,
      lastAt: asIso(row.last_at) as string,
    })),
  };
}

/** Cached feed status, safe to call on every app launch. */
export async function feedStatus(): Promise<FeedStatus> {
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.value;
  const value = await loadFeedStatus();
  cached = { at: Date.now(), value };
  return value;
}

/** Only the check script should need this. */
export function clearFeedStatusCache(): void {
  cached = null;
}
