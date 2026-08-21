# Realtime feed profile — `VehiclePositions.pb`

Phase 1 reconnaissance, realtime side. What OTD's live feed actually sends,
measured from the recorder's own archive rather than assumed from the
GTFS-realtime spec. Companion to `docs/static-feed-profile.md`.

Archive analysed: 2026-08-09 → 2026-08-10, 6,683 recorded frames, collected by
the Azure-deployed recorder at 10s polling. Reproduce with
`node tools/scan-archive.js` and `node tools/peek-frame.js` against a local
copy of the archive (`DATA_ROOT` pointed at it).

## The feed serves genuinely empty responses, often

| day | frames | zero-vehicle frames | % empty |
|---|---|---|---|
| 2026-08-09 | 4,696 | 2,470 | 52.6% |
| 2026-08-10 (partial) | 1,987 | 449 | 22.6% |
| **combined** | **6,683** | **2,919** | **43.7%** |

These are not failed fetches — every one is a normal `HTTP 200` with a valid,
well-formed `FeedMessage`. One was inspected directly: a 35-byte gzipped
payload, header only, zero `entity` rows. This is what OTD's server actually
sent, not a truncation or a recorder bug.

It started within 3 minutes of the recorder going live and is present on
every day recorded so far — chronic, not a one-off blip. Fleet counts have
been observed swinging from 0 to ~5,600 vehicles and back within a single
10-second tick either side of one of these frames, which is not plausible as
real-world bus behaviour. The likely explanation is a server-side caching or
regeneration cycle on OTD's backend that occasionally serves before the feed
has repopulated — but that's inference, not confirmed against OTD directly.

**Consequence for anything reading this archive:** `vehicle_count = 0` means
"the feed said nothing this tick," never "zero buses are running." Treating
it as the latter would fabricate a false signal about the fleet — exactly the
kind of certainty this project exists to avoid manufacturing. `realtime_frame`
keeps every frame, including empty ones, specifically so this pattern stays
queryable rather than silently discarded.

## Fleet size, when the feed isn't empty

From `scan-archive.js` across all decoded frames:

| min | p05 | p50 (median) | p95 | max |
|---|---|---|---|---|
| 0 | 0 | 3,444 | 5,577 | 5,606 |

Ignoring empty frames, the visible fleet still swings by the full range
(0 → ~5,600, effectively 100% of peak) between adjacent 10-second frames on
several occasions — consistent with the empty-frame phenomenon above rather
than real fleet turnover.

## `trip_id` and `route_id` — both present

CLAUDE.md previously flagged this as unverified. Confirmed against real
frames: every vehicle entity carries both. `trip_id` follows the pattern
`route_id_HH_MM`, matching the static feed's own trip-naming convention
exactly (see `docs/static-feed-profile.md`). Example: `route_id=1728`,
`trip_id=1728_11_50`.

## `speed` is always zero; `bearing` is never present

Sampled 243,118 vehicle rows across a full day of non-empty frames
(`position.speed` checked on every one):

- `speed` field: present on 100%, and **exactly `0` on 100%** — never once a
  non-zero reading.
- `bearing` field: **absent on 100%** — not zero, genuinely never sent.

Neither field carries usable information from this feed. Real speed or
heading has to be derived from position deltas between consecutive frames of
the same `vehicle_id` — that's Phase 2 map-matching work, not something the
loader or this profile attempts.

## `schedule_relationship` — many vehicles aren't in the static schedule

One sampled frame: 5,573 vehicles, `SCHEDULED=2,025`, `ADDED=3,548`. The
majority of running vehicles report `ADDED` — meaning the trip does not exist
anywhere in the static `trips` table. This is consistent with CLAUDE.md's
documented "ghost buses" problem (new e-bus fleets never registered in the
system) showing up from the other direction: buses that exist in the
realtime feed with no static counterpart at all.

**Consequence for schema design:** `vehicle_position.trip_id` has no foreign
key to `trips` — declaring one would reject the majority of real rows.

## What's loaded

`db/schema_realtime.sql` defines two tables, confirmed loaded from the full
archive analysed above:

| table | rows | notes |
|---|---|---|
| `realtime_frame` | 6,683 | one per recorded file, including empty ones — `vehicle_count` is the frame-emptiness signal described above |
| `vehicle_position` | 17,400,363 | one per vehicle per non-empty frame. No `speed`/`bearing` columns, no FK from `trip_id` to `trips` (both explained above) |

5,994 distinct `vehicle_id` values seen across the archive so far — a rough
upper bound on the visible fleet size, not the true fleet size (a vehicle
that never sent a position, or was mid-empty-frame every time it would have
been seen, isn't counted here).

Load or re-load with:

```
node tools/load-realtime.js            # all days under DATA_ROOT/raw
node tools/load-realtime.js 2026-08-10 # one day only
```

Idempotent — `source_file` is `UNIQUE` on `realtime_frame`, so re-running
after pulling more days down from the recorder only loads what's new.

## Traps for anything reading this feed

- **Don't count `vehicle_count = 0` as fleet data.** It's feed noise, not a
  measurement of how many buses are running. Filter it out of any "buses
  currently running" metric; keep it in for feed-uptime metrics.
- **Don't trust `position.speed`.** It's always 0. Derive movement from
  position deltas instead.
- **Don't assume `trip_id` resolves in `trips`.** A large fraction won't —
  check `schedule_relationship` first.
- **Position age varies a lot.** Even within one non-empty frame, individual
  vehicles' `position.timestamp` can be anywhere from a few seconds to
  several minutes behind the frame's own header timestamp. Always compute
  and check per-vehicle age; don't assume the whole frame is equally fresh.
