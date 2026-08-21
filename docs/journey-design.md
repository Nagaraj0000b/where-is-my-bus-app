# Journey-first design — the app answers travel, not bus-picking

**Status: built.** `GET /journey` and `GET /journey/by-hour` are live in
the API ([api/src/journey.ts](../api/src/journey.ts)), proved by 52 checks
in `npm run check-journey` before being wrapped in HTTP, plus 101
end-to-end HTTP checks in `npm run test-api`.

This note records the reframe of the user-facing design and the
measurements behind it — including two that overturned assumptions stated
earlier in the same session.

---

## 1. The reframe

CLAUDE.md's feature list is written bus-first: *"buses arriving at this
stop"*, *"buses between stops"*. But the person holding the phone does not
want a bus. **They want to be somewhere else.** Which bus is a means, and
it only becomes the interesting question *after boarding* — at which point
it changes to "which stop is next, when do I get off".

So the primary screen is **"where do you want to go?"**, and the answer is
a journey, not a list of vehicles.

This splits the app cleanly in two:

| phase | the user's question | what the app shows |
|---|---|---|
| **before boarding** | how do I get there, and when should I leave | walk → wait → ride → total, and which routes work |
| **after boarding** | am I nearly there | stops remaining, when to get off, alarm |

That boundary is also the natural home for CLAUDE.md's manual **"I'm on
this bus"** button (§4) — the deliberate replacement for the cut
sensor-based boarding detection.

---

## 2. What the user enters, and what comes back

The user gives two **locations** — not stop IDs. A phone knows its
coordinates; nobody knows they are standing at `stop_id 1278`.

Verified working end to end against real data:

> **Shivaji Park → Ordinance Depot**
> Walk 3 min · Wait ~3 min · Ride 5 min
> **About 11 minutes**
> Take route **2433, 2455 or 2544** — whichever comes first
> *From 9.7M observed passages. Weekday mornings.*

The pipeline behind that, all of which already exists:

```
two lat/lon points
   ↓  PostGIS radius search on stops        (already exposed: /stops/near)
candidate boarding and alighting stops, with walking distance
   ↓  stop_times + trips: routes serving both, in the right order
route options
   ↓  route_segment_travel_time (Phase 3/4 model)
ride time, with confidence
   ↓  observed_stop_passage: how often that route really showed up
wait time
   ↓
ranked by TOTAL = walk + wait + ride
```

### The ranking insight

Ranking by ride time gives the wrong answer. A measured example:

| route | ride | bus every | wait | **total** |
|---|---|---|---|---|
| 2433 | 5.3 min | 6.4 min | 3.2 min | **8.5 min** |
| 2417 | **4.6 min** | 10.7 min | 5.4 min | 10.0 min |

Route 2417 has the **fastest ride** and is the **worse journey**, because
it comes less often. Only total time — what the traveller actually
experiences — is a correct ranking, and computing it requires *observed*
frequency. The published timetable cannot support this, because its times
are fabricated.

The planner also picks the boarding stop by total time, not by proximity:
in testing it chose a stop 101 m away over one 162 m away because the
service there was better.

---

## 3. The transfer problem — an assumption that was wrong

Earlier in this session I said Delhi's route density looked high enough
that transfers might be rare. **That was wrong, and it came from
generalising a cherry-picked example** (two stops that happened to share
84 routes).

Measured properly — 400 random stop pairs between 2 km and 10 km apart,
all at stops with real observed service:

| | |
|---|---|
| pairs tested | 400 |
| **directly connected by one route** | **20 (5.0%)** |
| average route choices when direct | 3.4 |

**95% of journeys need at least one change.** A direct-only journey
planner would answer about one query in twenty.

Extending to one transfer (60 pairs, exact shared stop required):

| | |
|---|---|
| direct | 4 (6.7%) |
| reachable with **one** change | 29 (48.3%) |
| needs two or more | 27 (45.0%) |
| **within one change** | **55%** |

### …but those numbers were themselves wrong, for a fixable reason

Both tests above required an **exact shared `stop_id`**, and Delhi's GTFS
lists a separate stop_id for each direction of the same physical stop —
often several more for one junction. So a route serving the far side of a
road counted as not serving the stop at all.

Measured: **6,872 stops are only 3,649 real places** (1.88 stop_ids each).
Merging stops within 100 m into one "place"
([db/schema_stop_places.sql](../db/schema_stop_places.sql)) and re-running
the identical tests:

| | raw stop_ids | **places (100 m)** |
|---|---|---|
| directly connected | 5.0% | **16.8%** |
| direct (transfer sample) | 6.7% | **18.0%** |
| reachable with one change | 48.3% | **68.7%** |
| needs two or more | 45.0% | **13.3%** |
| **within one change** | 55.0% | **86.7%** |

Same city, same routes, same queries. **More than three times the direct
connectivity, and 87% coverage within one change** — purely from not
double-counting one physical place as two.

### Design consequences

1. **Route on places, never raw stop_ids.** This is not a UI nicety, it is
   a correctness issue: stop-level routing silently loses two thirds of
   the real connections.
2. **One transfer covers ~87% of journeys.** That is a viable product.
   Two-transfer routing can wait, and the remaining ~13% should be told
   honestly that no simple route exists rather than shown a bad one.
3. **Direct-only is not viable** — it answers under one query in five.

### Why 100 m, and not more

Clustering was tested at three radii across all 6,872 stops:

| radius | places | stops per place |
|---|---|---|
| **100 m** | **3,649** | **1.88** |
| 200 m | 2,505 | 2.74 |
| 300 m | 1,544 | 4.45 |

100 m merges direction-duplicates and both sides of a road without
over-merging. Larger radii creep up because DBSCAN links transitively — if
A is near B and B near C, all three join even when A and C are far apart —
so by 300 m genuinely separate stops chain into one blob.

100 m is an **identity** radius ("is this the same place"), deliberately
*not* a walking-transfer radius. If the planner later wants to allow a
300 m walk between distinct places, that belongs in the planner as a
distance test, not baked into identity where it would corrupt it.

Spot-checking the merges shows it doing the right thing: `GTB Nagar`,
`GTB Nagar / GTB Nagar Metro Station` and `GTB Nagar / Haqiqat Nagar` all
collapse to one place, which is what a traveller sees.

---

## 4. Why "frequency", not a departure timetable

There are two things the word "timetable" can mean, and only one of them
can be honest here.

**What can be given reliably — a frequency timetable:**

> ISBT Nityanand Marg, weekdays: buses every ~15 min at 07:00, every ~18
> min at 10:00 (161 buses/hour across 88 routes), every ~27 min at 14:00.

**What cannot honestly be given — a departure timetable** ("the 09:05
bus"). Delhi buses do not run to a fixed schedule, and OTD's published
times are, by its own documentation, *"a rough estimate generated by
assuming a constant speed of travel"* (CLAUDE.md §2). Printing "09:05"
would be inventing precision that does not exist — precisely the failure
this project exists to expose.

For Delhi the frequency answer is also the more *useful* one. "Every 7
minutes" tells you to just go. "The 09:05" tells you to trust a number
that will be wrong.

Because service varies so much by hour, the hourly frequency table doubles
as a genuine planning tool: it tells you *when* to travel, not only how.

---

## 5. What this delivers against CLAUDE.md

One screen covers four listed features at once, with **no live feed and no
recorder**:

| # | Feature | How this delivers it |
|---|---|---|
| 1 | Buses arriving at this stop, with ETA | most of its practical value, in observed form |
| 2 | Confidence-banded times | the existing ETA model and bands carry through |
| 5 | Route and schedule information | a **real** timetable replacing the fabricated one |
| 6 | Buses between any two stops | this is exactly the journey query |

It also supports the project's central claim more directly than a live map
would: *OTD publishes a timetable generated by assuming constant speed; we
publish one measured from 9.73 million observed passages at 6,512 stops.*

Live positions layer on top later, upgrading *"wait ~3 min typically"* to
*"the next one is 400 m away"* — an improvement to one number, not a
different product.

---

## 6. Open items before building

1. ~~**Measure walking transfers.**~~ **Done** — see §3. Routing on places
   rather than stop_ids lifts one-change coverage from 55% to **86.7%**.
2. ~~**Deduplicate stops.**~~ **Done**, including the UI-facing half.
   `stop_place` table built and documented
   ([db/schema_stop_places.sql](../db/schema_stop_places.sql)); `/stops/near`
   was still querying raw `stops` and showing the same physical stop twice
   (found while checking this list off - "Shivaji Stadium Terminal" and
   "Regal / Palika Kendra" each appeared twice near Connaught Place). Now
   returns one row per place, using the nearest stop_id's name.
3. **Two-transfer routing** for the remaining ~13%, or a clear "no simple
   route" answer. Deliberately deferred — 87% coverage is a product, and
   an honest refusal beats a bad third leg.
4. ~~**Confidence on frequency.**~~ **Done** — `describeConfidence` in
   `journey.ts` checks `days_seen` against the same 3-day threshold the ETA
   model uses, alongside how well-observed the ride time is. A route with
   an unobserved frequency is marked `low` even if its ride time is solid.
5. **Walking speed.** Currently assumed 83 m/min (5 km/h). Fine as a
   default, worth stating in the UI rather than hiding.
6. **Weekend data remains thin** — two recorded days. Every weekend
   figure inherits that weakness.

---

## 7. The endpoint, as built

```
GET /journey?fromLat=&fromLon=&toLat=&toLon=&at=
```

Backed by three precomputed tables, because joining 3.85M `stop_times`
rows per request would be far too slow:

| table | rows | what it answers |
|---|---|---|
| `stop_place` | 6,872 -> 3,649 places | which stop_ids are the same place |
| `route_place` | 87,718 | which routes call where, in order |
| `place_route_frequency` | 1,454,317 | how often each route really turns up |

Measured response times: **~17-20 ms** for both direct and one-change
journeys, on a warm cache. The transfer query benchmarked at ~180 ms cold
on a long cross-city pair, so that is the honest worst case rather than
the typical one.

### A note on testing the transfer path

Worth recording, because it nearly shipped untested. The transfer code
passed its first two test attempts **without ever executing**:

1. The first test pair turned out to have a direct route, so the planner
   never needed a change.
2. The second used two *places* verified to have no direct route — but the
   planner searches an 800 m radius and legitimately reached a nearby place
   that *was* directly connected. Correct behaviour, useless as a test.

Only running the real planner across random distant pairs until one
actually returned an option with a change in it produced a usable case.
The lesson is the same one cross-validation taught in Phase 4: **a test
that passes without running the code it claims to test is worse than no
test**, because it buys false confidence.
