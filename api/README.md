# API — Phase 5

Serves the honest arrival estimate: how long until a bus reaches a stop,
as a **range with its provenance**, never a bare number.

Node 25 runs TypeScript directly, so there is no build step.

```bash
npm run api            # starts on :3000
npm run check-eta      # proves the ETA logic (24 checks, no server needed)
npm run check-journey  # proves the journey planner (52 checks, no server needed)
npm run check-arrivals # proves the stop board, replay, frequency fallback and destination filter
npm run check-location-proof  # proves the paper's 4-satellite protocol and relay selection (343 checks, no DB)
npm run test-api       # end-to-end over HTTP (134 checks, needs the server running)
```

Two different jobs. `check-eta` calls the logic directly and asks *is the
maths right*. `test-api` talks to the running service over HTTP and asks
*does it behave when a real, careless, or hostile client uses it* — bad
input, SQL injection, absurd numbers, concurrency, response times.

## Run the checks first

`check-eta.ts` exists because of CLAUDE.md working convention #4 — *"script
first, service second. Don't wrap logic in an API until it is correct in a
script."* It verifies Delhi-vs-UTC time handling, that the range widens
with distance and never inverts, that the estimate refuses rather than
guesses when data is missing, and — the important one — it re-runs a real
held-out-day experiment through the same code path the API uses, checking
the result against the accuracy `docs/eta-design.md` promises.

If those numbers ever drift apart, either the code or the design document
is wrong and both need looking at.

## Files

| file | what it is |
|---|---|
| `src/journey.ts` | the journey planner: two locations to ranked ways of travelling. Ranks by total time, routes on places, allows one change — all three from measurement, see `docs/journey-design.md` |
| `src/eta.ts` | turning a bus position into an arrival estimate with an honest range. Everything in it came from measurement — see `docs/eta-design.md` |
| `src/feed.ts` | is the official feed live, how old is the newest frame, which recorded days can be replayed |
| `src/arrivals.ts` | buses coming to a stop: replay from matched passages, live from the latest frame, batched ETA, frequency fallback, the optional destination filter, and the location-proof summary on each row (each proof built for that board's point of interest) |
| `src/gnss.ts` | the paper's satellite model: 12 simulated GEO candidates three per side, Algorithm 1's nearest-per-side choice, `Rad = C(TY−TX)/(2Nλ)`, the four-sphere solve of equations (1)–(4), and Algorithm 3's direction-ratio/triangle check of equations (5)–(11) |
| `src/location_proof.ts` | the trusted-authority verifier: one-time challenge, real RSA-OAEP challenge echo and ECDSA satellite signatures, ranges turned into a four-sphere position, Algorithm 3, the six paper faults, `verified`/`weak`/`rejected`, and the relay-vehicle selection (Algorithm 2 + Algorithm 3) |
| `src/routes.ts` | route meta, ordered stops, and the shape a bus actually follows |
| `src/confidence.ts` | the hop-quality counts turned into one plain-language confidence word |
| `src/db.ts` | one shared connection pool |
| `src/server.ts` | HTTP translation only, no logic of its own |
| `check-eta.ts` | proof the ETA logic is right, runnable on demand |
| `check-journey.ts` | proof the journey planner is right — including a pair verified to actually need a change |
| `check-arrivals.ts` | proof the stop board logic is right, including the replay and fallback paths |
| `check-location-proof.ts` | independent adversarial proof of the paper engine: Algorithm 1's four sides, equations (1)–(11), the `Rad` formula, the four-sphere solve, all six faults, the measured false-accept/false-reject table, and relay selection including "a spoofing nearest bus must not be selected" |

## Endpoints

### `GET /journey?fromLat=…&fromLon=…&toLat=…&toLon=…`

**The question the app exists to answer.** Two locations — not stop ids,
because a phone knows its coordinates and nobody knows they are standing
at stop 1278.

```bash
curl "localhost:3000/journey?fromLat=28.6752&fromLon=77.1325&toLat=28.6761&toLon=77.1160"
```

```json
{
  "options": [{
    "changes": 0,
    "totalMinutes": 10.9,
    "rangeMinutes": { "earliest": 7.5, "latest": 14.2 },
    "summary": "Take route 2433 from Shivaji Park",
    "breakdown": { "walkMinutes": 2.9, "waitMinutes": 3.4, "rideMinutes": 4.7 },
    "confidence": { "level": "high", "because": "…" }
  }],
  "assumptions": { "walkRadiusMetres": 800, "walkSpeedMetresPerMin": 83, "waitRule": "…" }
}
```

Three things worth knowing about the shape:

- **Ranked by TOTAL time, not ride time.** A faster ride on a rarer bus is
  a worse journey. Measured: route 2433 rides in 5.3 min and comes every
  6.4; route 2417 rides in 4.6 and comes every 10.7 — the faster ride
  loses. Computing this needs *observed* frequency, which the published
  timetable cannot provide.
- **Routes on places, not stop_ids.** Delhi lists ~1.9 stop_ids per real
  stop (one per direction). Routing on raw ids makes 5% of pairs look
  connected instead of the true 16.8%.
- **At most one change**, which covers ~87% of journeys. The rest get a
  clear refusal rather than a poor third leg.

A transfer answer names the frequency of *each* leg, which is often the
decisive fact:

```
81 min | Route 2229 to Police Station Najafgarh, then route 2273
  walk 5 + wait 32.8 + ride 43.3
  leg: 2229, 22 stops, bus every 5.5 min
  leg: 2273,  6 stops, bus every 60 min   <- this is why the wait is 33 min
  confidence: low
```

### `GET /journey/by-hour?fromLat=…&fromLon=…&toLat=…&toLon=…`

**"When should I travel?"** — the same journey costed for every service
hour. No bus app answers this, because it needs *observed* frequency: a
timetable generated by assuming constant speed cannot tell you that 16:00
is slower than 08:00.

```
ADVICE: Travelling around 8:00 takes about 7 minutes less than around 16:00.

  07:00  11.2min  via 2417  (high)
  08:00  10.9min  via 2417  (high)   <- best
  ...
  16:00  17.5min  via 2429  (low)    <- worst
  23:00  11.4min  via 1151  (medium)
```

Each hour is costed on its own rather than scaling one answer, because
**the best route changes with the hour** — 11 different routes win at
different times on the example above. A route that is frequent at 09:00
may be hourly at 21:00, which changes not just how long it takes but which
bus you should catch.

Hours outside 05:00–23:00 return `null`, not a guess: the feed has almost
no data there (hour 00 has usable numbers on 4% of cells).

> **Performance note.** The first version ran the whole planner 19 times
> and took **3.7 s**. Which routes serve two places does not change with
> the hour — only their timings do — so the options are found once and
> costed against all hours in a single query. Now **~220 ms**.

### `GET /eta?route=…&from=…&to=…`

The core question. `from` is where the bus is now, `to` is the stop being
asked about, both as positions along the route (get them from
`/routes/:routeId/stops`). Optional `at=<ISO date>` for testing a
particular time.

```bash
curl "localhost:3000/eta?route=2251&from=2&to=12"
```

```json
{
  "available": true,
  "stopsAway": 10,
  "estimate": { "seconds": 1031, "text": "17 min" },
  "range":    { "text": "11 min to 24 min" },
  "confidence": {
    "level": "high",
    "because": "Nearly every leg was estimated from buses on this same route, at this hour, on this kind of day."
  },
  "basis": {
    "legsByDetail": { "this-hour-this-daytype": 10, "any-hour-this-daytype": 0,
                      "any-day-any-hour": 0, "missing": 0 },
    "dayType": "weekday", "delhiHour": 19
  },
  "caveats": ["…"]
}
```

Three deliberate choices in that shape:

- **The range is never omitted.** The estimate and its range are one
  object, so a caller cannot accidentally show the number alone.
- **`basis.legsByDetail` is exposed, not hidden.** It says how many legs
  were estimated from data that genuinely matches the request versus how
  many fell back to a broader average. The estimate is auditable rather
  than a black box.
- **`confidence.because` is plain language**, meant to be shown to a
  commuter as-is.

Returns **422**, not a guess, when the answer would be knowably wrong —
a stop behind the bus, or legs that have never been observed (which would
make the total read too low).

`range.couldBeArrivingNow` is true when the honest band reached back
before the moment asked — i.e. the bus may already be pulling in. Found by
testing: on a thin route the band can legitimately run into the past
(estimate 358s, band low −402s → "arrives 44 seconds ago"). Meaningful as
a statistic, nonsense on a screen, and worse, the text field clamped it
while the number field did not — so a client reading the number disagreed
with one reading the text. The floor is now applied once to seconds,
timestamp and text together, with this flag preserving what the clamp
would otherwise throw away.

### `GET /feed/status`

Is the official feed live, how old is the newest non-empty frame, and which
recorded days can be replayed. The app calls this before it labels anything
`LIVE` or `REPLAY`.

### `GET /stops/:placeId/arrivals?at=…&windowMinutes=45&to=<destinationPlaceId>`

The stop board. With `at`, the answer is a replay of the recorded stop
passages around that moment. Without it, the answer uses the newest
non-empty frame and any active passenger beacons. Routes with no tracked
bus return observed frequency instead of a fabricated countdown.

Every arrival carries `source` (`official`, `passenger`, `replay`), a
range, confidence, the matched progress along the route, and a `proof`
(`ProofSummary | null`, described under *Location proof* below). A replay
answer is always labelled `mode: "replay"`; the endpoint never calls itself
live when the newest frame is older than 90 seconds.

**`to` is the "Where to?" filter.** Give it a destination *place id* (a place
id, not a raw stop id — see `/stops/search`) and the board narrows to buses
that reach that place after this stop **without a change**: a route counts
only when the destination appears later in that route's own stop order. Each
bus is then costed to the destination stop, so `stopsAway`, `eta` and `range`
answer "when do I get there", not "when does the bus arrive here". The
frequency fallback is filtered the same way, so it only names routes that
carry the rider to the destination.

```bash
curl "localhost:3000/stops/572/arrivals?to=818"
```

```json
{
  "place":       { "placeId": 572, "name": "Shivaji Stadium", "lat": 28.63, "lon": 77.22 },
  "destination": { "placeId": 818, "name": "Shivaji Park", "lat": 28.6386, "lon": 77.2241 },
  "noDirect": false,
  "arrivals": [{
    "routeShortName": "RL-79DOWN",
    "currentStopSequence": 52,
    "targetStopSequence": 62,
    "stopsAway": 10,
    "eta": { "text": "16 min" },
    "range": { "text": "10 min to 24 min" }
  }]
}
```

`destination` is always present (`null` when no `to` was given) and `noDirect`
is always a boolean, so one response shape covers both cases. Without `to` the
board is exactly what it always was. An invalid `to` is a **400** (`to must be
a positive whole number place id`); a place id that is not in the current
snapshot is a **404**.

**When no single route reaches the destination after this stop**, the board
does not invent rows: `arrivals` and `frequency` are empty, `noDirect` is
`true`, and `caveats` carries the honest fallback:

> No direct bus from this stop to <name>. The Plan tab can look for a trip
> with one change.

`windowMinutes` (5–120, default 45) filters on arrival at the chosen
destination when `to` is set.

The `proof` rules, in one place:

- Every proof is built for **this board's point of interest**: the board
  place's coordinates and name. Paul, Dhal and Mary run the protocol for one
  POI — Algorithm 1 selects the nearest satellite on each of its four sides —
  so `ProofSummary.poi` travels on every row and the proof screen names the
  stop the check was measured from.
- `passenger` rows carry `proof: null` — a passenger's phone is not the bus's
  GPS unit, and the UI labels it "No bus GPS proof".
- `official` rows are verified from the raw feed position
  (`match.rawLat`/`match.rawLon`) at `recordedAt`, with `routeOffsetM` from
  the map match. A fix younger than an hour is checked `live`, older as
  `archived`.
- `replay` rows are verified from the **nearest actual archived GPS fix**
  within ±3 minutes of the board moment (raw `vehicle_position` row, not the
  interpolated board position), so the proof is about a real reading. Its
  `routeOffsetM` is the distance from that archived fix to the **route line**
  (the fix snapped at its own position) — never the distance from the fix to
  the shown board point, which would include how far the bus drove between
  the fix and the board moment and make an on-route bus look off-route. When
  the archive has no such fix, `proof` is `null` and the response adds
  `"No recorded GPS fix was attached to this position, so no location proof
  is shown."`
- A `rejected` proof caps `confidence.level` at `low` and prefixes the
  explanation with "The bus's GPS check failed. "; a `weak` proof caps it at
  `medium` and prefixes "The GPS fix is weak. ". The numeric ETA is never
  changed — it was measured on the same recorded buses either way.

### `GET /routes/:routeId/detail?at=…&to=…`

Everything the route screen needs in one request: route meta, simplified
shape, ordered stops, buses on the route, and the ETA to one chosen stop
sequence. `to` is a stop sequence from the stops list; omit it to see the
buses without a target. Every bus in `runs` carries the same `proof`
summary as the stop board (one shared helper attaches both), so the ride
screen and the board cannot disagree about a bus's GPS check. The proof's
point of interest is the chosen target stop — its physical place when known,
else the stop's own coordinates — or, without a target, the route's **first
stop**, so every bus is still checked against somewhere real.

### `GET /location-proof?vehicleId=…&lat=…&lon=…&poiLat=…&poiLon=…&poiName=…&at=…&fault=…&offsetM=…`

The verifier demo the app's proof screen and curl use: re-run the paper's
protocol for a position the caller chooses, and return the full
`LocationProof` (verdict, checklist, the four chosen satellites, the satellite
message table, the four-sphere solution and the Algorithm 3 table).

`poiLat`/`poiLon` are **required**: the protocol is run for one **point of
interest** — Algorithm 1 picks the nearest satellite on each of its four
sides from it — so a fix with nothing to measure it against is not a proof.
`poiName` is optional and only labels it in the UI.

```bash
curl "localhost:3000/location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165"
curl "localhost:3000/location-proof?vehicleId=DL1PD0001&lat=28.6139&lon=77.2090&poiLat=28.6323&poiLon=77.2165&fault=spoof"
curl "localhost:3000/location-proof?vehicleId=DL1PD6034&lat=28.625690460205078&lon=77.20665740966797&poiLat=28.6323&poiLon=77.2165&poiName=Shivaji%20Stadium&at=2026-08-16T07:59:53Z&fault=none"
```

```json
{ "ok": true, "proof": { "status": "verified", "label": "GPS verified", "poi": { "lat": 28.6323, "lon": 77.2165, "name": "Shivaji Stadium" }, "...": "..." } }
```

- `vehicleId` required, non-empty; `lat`/`lon` required and in range.
- `poiLat`/`poiLon` required and in range (the paper's point of interest);
  `poiName` optional label.
- `at` optional ISO fix time (default now). A recorded time is verified in
  `archived` mode.
- `fault` optional, one of `none`, `spoof`, `replay`, `tamper`, `delay`,
  `freeze`. An unknown value is a 400 that lists the allowed ids — never a
  silently honest fix.
- `offsetM` optional: the fix's distance from the bus route line in metres.

This endpoint is **not an authentication boundary**. Anyone may ask for any
vehicle id and coordinates, and the answer is always a SIMULATED proof: it
shows that the verification pipeline works, not that a real Delhi bus was
checked. The app's "Try a bad fix" picker calls it with each fault id.

### `GET /relay-selection?placeId=…&at=…` (or `?lat=…&lon=…&at=…`)

The paper's relay-vehicle selection. At a road intersection — here, a bus stop
— the trusted authority wants the nearest vehicle it can honestly trust to
relay its messages. Algorithm 2 computes every candidate bus's distance `D` to
the point of interest from the four-sphere solution; Algorithm 3 reports its
triangle check; the nearest vehicle whose proof is **verified** becomes the
relay. A rejected vehicle can never be selected — a spoofed, replayed, delayed,
tampered or frozen bus is rejected by its own proof before ranking, stays in
`candidates` with its reason, and is skipped by `selected`. A weak proof passes
every required check but not the optional route check, and is not eligible
either: the paper accepts a vehicle only when the checks pass, so the relay is
always verified.

Two optional demo parameters make the security property visible live:
`faultVehicle=<vehicleId>&fault=<attack>` injects one of the six paper attacks
into that candidate's exchange (both parameters required together). The
candidate stays in the list with its rejection reason, `dToPoiM` is still
measured from the TA-solved position, and `selected` moves to the next verified
bus. The honest run is unchanged.

```bash
curl "localhost:3000/relay-selection?placeId=572&at=2026-08-16T08:00:00Z"
curl "localhost:3000/relay-selection?lat=28.6323&lon=77.2165&at=2026-08-16T08:00:00Z"

# demo: make the nearest bus (990A, 43.1 m) spoof its claim
curl "localhost:3000/relay-selection?placeId=572&at=2026-08-16T08:00:00Z&faultVehicle=DL1PD8920&fault=spoof"
# -> 990A rejected (claim-matches-solution), selected relay becomes 966EXT at 555.1 m
```

```json
{
  "ok": true,
  "relay": {
    "protocol": "Algorithm 2 + Algorithm 3",
    "simulated": true,
    "poi": { "lat": 28.63239, "lon": 77.21551, "altM": 216, "name": "Shivaji Stadium Terminal" },
    "deltaTSeconds": 30,
    "satellites": [
      { "side": "E", "satelliteId": "GEO-E1", "ecef": { "x": -12693441.12, "y": 36351649.09, "z": 17701430.93 }, "distanceToPoiM": 36921577.7 },
      { "side": "W", "satelliteId": "GEO-W1", "ecef": { "…": "…" }, "distanceToPoiM": 37336111.1 },
      { "side": "N", "satelliteId": "GEO-N1", "ecef": { "…": "…" }, "distanceToPoiM": 37061088.2 },
      { "side": "S", "satelliteId": "GEO-S1", "ecef": { "…": "…" }, "distanceToPoiM": 37470590.5 }
    ],
    "candidates": [
      { "vehicleId": "DL1PD8920", "routeId": "2557", "routeNumber": "990A",
        "claim": { "lat": 28.63266, "lon": 77.21574 }, "solved": { "lat": 28.63270, "lon": 77.21578 },
        "dToPoiM": 43.1, "status": "verified", "rejectedCheck": null, "algorithm3Passed": true },
      { "vehicleId": "DL1PD8148", "routeId": "2513", "routeNumber": "966EXT", "…": "…",
        "dToPoiM": 555.1, "status": "verified", "rejectedCheck": null, "algorithm3Passed": true }
    ],
    "selected": { "vehicleId": "DL1PD8920", "routeId": "2557", "routeNumber": "990A",
                  "dToPoiM": 43.1, "status": "verified", "algorithm3Passed": true },
    "selectedAlgorithm3": { "passed": true, "maxDifferenceM": 0, "toleranceM": 500,
                            "sides": [ { "side": "E", "differenceM": 0, "passed": true, "…": "…" } ] },
    "caveat": "Simulated: the four satellites and their timestamps are generated for the demo. The signatures, encryption and checks are real, so a lying or delayed candidate is genuinely rejected - but this does not prove anything about Delhi's real feed."
  }
}
```

- `placeId` preferred, or `lat`/`lon`; the coordinate form resolves the nearest
  place within 1500 m using the same place rules as `/stops/near` (404 when
  none is that close).
- `at` optional ISO moment. With it the candidates are the replayed stop board
  for that moment; without it, whatever the newest feed and passenger beacons
  can honestly offer.
- Candidate positions use the raw fix the bus reported when the board row
  carries one, otherwise the snapped point on its route. A row with neither is
  skipped, never placed at (0, 0).
- Each candidate carries the `claim` **the protocol judged** (a spoofed bus is
  listed with its lie) and the position the TA `solved` from the trusted
  ranges. `dToPoiM` is measured from the **solved** position, so a falsified
  claim cannot move a candidate closer to the POI — it only gets it rejected.
- `candidates` is sorted by `dToPoiM` ascending; `selected` is the nearest
  **verified** candidate and `selectedAlgorithm3` is its per-side triangle
  table (Algorithm 3).
- **Simulated.** The four satellites and their timestamps are generated
  because there is no receiver hardware or satellite link here; the ECDSA
  signatures, the RSA-OAEP challenge echo and every check are real, so an
  injected fault really is rejected. The response's `caveat` says this, so a
  client cannot show the selection without it.

### `GET /routes/:routeId/stops`

The stops along a route in order, with their position numbers. Needed to
turn "the stop I'm standing at" into the `from`/`to` numbers above.

### `GET /stops/near?lat=…&lon=…&radius=500`

Stops near a point, nearest first, static GTFS so it works with no live
feed. **One row per place, not per raw stop_id** — Delhi lists a separate
stop_id per direction of the same physical stop, and this used to show
"Shivaji Stadium Terminal" and "Regal / Palika Kendra" twice each near
Connaught Place. Routes through `stop_place` (the same table
`/journey` uses) and returns each result's `place_id`.

### `GET /stops/search?q=…&limit=10`

Find a stop/place by typed name (`q`, at least 2 characters). Same
place-dedup as `/stops/near` — one row per physical place. Prefix matches
("Shivaji…" for "sh") are ranked ahead of matches buried mid-name.

### `GET /routes/search?q=…&limit=10`

Find a route by its number (`q`, at least 1 character). `route_short_name`
carries direction as a suffix (`764UP` / `764DOWN` — see `db/schema.sql`),
so a search returns both directions as separate rows on purpose; a rider
has to pick the one going their way. An **exact** number match (`764UP`/
`764DOWN`) is ranked ahead of longer route numbers that merely start with
the same digits (`764B…`, `764STL…`) — real, different Delhi routes that
would otherwise tie on a plain prefix match and sort alphabetically ahead
of the route someone actually typed.

### `GET /health`

Service up, and can it reach its data.

## Location proof — what it is and what it is not

Every bus position can carry a small `proof` object saying whether its GPS
fix passed the paper's verification protocol, and how well the four simulated
satellites supported it. It belongs to this project's "every number says
where it came from" idea: the position is recomputed from measurements rather
than believed.

The protocol is adapted from Paul, Dhal and Mary, *Relaying Vehicle Selection
Protocol for a Road Intersection*, IEEE/ACM Transactions on Networking 32(3),
2024. It is implemented as the paper writes it, and the mapping is:

| Paper | Where Is My Bus |
|---|---|
| Trusted Authority (TA) | the verifier in `src/location_proof.ts` |
| Satellites `s1…sn` | 12 simulated GEO candidates in `src/gnss.ts`, 3 per side at the paper's ~36,000 km scale |
| Point of interest `(g,h,i)` | the stop the board or route screen is about; `ProofInput.poi` is required |
| Algorithm 1 — `Y = sqrt((a−g)² + (b−h)² + (c−i)²)`, keep the nearest per side `S_E / S_W / S_N / S_S` | `selectNearestSatellites(poi)` — exactly four satellites are accepted downstream, one per side |
| Algorithm 2 — challenge `R`, encrypted `E_inf`, `T_X`/`T_Y`, signed `Info` | one-time challenge; real RSA-OAEP challenge echo and real ECDSA satellite signatures |
| Algorithm 2 — `Rad = C·(T_Y − T_X) / (2·N·λ)` | `radFromTimestamps()`; one `Rad` per satellite (`N·λ = 1` in the simulation) |
| Algorithm 2 — equations (1)–(4), four spheres | `solveFourSpheres()` — exact linearised solve, one radius per satellite |
| Algorithm 2 — `D`, `D_min`, nearest vehicle | `selectRelayVehicle()` — candidates ranked by `dToPoiM`; the nearest **verified** vehicle wins |
| Algorithm 3 — direction ratios (5), (7), line equations (6), (8), angle (9)/(10), `Y_new` (11) | `algorithm3Check()` — one row per side, tolerance `RANGE_TOLERANCE_M` = 500 m; run on the TA-solved position (see the honest note below) |
| Relay-vehicle selection at an intersection | `GET /relay-selection` (documented above) |

**A note on Algorithm 3, stated honestly.** As published, Algorithm 3's input
is the position the TA already solved from the trusted ranges: `Z1` and `Z2`
are the POI→vehicle and satellite→vehicle distances, and equation (11) is
therefore **the law of cosines** on a triangle whose third side is the
satellite-to-POI distance. For any point it reproduces `Y` exactly — it is a
consistency display for the solve, not an independent discriminator. The
engine shows this: honest difference `0.00 m` on all four sides, and even a
deliberately delayed exchange (whose four-sphere residual is ~340 km) still
closes to `0.00 m`. The security comes from Algorithm 2: the ranges are
measured by the trusted side from satellite timestamps the vehicle cannot forge
(Algorithm 3 cannot bypass the range solve), and our
`claim-matches-solution` check compares what the *feed* claimed against the
TA-solved position. Relay selection is where the paper's security goal
actually lands: `D` is computed from the solved position, so a falsified claim
does not move `D` at all — it only gets the candidate rejected — and a
rejected candidate is never selectable.

The six faults are deterministic, documented, and each trips a named check.
A proof is `rejected` when a required check fails; `weak` when every required
check passes but the optional route check does not; otherwise `verified`:

| fault | what the dishonest or broken unit does | first failing check |
|---|---|---|
| `none` | honest fix | — (`verified`) |
| `spoof` | claims a position 1.5 km away | `claim-matches-solution` |
| `replay` | replays an earlier round's information (challenge 10 min old) | `tsat-fresh` |
| `tamper` | flips one byte of a satellite signature | `signature-valid` |
| `delay` | replies 2 ms late, inflating every `Rad` | `four-spheres-consistent` |
| `freeze` | reports its position from 10 minutes ago | `claim-matches-solution` |

The verifier's checklist, in the order the app renders it:

| id | required | passes when |
|---|---|---|
| `tsat-fresh` | yes | the challenge is at most ΔT = 30 s old and was never used |
| `signature-valid` | yes | all four satellite ECDSA signatures verify over `Info` |
| `challenge-echo` | yes | the decrypted `E_inf` carries the same `R` and vehicle id (real RSA-OAEP) |
| `ranges-plausible` | yes | every `Rad` is 30,000–60,000 km — a GEO-scale range |
| `four-spheres-consistent` | yes | equations (1)–(4) solve with a residual of at most 250 m |
| `claim-matches-solution` | yes | the claimed fix is within 25 m of the four-sphere solution |
| `algorithm3-consistent` | yes | all four equation (11) distances agree within 500 m (reported consistency — see the note above) |
| `route-plausible` | no | when a route offset is supplied, the fix is within 50 m of the route line |

`check-location-proof.ts` proves this independently and adversarially:
Algorithm 1's nearest-per-side choice, the `Rad` formula, equations (1)–(11),
the four-sphere solve, Algorithm 3, the real cryptographic failures on tamper
and replay, all six faults, and relay selection — including that a **spoofing
nearest vehicle cannot become the relay**. It needs no database. The full JSON
shape is frozen in
[`scratch/paper-fidelity-contract.md`](../scratch/paper-fidelity-contract.md),
which supersedes `scratch/location-proof-contract.md` for the protocol.

**What it is not — always say this when showing a proof:**

> Simulated: the four satellite readings behind this proof are generated for
> the demo, so the check shows that the verification pipeline works — not that
> Delhi's official feed is honest. The official feed publishes a bare position
> with no satellite measurements and no signature.

The verification code, the fault injection and the measured false-accept /
false-reject rates are real; the satellite observables are not. Replay proofs
are built from the raw archived GPS reading in `vehicle_position`, and that
table currently holds **only 2026-08-16** (21.8M rows from 15 Aug 23:59Z to
16 Aug 18:43Z). So replay proofs appear on boards replayed for 16 Aug (for
example `?at=2026-08-16T08:00:00Z`, 13:30 IST); other replay days correctly
show `proof: null` with the caveat instead of inventing a fix. When the
recorder runs again, live `official` rows carry proofs immediately.

## What is deliberately missing


**There is no official live feed to serve.** The recorder was deliberately
stopped on 2026-08-19. The stop board (`/stops/:placeId/arrivals`) is built
and returns replayed positions from the matched passages, passenger
beacons, and observed frequency. It never labels a recorded answer `LIVE`:
if the newest frame is older than 90 seconds, it says so and steps down.

The screen we refuse to build is the one that shows a bus moving on a map
and calls it live when it is not. When the recorder runs again, the same
endpoint reads the newest frame and the app changes tier without a rewrite.

## Known limits

Inherited from the model — full detail in
[docs/eta-design.md](../docs/eta-design.md) §7:

- Built from **one week** of data (10–16 Aug 2026).
- **Weekend estimates rest on two recorded days** and are weaker. The API
  says so in `caveats` when the request falls on a weekend.
- **Hour-specific data thins out on long routes.** A 176-stop route
  spreads its observations across 48 hour/day-type buckets and lands near
  the trust threshold, so more legs fall back to broader averages. This is
  visible per request in `basis.legsByDetail` rather than hidden.
- **No official live position**, so the top tier is replay/passenger/
  frequency today. Every answer says which one it is.
- **Location proofs are simulated.** The four satellites, their ranges and
  timestamps are generated for the demo, because the public feed carries no
  observables; the cryptographic checks, the six faults and the measured
  false-accept/false-reject rates are real. A proof never claims Delhi's feed
  is honest.
- **Replay proofs need raw archived positions**, which currently exist only
  for 16 Aug 2026. Other replay days show `proof: null` plus a caveat rather
  than a proof built from an interpolated position.
