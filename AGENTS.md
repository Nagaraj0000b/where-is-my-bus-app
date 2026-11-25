# Where Is My Bus

Project context. This describes *what* is being built and *why*.
It deliberately does not prescribe *how* — the developer is working the
implementation out while building. For how code should look and how to
talk about it, see [RULES.md](RULES.md).

---

## 1. What this is

A fault-tolerant bus tracking and transit planning architecture with an
offline-capable static layer: **Where Is My Bus**, referencing the commuter-first
philosophy of **Where Is My Train**.

The core principles adapted from Where Is My Train for urban bus transit:
1. **Offline-First, for the layer that can be offline**: routes, stops, ordered
   stop sequences and direct-bus lookups operate locally on-device (via SQLite)
   with zero internet connectivity. Timetables, arrival times and journey
   planning need the API, and live bus positions always need the network — an
   offline phone has no way to learn where a bus is. The app says which of the
   two it is answering from instead of blurring them.
2. **Crowdsourced Telemetry Imputation**: When official feeds drop, lag, or fail to
   list active buses ("ghost buses"), passengers traveling on board transmit GPS
   beacons to keep the bus visible for waiting commuters.
3. **Graceful Degradation**: Continuous service dynamically stepping down across
   fallback tiers (Live GPS -> Crowdsourced Telemetry -> Historical Statistics -> Static Timetable)
   instead of vanishing.
4. **Probabilistic Arrival Intervals**: Providing commuters with calibrated arrival time windows
   (e.g., 8–12 min) with explicit data provenance indicators, rather than brittle single-point ETAs.

### The Role of Delhi Transit Data (The Testbed)
Delhi was chosen as the **reference implementation and empirical testbed** because
the Delhi Open Transit Data (OTD) initiative provides open static GTFS and 10-second
GTFS-Realtime feeds across 7,300+ buses. It provides a real-world testing ground
with characteristic municipal feed anomalies: 30–50% empty responses, hardcoded 0-speed metrics,
static schedules assuming idealized constant speeds, and unlisted fleets.

---

## 2. The Technical Challenge: Real-World Municipal Telemetry

Modern municipal bus transit produces massive telemetry streams, but raw feeds present major systemic challenges:

1. **Telemetry dropouts & outages**: Hardware GPS units go offline or drop packets, causing active vehicles to disappear from tracking maps.
2. **Unlisted fleets & unscheduled trips**: New feeder fleets or dynamically added trips lack entries in static schedule feeds.
3. **Static schedule discrepancies**: Published timetables (e.g., in GTFS `stop_times.txt`) typically assume idealized constant travel velocities without accounting for real-world traffic congestion.
4. **Missing sensor attributes**: Realtime feeds frequently omit speed and bearing metrics or hardcode them to 0, requiring velocity and heading to be derived algorithmically from sequential spatial sightings.
5. **Feed response volatility**: Upstream cache invalidation or server regeneration can cause intermittent empty payloads (0 vehicles returned) even during peak fleet operations.
6. **Brittle point-estimate ETAs**: Oversimplified single-point arrival times fail to reflect stochastic urban traffic variance and dwell times.

### Data Source Facts (Delhi Testbed)

- **OTD publishes `VehiclePositions.pb` only. There is no `TripUpdates` feed.**
  No precomputed ETA exists in the open data — the prediction and journey planning
  layers are designed and engineered from raw positions from the ground up.
- The static GTFS includes full route linestrings in `shapes.txt` (770,824 points
  across 2,648 shapes, with populated `shape_dist_traveled` in meters).
- **The realtime feed carries both `trip_id` and `route_id`**, following
  predictable naming patterns aligned with static identifiers.
- **Upstream responses periodically return empty vehicle payloads** (~30–50%
  of HTTP 200 responses contain zero records during cache rebuilds). The
  ingestion pipeline treats `vehicle_count = 0` as a silent tick rather than
  an empty fleet.
- **`position.speed` is hardcoded to 0 and `bearing` is omitted**, necessitating
  sequential spatial delta calculation to determine velocity and heading.
- A significant share of vehicles report `schedule_relationship = ADDED`,
  confirming that live operations frequently diverge from static schedules.

---

## 3. Core Architectural Contributions

Rather than a simple consumer of transit APIs, **Where Is My Bus** is engineered as an autonomous, fault-tolerant transit tracking architecture:

1. **Probabilistic Arrival Ranges**: Calibrated confidence windows reflecting empirical travel time distributions, paired with explicit data provenance indicators.
2. **Dynamic Graceful Degradation**: Multi-tier operational resilience stepping down smoothly across fallback tiers (Live GPS -> Crowdsourced Telemetry -> Historical Segment Statistics -> Static Timetable) during feed or network outages.
3. **Crowdsourced Telemetry Imputation**: An opportunistic passenger beaconing architecture ("I'm on this bus") that maintains visibility for untracked or unlisted vehicles.
4. **Spatial Map-Matching Pipeline**: High-throughput PostGIS projection mapping noisy GPS coordinates to underlying route shape linestrings, handling lap boundaries and heading ambiguities.
5. **Offline-First Transit Mobility**: An on-device SQLite pack (12.2 MB, three tables: routes, places, ordered route stops) supporting stop search, route search, ordered stop sequences and direct-bus lookups with zero cellular connectivity. Ranked multi-leg journey planning, every timetable answer and every live tier need the network. This is the static skeleton of the network, not a tracking source, and the boundary is stated in the app rather than glossed over.
6. **Empirically Evaluated Travel Time Modeling**: Statistically robust hop passage extraction and 7-fold cross-validation with day-type (weekday/weekend) stratification.
7. **Verifiable Location Provenance (simulated)**: Every bus position can carry a location proof that follows the paper's protocol exactly: Algorithm 1 selects the nearest satellite on each of the four sides of the point of interest, Algorithm 2 turns signed, encrypted round-trip exchanges into ranges (`Rad = C(T_Y−T_X)/(2Nλ)`) and solves the four sphere equations (1)-(4), and Algorithm 3 recomputes the satellite-to-POI distances with equation (11). The same machinery selects the relay vehicle (`D_min` over verified vehicles only), which is the paper's actual security goal. Adapted from Paul, Dhal and Mary, *Relaying Vehicle Selection Protocol for a Road Intersection*, IEEE/ACM TON 32(3), 2024.

The first six are achievable from the public OTD feed alone, with zero users. The seventh is a designed protocol demonstration: the four satellites and their timestamps are simulated because there is no receiver hardware or satellite link, while the signatures, encryption and checks are real; that is always labelled in the API responses and docs (see `docs/location-proof.md`). The app does not display proofs - it focuses on bus tracking.

---

## 4. Core features

Priority order.

1. **Buses arriving at this stop, with ETA** — the primary screen
2. **Confidence-banded arrival times** — an empirical arrival interval reflecting real-world traffic variance
3. **Graceful degradation** — Live → Estimated → Timetable as data quality drops
4. **Data provenance indicator** — indicates data tier (live GPS, crowdsourced ping, historical average, or timetable)
5. **Route and schedule information** — route lists, stop sequences, timetables
6. **Buses between stops** — all buses running between any two stops
7. **Offline capability (static layer only)** — routes, stops, ordered stop sequences and search work with no network; timetables, ETAs, journey planning and live positions do not
8. **Delay and bunching alerts**
9. **Arrival alarms** — notify when approaching the destination stop
10. **Ghost bus reporting** — scheduled-but-untracked trips made visible
11. **GPS location proof — backend/API only** — the API attaches the paper's four-satellite proof to every bus position: Algorithm 1 picks the nearest satellite on the East, West, North and South sides of the point of interest; Algorithm 2 exchanges fresh random values, encrypted replies and signed Info, turns round trips into `Rad` and solves the four sphere equations (1)-(4); Algorithm 3 reports the equation (11) check. Relay-vehicle selection (nearest verified bus to the POI) is included, since that is the paper's actual goal. Simulated satellites/timestamps, real signatures, encryption and checks. Deliberately not shown in the app: the app's main feature is the bus tracking/ride screen. See `docs/location-proof.md`.

### Deliberately cut or downgraded

- **Boarding/alight detection via phone sensors** — CUT. Research-grade,
  needs labelled sensor data that cannot be collected here. Replaced with a
  manual "I'm on this bus" button.
- **Spoof rejection via cross-validation between riders** — DOWNGRADED to
  basic plausibility checks. Real cross-validation needs many concurrent
  riders on one bus.
- **Passenger-sourced positioning** — built and demonstrated, but presented
  as a designed contribution rather than a validated one. See constraints.
- **Real satellite verification** — DOWNGRADED to a simulated proof. There is
  no receiver hardware and no satellite link, so the satellite observables in
  a location proof are generated for the demo. The verification code, the
  attack faults and the measured false-accept/false-reject rates are real.
- **Proof screens in the app** — CUT deliberately at the user's request. The
  proof stays a backend/API contribution (`proof` on arrivals,
  `/location-proof`, `/relay-selection`); the rider's app focuses on bus
  tracking, with the ride/tracking screen as its main feature.

---

## 5. Constraints

- **Solo student project.**
- **The developer is in Guwahati, not Delhi. No fieldwork is possible.**
  Nobody can stand at a Delhi bus stop with a stopwatch.
- **No real users**, so anything depending on a crowd of Delhi riders cannot
  be validated in production.

This is why the project is designed around the public feed first and
crowdsourcing second. The feed-based system is fully buildable and verifiable
from a laptop anywhere.

Crowdsourcing is presented as an engineered architecture and simulated imputation pipeline.

---

## 6. Tech stack

**Mobile**
- Flutter (Dart) — chosen over React Native; closer to the developer's C++
  background, calmer toolchain for a solo build
- MapLibre (`maplibre_gl`) — maps, avoids Google Maps billing
- SQLite (`sqflite`) — on-device data for offline mode
- Riverpod — state management

**Backend**
- Node.js + TypeScript
- Fastify — API server
- `gtfs-realtime-bindings` — protobuf decoding
- Server-Sent Events — live updates to the app

**Data**
- PostgreSQL + PostGIS — main database and spatial queries
- Redis — live vehicle state, hot path
- Gzipped `.pb` files on disk — raw immutable archive
- SQL — the analysis and aggregation work

**Ops**
- Docker Compose for local Postgres+PostGIS
- The recorder runs on **Azure for Students** (`Standard_B2ats_v2`, UAE North
  — that subscription's closest allowed region, not India), as a systemd
  service. Chosen specifically because it needs **no credit card** — Oracle
  Cloud's Always Free tier was tried first and rejected for exactly that
  reason. See `recorder/DEPLOY.md` for the live deployment's real
  configuration and how to rebuild it.

**Environment**
- Develop on Windows via WSL2 (Ubuntu); keep code in the WSL filesystem
  (`~/projects/...`), not `/mnt/c/...`
- Flutter installs on Windows proper, not inside WSL
- Deploy on Linux

**Optional**
- C++ via `node-addon-api` for a performance-sensitive core — not required at
  this scale, purely a choice if wanted
- TimescaleDB if position history queries slow down

---

## 7. Phases (outline)

Build in this order. **The app is last, not first.**

- **Phase 0 — Recorder. DONE, running.** Deployed on Azure, systemd-managed,
  confirmed to survive a reboot. Fetches `VehiclePositions.pb` on a loop and
  writes it to disk. Nothing else. See `recorder/DEPLOY.md` for the live
  config.
- **Phase 1 — Look at the data. Static: done. Realtime: done for the archive
  collected so far, ongoing as more accumulates.** Static GTFS is profiled
  (`docs/static-feed-profile.md`) and loaded (`db/schema.sql`). The realtime
  archive is profiled (`docs/realtime-feed-profile.md`) and loaded
  (`db/schema_realtime.sql`, `tools/load-realtime.js`) — re-run the loader as
  the archive grows.
- **Phase 2 — Map-matching. In progress.** Turning a raw position into
  progress along a route. Stop offsets along each route are computed
  (`db/compute_stop_distances.sql`). The vehicle-position side - raw
  distance-along-route, then deciding which readings to trust
  (`db/schema_matching.sql`, `db/compute_vehicle_raw_progress_chunked.sql`,
  `tools/match-vehicle-progress.js`) - is built and validated on 2 recorded
  days, with three real bugs found and fixed along the way. See
  `docs/plain-explanations.md` for what they were. Re-validating on the full
  8-day archive next (`scripts/run-full-pipeline.sh`).
- **Phase 3 — Historical travel times.** Derive them from the archive.
- **Phase 4 — ETA + evaluation.** The milestone that de-risks the project.
- **Phase 5 — API. In progress.** The original ETA/journey/route endpoints are
  live. The stop-board read layer (`/feed/status`, `/stops/:id/arrivals`,
  `/routes/:id/detail`) is added, with replay from matched stop passages. The
  location-proof layer (`proof` on every arrival, `/location-proof`,
  `/relay-selection`) lives entirely in the API; the app does not render it.
- **Phase 6 — Flutter app. In progress.** The stop board and the
  tracking/ride screen (the app's main feature: follow the bus on a map with
  direction, next stop, arrival window, progress, full-screen map, view-route,
  alarm and share) are built, along with the plan and saved screens and a
  three-tab shell; see `docs/ui-redesign.md`. Plan results, saved stops,
  offline frequency and the replay speed control are next.

### Phase 0 is the only irreversible deadline

Historical feed data cannot be collected retroactively. Every day the
recorder is not running is evaluation data permanently lost. It must be
running before anything else is built.

---

## 8. Working conventions

1. **Look at real data before designing the schema.** Every wrong assumption
   about the feed costs a rewrite.
2. **Raw is immutable; everything else is rebuildable.** The recorder never
   parses and never deletes.
3. **Build the evaluation harness early.** Without a number, "I improved the
   ETA" is a feeling rather than a result.
4. **Script first, service second.** Don't wrap logic in an API until it is
   correct in a script.
5. **Simple, readable code.** No bit manipulation unless genuinely required.
   Prefer clear syntax over clever syntax.

### On AI assistance

Use it for boilerplate — protobuf glue, API scaffolding, Flutter screens,
Docker Compose, SQL migrations.

**Map-matching and ETA logic may now be written by AI too.** This project
originally kept that logic strictly hand-written, because it is what gets
questioned in the viva. That rule was deliberately relaxed on 2026-08-12,
after being reminded of the viva risk and choosing to accept it anyway.
From now on: AI can write this logic in full, but must always explain it in
plain language alongside the code, so the developer can still understand and
defend it. Trade-offs should still be talked through, not just silently
decided.

### Project map

`.ua/knowledge-graph.json` is a generated map of this repo — code, SQL, docs
and config in one graph, with layers and a guided tour that follows the real
build order. Read it to orient before exploring the tree.

It is derived data, never edit it by hand. Regenerate it with the
`understand` skill after a batch of changes; runs after the first are
incremental and only re-analyse what changed.

---

## 9. Sources

### Local data

The recorded realtime archive lives **outside this repo**, at:

```
C:\Users\nagga\Desktop\DATA FOR WIMB
  raw/<YYYY-MM-DD>/vp-<timestamp>.pb.gz   the immutable frames
  manifest/<YYYY-MM-DD>.jsonl             one line per fetch attempt
```

Set `DATA_ROOT` to that path when running anything under `tools/`. It is kept
off the Desktop project folder deliberately — the archive is immutable and must
never be caught up in a repo clean, and at 477 MB for two days it does not
belong in Git.

The static GTFS snapshot is `delhi_buses_static_gtfs_v1/` inside the repo,
gitignored (151 MB `stop_times.txt` alone exceeds GitHub's limit).

### External

- Open Transit Data Delhi — <https://otd.delhi.gov.in/documentation>
- OTD static data — <https://otd.delhi.gov.in/data/static>
- OTD realtime data — <https://otd.delhi.gov.in/data/realtime>
- DIMTS, AIS-140 based tracking — <https://www.dimts.in/ais-based-tracking.aspx>
