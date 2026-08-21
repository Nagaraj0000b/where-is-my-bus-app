# Where Is My Bus — Delhi

An honesty-and-gap-fill layer over Delhi's public bus feed: which buses are
coming to a stop, when, and how much that number can be trusted. The full
motivation, the problem being solved, and why it differs from what already
exists is in [CLAUDE.md](CLAUDE.md) — read that first if you're new here.

## Status

| Phase | State |
|---|---|
| 0 — Recorder | **Stopped deliberately (2026-08-19)**, after collecting a full 8+ day archive (Aug 9–16). `wimb-recorder.service` stopped and disabled on the VM — no more data being collected, on purpose (storage/time constraints ruled out extending to 3–4 weeks). Archive preserved on the VM (6.4 GB, 79,469 frames) and pulled down locally. See [recorder/DEPLOY.md](recorder/DEPLOY.md) |
| 1 — Look at the data | **Done.** Static GTFS profiled and loaded. Realtime archive profiled and loaded too — see [docs/realtime-feed-profile.md](docs/realtime-feed-profile.md) for what was actually found (the feed serves genuinely empty responses ~44% of the time; `speed` is always 0; most vehicles aren't in the static schedule at all) |
| 2 — Map-matching | **Done.** Each stop's offset along its route is computed for all 3.85M `stop_times` rows. The vehicle-position matching pipeline (raw distance-along-route, then accept/reject GPS noise) is built, validated, and re-run on a full week (Mon–Sun, Aug 10–16). Three bugs found and fixed (rejection cascade, lap-restart, measurement ruler mismatch), plus one known remaining issue (buses traveling backward on one-way route shapes — ~13% rejection rate, correctly excluded from downstream output). Write-up in [docs/plain-explanations.md](docs/plain-explanations.md) |
| 3 — Historical travel times | **Done.** Stop passage times extracted for all 7 days — 9.73M passages across 6,121 vehicles, 2,138 routes, 6,512 stops. Aggregated into `route_segment_travel_time`: 68,758 route segments, each with pooled and hour-of-day travel time statistics (median/p25/p75/mean/stddev), averaging 133 samples per segment. Typical hop: 86.5s median, consistent with measured ~19-22 km/h bus speeds |
| 4 — ETA + evaluation | **Method designed and 7-fold cross-validated.** Cross-validation (each day held out in turn) overturned three conclusions drawn from a single held-out day, including the biggest one: the model had **no day-type awareness**, so it under-predicted weekdays (+279s @20 hops) and over-predicted weekends (−527s) — errors that cancelled into a deceptively healthy average. Adding a weekday/weekend split cut bias **83% on weekdays and 99% on weekends**, and improved weekend accuracy 25–41%. Also established: sum means not medians; live position must **not** be used to extrapolate delay (correlation 0.088; the intuitive version makes ETAs 16–55% worse). Final accuracy: 20-hop ETA off by ~482s weekday / ~370s weekend. Full method, bands and limits in **[docs/eta-design.md](docs/eta-design.md)**. ETA-serving logic not yet built |
| 5 — API | **Built and verified.** Fastify + TypeScript (Node 25 runs TS directly, no build step). **`/journey`** is the headline: two *locations* in, ways to travel out, ranked by **total** time (walk + wait + ride) — because a faster ride on a rarer bus is a worse journey. Routes on *places* not stop_ids (Delhi lists ~1.9 ids per real stop; raw ids make 5% of pairs look connected instead of 16.8%), allows one change (~87% coverage). Plus `/eta`, `/routes/:id/stops`, `/routes/search`, `/stops/near`, `/stops/search`, `/health`. **`/journey/by-hour`** answers *when* to travel — the same journey costed for every service hour (best 08:00 = 10.9 min, worst 16:00 = 17.5 min on the example route), which no bus app does because it needs observed frequency. All logic proved in scripts before being wrapped, per convention #4 — 24 + 52 checks, plus 109 end-to-end HTTP tests. Deliberately **no live-arrivals endpoint** while the recorder is stopped. See [api/README.md](api/README.md) |
| 6 — Flutter app | **Three real screens, working end to end (2026-08-20).** Flutter 3.47.1, Android SDK, OpenJDK 17 — `flutter doctor` clean except Windows-desktop support (deliberately skipped). Phone connects over **home WiFi**, not USB (`http://10.3.6.147:3000`, firewall rule scoped to Private networks only — chosen over a permanent USB tether and over ngrok, which would have exposed the dev API to the public internet). Bottom-nav shell with: **Journey** (`journey_screen.dart`) — the planner, tested live on a phone against `/journey`, confidence-banded results, GPS "use my location"; **When?** (`by_hour_screen.dart`) — `/journey/by-hour` as an hour-by-hour comparison with a best/worst headline; **Routes** (`routes_screen.dart`) — search a route number, see its ordered stop list via the new `/routes/search` + `/routes/:id/stops`. `flutter analyze` and `flutter test` clean, `flutter build web` succeeds end-to-end. See [docs/flutter-setup.md](docs/flutter-setup.md). Honest constraint unchanged: with the recorder stopped there is no live feed, so there is still no "arriving now" screen |

## Layout

```
CLAUDE.md                      project context — read this first
RULES.md                       how to talk and how code should look — plain
                                language, simple code, comments required
README.md                      this file

recorder/                      Phase 0 — fetches VehiclePositions.pb on a
                                loop, writes gzipped frames + a manifest.
                                Zero dependencies, runs as a systemd service.
  record.js                    the recorder itself
  wimb-recorder.service        systemd unit used on the deployed VM
  README.md                    what it does, storage math, local test run
  DEPLOY.md                    the live deployment's actual config, and how
                                to rebuild it from scratch if it's ever lost
  .env.example                 copy to .env for a local test run (gitignored)

tools/                         Phase 1 — scripts that read the archive,
                                nothing here is production code
  peek-frame.js                inspect one recorded frame (CSV/JSON export)
  scan-archive.js              fleet count over time, ghost-bus detection
  profile-gtfs.js              reconnaissance script that produced
                                docs/static-feed-profile.md
  load-realtime.js             loads recorded frames into vehicle_position /
                                realtime_frame, idempotent, re-run as the
                                archive grows
  match-vehicle-progress.js    Phase 2 - decides which raw GPS readings to
                                trust, bus by bus, in time order

api/                           Phase 5 - the service. Node 25 runs the
                                TypeScript directly, so there is no build step
  src/journey.ts               the journey planner - two locations to ranked
                                ways of travelling. Ranks by TOTAL time (walk
                                + wait + ride), routes on places not stop_ids,
                                allows one change (~87% coverage). Also
                                planByHour: "when should I travel", the same
                                journey costed for every service hour
  src/eta.ts                   bus position -> arrival estimate with an honest
                                range. Every rule came from measurement
                                (docs/eta-design.md)
  src/db.ts                    shared connection pool
  src/server.ts                HTTP translation only, no logic of its own
  check-eta.ts                 proves the ETA logic BEFORE the service wraps
                                it (convention #4) - 24 checks, including a
                                real held-out-day experiment
  check-journey.ts             proves the journey planner - 52 checks,
                                including a pair verified to genuinely need
                                a change (the first two attempts passed
                                without ever running the transfer code)
  README.md                    endpoints, response shape, what is
                                deliberately missing and why

app/                            Phase 6 - the Flutter app. Bottom-nav shell
                                (main.dart) over three screens
  lib/journey_screen.dart      the planner - two places in, ranked ways to
                                travel out, never a bare number (confidence
                                band + plain-language "because")
  lib/by_hour_screen.dart      "when should I travel" - the same journey
                                costed for every service hour, best/worst
                                highlighted
  lib/routes_screen.dart       search a route number, see its ordered stop
                                list - also how someone finds their own
                                stop's position number for /eta later
  lib/place_search_field.dart  shared "type a stop name, pick a
                                suggestion" box - journey and by-hour both
                                need a From/To picker, so this is the one
                                place that debounce/suggestion logic lives
  lib/error_card.dart          shared error display - offers "Try again"
                                only when retrying could genuinely help
                                (a failed request), never for an honest
                                "no route found" answer
  lib/api_client.dart          talks to api/, turns JSON into Dart objects
                                that keep the range+confidence shape all
                                the way to the widget tree

db/                            PostgreSQL + PostGIS schema, both for the
                                static GTFS and the loaded realtime archive
  schema.sql / load.sql / verify.sql       static GTFS
  schema_realtime.sql                      realtime_frame, vehicle_position
  compute_stop_distances.sql   Phase 2 - fills the stop-offset-along-route
                                gap the static feed leaves blank
  schema_matching.sql          Phase 2 - vehicle_progress table (raw vs.
                                accepted distance-along-route per sighting)
  compute_vehicle_raw_progress_chunked.sql   Phase 2 - closest-point-on-line
                                for every recorded bus sighting, done in
                                frame-id chunks (see plain-explanations.md
                                for why the day-by-day version was worse)
  schema_route_places.sql      routing index: which routes call at which
                                places, in order. 87,718 rows instead of
                                joining 3.85M stop_times per request
  schema_place_frequency.sql   how often each route really turns up at each
                                place, by hour and day type. Observed, not
                                timetabled - this is what makes wait times
                                real and ranking correct
  schema_stop_places.sql       groups stop_ids that are the same physical
                                place (Delhi lists ~1.9 per real stop, one
                                per direction). Not cosmetic - routing on
                                raw stop_ids loses two thirds of the real
                                connections. See docs/journey-design.md
  schema_stop_passages.sql     Phase 3 - observed_stop_passage table
                                (accumulates across daily processing runs)
  extract_stop_passages.sql    Phase 3 - extracts stop passage times by
                                interpolating between consecutive accepted
                                GPS readings
  schema_travel_times.sql      Phase 3 - route_segment_travel_time table
                                (pooled + hourly travel time statistics)
  compute_travel_times.sql     Phase 3 - aggregates stop passages into
                                per-segment travel time statistics
  evaluate_travel_time_predictions.sql   Phase 4 - the evaluation harness.
                                Holds out one day, trains on the other 6,
                                checks SINGLE-HOP predictions against real
                                held-out hops. Self-contained, doesn't touch
                                the production route_segment_travel_time table
  evaluate_multistop_eta.sql   Phase 4 - the number that actually matters:
                                multi-stop ETA error (1/3/5/10/20 hops).
                                Found errors compound rather than cancel,
                                and are systematically optimistic
  diagnose_eta_bias.sql        Phase 4 - tests two competing explanations
                                for that optimism against each other
                                (slow test day vs. sum-of-medians trap)
                                and measures the median-vs-mean fix
  calibrate_eta_bands.sql      Phase 4 - measures the empirical (lopsided)
                                confidence bands, and tests whether a bus
                                already running late stays late
  calibrate_live_correction.sql  Phase 4 - fair re-test of live delay
                                correction at gentle coefficients near its
                                statistical optimum, before ruling it out
  schema_eta_calibration.sql   Phase 4 - eta_calibration_fold table, one
                                row per (held-out day, journey length)
  crossvalidate_eta.sql        Phase 4 - ONE cross-validation fold; run
                                seven times by scripts/crossvalidate-eta.sh
  crossvalidate_eta_daytype.sql  Phase 4 - the fix cross-validation found
                                was needed: predicts from the same KIND of
                                day (weekday/weekend), scored against the
                                day-blind method on identical journeys
  README.md                    setup, query examples, deliberate schema
                                choices for both sides

scripts/
  run-full-pipeline.sh         pulls the full archive, loads it, and
                                re-runs Phase 2 matching end to end -
                                resumable, safe to re-run
  process-week.sh              Phase 2+3 day-by-day loop - processes
                                Aug 10-16 (Mon-Sun) one day at a time:
                                load, match, extract passages, clear
  crossvalidate-eta.sh         Phase 4 - rotates the held-out day across
                                all 7 days. This is what caught the
                                single-day calibration being wrong

docs/
  plain-explanations.md        plain-English write-ups of things built here,
                                reusable for the report/viva — no jargon
  static-feed-profile.md       what Delhi's static GTFS actually contains,
                                measured — row counts, integrity, what's
                                fake or missing, the fabricated-timetable
                                speed analysis
  realtime-feed-profile.md     what the realtime feed actually sends,
                                measured — the ~44% empty-frame phenomenon,
                                speed/bearing being unusable, trip_id
                                verified present, ADDED vs SCHEDULED split
  journey-design.md            the user-facing reframe: the app answers
                                TRAVEL (A to B), not bus-picking. Verified
                                end to end on real data; includes the
                                measurement showing 95% of journeys need a
                                transfer, which corrected an earlier
                                assumption. Design note - not yet built
  flutter-setup.md             Phase 6 prerequisite - installing Flutter on
                                THIS 16 GB laptop without the app work and
                                Docker fighting for memory: VS Code over
                                Android Studio, real phone over emulator,
                                plus the adb-reverse gotcha
  low-level-design.md          bottom-up design: every table that exists
                                (Phases 0-3), how the five pipeline scripts
                                connect them, and field-level reference for
                                all 13 — plus what Phase 4 still has to decide
  eta-design.md                Phase 4 design, written after measuring:
                                sum means not medians, lopsided confidence
                                bands from real residuals, and why live
                                delay extrapolation is deliberately NOT used

delhi_buses_static_gtfs_v1/    the static GTFS snapshot itself. Gitignored —
                                151 MB stop_times.txt alone exceeds GitHub's
                                100 MB limit. Reload with db/load.sql.

docker-compose.yml             PostGIS for local dev, plus Adminer (a plain
                                web page for browsing the database at
                                localhost:8081 - see db/README.md)
package.json                   npm scripts for tools/
```

## Quickstart

**Database** (static GTFS + realtime archive, local dev):

```bash
docker compose up -d
docker exec wimb-db psql -U wimb -d wimb -f /db/schema.sql
docker exec wimb-db psql -U wimb -d wimb -v label=delhi_buses_static_gtfs_v1 -f /db/load.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/verify.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_realtime.sql
node tools/load-realtime.js
```

Full detail, including the Git Bash path-mangling gotcha, in [db/README.md](db/README.md).

**Inspect the live archive** (once you have `.pb.gz` frames locally, e.g. after
pulling days down from the recorder VM — see `DATA_ROOT` convention in
[CLAUDE.md](CLAUDE.md) §9):

```bash
npm run peek                    # newest frame in DATA_ROOT
npm run scan-archive            # fleet count over time, all days
npm run profile-gtfs -- <dir>   # re-profile a static GTFS snapshot
npm run load-realtime           # load/refresh the DB from DATA_ROOT/raw
```

**Recorder** — already running unattended in the cloud; you shouldn't need to
touch this day to day. If you ever need to run it locally to test a change,
or rebuild the deployment from scratch, see [recorder/README.md](recorder/README.md)
and [recorder/DEPLOY.md](recorder/DEPLOY.md).

## Conventions

Working conventions (look at real data before designing, raw archive is
immutable, build the evaluation harness early, script before service) and the
AI-assistance boundary (AI may write map-matching and ETA logic, but must
explain it in plain language alongside the code — see *On AI assistance* in
[CLAUDE.md](CLAUDE.md)) apply project-wide, not just to this file.
