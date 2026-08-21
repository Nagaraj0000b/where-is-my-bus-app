# Plain-English explanations

Plain-language write-ups of things built in this project, kept here so they
can be reused directly — in the project report, the viva, or anywhere else
a clear, jargon-free explanation is useful. No fancy terms, per
[RULES.md](../RULES.md).

Each entry: what the problem was, in plain words.

---

## Working out how far into its route each stop sits (2026-08-12)

We have a map line drawn for every bus route. We know the total length of
each line in real metres. What we didn't know is: for each stop on that
route, how far into the line does it sit? Like knowing a road is 10 km
long, but not knowing that the third bus stop is at the 2.3 km mark. The
official data left this blank for every single stop, on purpose — it's
just missing.

The fix: for each stop, find the closest point on its route's line, and
read off how far into the line that point is. Filled in for all 3.85
million rows in the timetable. See
[db/compute_stop_distances.sql](../db/compute_stop_distances.sql).

One known gap: for about 3.5% of trips (4,227 out of 121,844), the numbers
go backward somewhere along the trip — most likely because that route's
line loops back near itself (e.g. a bus depot loop), so the "closest point"
calculation picked the wrong pass of the loop. Measured, not yet fixed.

---

## A bus getting stuck because we stopped believing it (2026-08-16)

When a new GPS reading arrives for a bus, we check whether it makes sense:
could a real bus have got from where we last saw it to here, in the time
that passed? If not, we don't believe the reading and keep showing the last
position we trusted.

That part was right. The mistake was in what we remembered afterwards. When
we rejected a reading, we kept the old *position* but moved the *clock*
forward to the rejected reading's time. So the next reading was measured
against a position that hadn't moved, over a gap of time that kept
shrinking — which made a perfectly ordinary bus look like it was travelling
impossibly fast. So we rejected that one too. And the next. Once a bus fell
into this, it usually stayed stuck.

How bad it was, measured on two days of real data:

| | |
|---|---|
| readings rejected overall | 22.7% |
| rejected *right after* another rejection | 81.9% |
| rejected right after an accepted one | 3.9% |
| average stuck run | 7.9 readings (~1.5 minutes) |
| worst stuck run | 195 readings — about 11 hours frozen |

That last row matters for the whole point of this project: a bus frozen on
one spot for 11 hours is exactly the "stale position shown as live" that
this app is supposed to refuse to do.

The fix is one line of thinking: if we didn't believe a reading, we learned
nothing from it, so we shouldn't update anything at all — not the position,
and not the clock. Then the next reading is compared against the last
*good* fix and the true time since it. See
[tools/match-vehicle-progress.js](../tools/match-vehicle-progress.js).

---

## Why we only keep a couple of days in the database at a time (2026-08-16)

The recorded files themselves are small — about half a gigabyte per day of
recording. The database built from them is not: one day of bus positions
becomes roughly 6 GB of database, because every bus reports its position
every ten seconds and that is millions of rows a day.

Loading eight days at once produced a 54 GB database and filled the laptop.
Two things about that were worse than expected, and both are worth knowing:

1. **Emptying the tables did not give the disk space back.** Docker keeps
   all its data inside one big file on Windows, and that file only ever
   grows. Deleting rows frees space *inside* the file, and Windows still
   sees the file at its largest-ever size.

2. **The official "shrink the file" tool did nothing either.** It can only
   reclaim parts of the file that have been wiped to zeroes, and deleting
   data does not wipe it — it just marks it reusable. The tool reported
   success and reclaimed nothing. In the end the file had to be deleted
   outright and rebuilt, which is safe here only because everything in it
   can be rebuilt from the recorded files.

The rule that follows: never hold more than about two days of bus positions
in the database at once. Positions are working material, not the product.
What we actually want out of them — how long buses really take between
stops — is a small table. Process a day, boil it down, drop the positions,
move to the next day. The database then stays about the same size no matter
how many months the recorder runs.

The recorded files stay on the recorder machine, which has months of room,
and are pulled down a day at a time as needed.

---

## A stopped command that did not stop (2026-08-16)

Worth knowing when running long database jobs: interrupting the command in
the terminal does **not** stop the work. The database server carries on
running the query on its own, still holding its locks.

This happened twice in one afternoon. Two abandoned copies of the same job
were left running, competing with the third — and with each other — for the
same rows, which made everything roughly three times slower and looked like
the database was simply slow. Worse, work done by an abandoned job is
thrown away at the end anyway, because there is no longer a client for it
to report back to.

To actually stop a database job, cancel it inside the database rather than
closing the terminal window.

---

## A bus that finished its route looking exactly like a broken GPS (2026-08-16)

After fixing the stuck-bus bug above, the numbers got worse in one way
before they got better: the single worst bus went from stuck 11 hours to
stuck **25 hours**. That was worth stopping and actually looking at, rather
than assuming the new bug was smaller than the one just fixed.

Tracing that one bus's real readings showed exactly what was happening:

```
raw position = 106,681.9 m along its route   (route is ~107 km long - the bus is basically at the end)
   ↓ next reading, 22 seconds later
raw position =      63.4 m along its route   (basically back at the start)
```

The bus didn't teleport. It **finished its route and started the next lap**
— completely normal; a bus runs the same route many times a day. But
nothing in the code knew that. The only two things it checks to decide
"is this a fresh start, not a bad reading" are the route number and the
trip number, and Delhi's feed labels a trip by its scheduled departure time
(e.g. "route 2716, the 13:22 departure"), not by which physical lap the bus
is on. So the *next* lap on the same route gets the exact same label as the
one just finished — the code had no way to see this coming.

Without knowing that, a jump from near the very end of the route to near
the very start looks exactly like an impossible jump — so it got rejected.
And because it never resets by itself once rejected, the bus stayed marked
"stuck" for as long as it took to travel almost the entire next lap before
its position happened to land close enough to the old (correct, but now
very outdated) reading to be trusted again.

The fix: also check for this specific pattern - was the last trusted
reading near the very end of the route, and is the new one near the very
start? If so, treat it as the bus starting its next lap, not a bad GPS fix,
regardless of what the route/trip labels say. Confirmed against the real
sequence above before touching the full 32-million-row database: every one
of the readings that had been stuck for 11+ hours is now correctly accepted
within seconds of the lap restart. See
[tools/match-vehicle-progress.js](../tools/match-vehicle-progress.js).

---

## Measuring a route's length the same way twice (2026-08-16)

Fixing the bug above needed one more number: how long is this route, in
total? That sounds like it should have one obvious answer, but there are
two different ways to ask PostGIS for it, and they don't agree:

- Ask PostGIS to measure the line fresh, from its shape.
- Read the number already stored at the very end of the line - the same
  number every bus's "how far along this route" reading is measured
  against.

On one route these differed by **172.7 metres**. Neither is wrong exactly -
they're just two slightly different rulers. The problem is that the bug fix
above compares a bus's position (measured with the second ruler) against
the route's total length - so if that total length were measured with the
*first* ruler instead, the comparison would be silently off by however much
the two rulers disagree, on every route, by a different amount.

The fix: measure the route's length the same way the bus positions
themselves are measured - from the same stored number, not a fresh
calculation. Two numbers that are meant to be compared should always come
from the same ruler.

---

## A fix that was never applied (2026-08-19)

The lap-restart fix (the "bus that finished its route" bug above) was
written on August 16 and the code was correct. But it was never applied
to the database.

The fix needs a column called `route_length_m` in the `route_shape_lookup`
table — it compares a bus's position against the route's total length to
detect the end-to-start jump. The SQL file that builds that table was
updated to include the column, but the table in the database was never
rebuilt with the new SQL. So the old table had three columns instead of
four, and the matcher's query — which references the missing column —
could never have run with the fix active.

The tell: the worst stuck run in the old data was 2,837 readings, which
matches the number in the code comments for the state *before* the fix.
Tracing the specific bus (DL51GD9043 at frame 5891) confirmed: the exact
106,681m → 63m lap-restart jump was being rejected as "jumped backward."

After rebuilding the table and re-running the matcher, the same jump at
frames 1194→1195 is accepted instantly. The fix works; it just hadn't
been turned on.

---

## Buses that genuinely travel backward on their route line (2026-08-19)

After fixing the lap restart, the worst stuck runs dropped from 2,837 to
about 2,235 readings. That improvement was real but smaller than expected,
because the remaining worst cases are a different problem entirely.

Tracing the new worst bus (DL1PD5157 on route 2769) showed it
continuously decreasing its distance along the route — from 11,653m down
to 10,689m over many minutes of consistent readings. This is not bad GPS
or a lap restart. The bus is really there, really moving, and the
readings are consistent with each other. It is just moving in the
opposite direction from the route line.

Most likely cause: the route's shape is drawn for one direction only (the
"UP" direction), and this bus is running the return leg. Delhi's feed
does have separate route IDs for UP and DOWN, but some buses may be
tagged with the wrong one, or some routes may use the same shape for
both directions.

This is a known, measured issue (it accounts for most of the 12.7%
rejection rate) but it does not corrupt the Phase 3 output: the travel
time extraction only uses segments where the bus moved forward along the
route, so backward-traveling segments are correctly excluded.

---

## Working out when each bus passed each stop (2026-08-19)

Phase 3 of the project: turning accepted bus positions into actual stop
passage times.

We know two things from Phase 2: where each bus is every ~10 seconds
(its accepted distance along the route), and where each stop sits along
that same route (computed earlier from the static GTFS). To find when a
bus passed a stop, we look for the pair of consecutive GPS readings where
the bus's distance crossed the stop's distance, and interpolate the time.

For example: at 09:15:00 the bus is at 5,200m along its route, and at
09:15:10 it is at 5,350m. A stop sits at 5,280m. The fraction of the
way through that 10-second interval is (5280 − 5200) / (5350 − 5200) =
0.533, so the bus passed the stop at roughly 09:15:05.

For one day (Monday August 10), this produced 1,250,248 stop passages
from 5,909 buses across 2,036 routes and 6,420 stops. A sanity check on
implied speeds between consecutive stops: median 18.9 km/h, average
22.0 km/h, 95th percentile 50.9 km/h. All reasonable for Delhi city
buses.

The processing runs one day at a time to keep the database small (~12 GB
per day instead of the 54 GB that crashed the laptop before). Each day's
stop passages go into a permanent table that accumulates across days;
then the raw positions are cleared before loading the next day.

---

## Why processing 7 days took most of a day to run (2026-08-19)

Processing one day of bus data — load it, work out how far each bus is
along its route, decide which readings to trust, extract stop passage
times — took anywhere from **1 hour 10 minutes to 3.5 hours** per day,
for roughly 20–26 million bus sightings a day. Worth writing down why,
because none of it was a bug.

**1. The geometry math is genuinely heavy, on purpose.** Working out
"how far along this route is this GPS point" is not a cheap lookup — it's
real trigonometry against a route line made of thousands of points,
repeated once per bus sighting. A day has 20+ million sightings. This is
the actual computational core of Phase 2, not overhead around it — making
it fast would mean making it approximate, which defeats the point.

**2. The bus-trust decision has to happen in order, one bus at a time.**
Deciding whether to believe a new GPS reading depends on the last reading
we trusted for that same bus (see "A bus getting stuck because we stopped
believing it" above). That's a chain of "depends on what came before" —
it can't be split across many workers running at once without a lot more
engineering, so it runs as a single, straightforward pass instead. Slower,
but easy to reason about and easy to verify by hand — which matters more
for a project that has to be defended in a viva than shaving off an hour.

**3. Docker Desktop on Windows runs the database inside a virtual
machine**, not directly on the laptop's disk. Every read and write to
Postgres crosses that virtualization layer, which is slower than a
database running natively on Linux. This is the one piece that's a real,
fixable inefficiency — running Postgres inside WSL2 directly (rather than
through Docker Desktop) would remove this tax — but it was left alone
rather than risking a database migration in the middle of a working run.

**4. One night, the laptop went to sleep mid-run.** Sleep pauses
everything — CPU, disk, network — until the laptop wakes up again. One
day's processing that should have taken under 2 hours took 6, purely from
that pause. Nothing broke; the work picked up exactly where it left off,
just very late. Confirmed at the time by checking the actual OS process —
it was still burning real CPU time even during a stretch where the log
file itself looked frozen, which is what "paused, not dead" looks like
from the outside.

None of these four are the same kind of problem, so no single fix would
have solved all of them — which is why the honest answer to "make it
faster" was "let it finish this way, once, correctly" rather than
stopping mid-run to change the architecture.

---

## Why the database has to be cleared and reloaded one day at a time (2026-08-19)

Already written up above (see "Why we only keep a couple of days in the
database at a time"), but the concrete numbers from actually running this
7-day pipeline are worth adding:

- One day of raw bus positions: **~12–13 GB** in Postgres.
- All 7 days at once, if never cleared: would be in the range of the
  **54 GB** that filled the laptop's disk on an earlier, smaller attempt
  (that was only 8 days of *position* data, before the stop-passage
  extraction step even existed).
- The actual useful *output* of a day's processing — the stop passage
  times — is tiny by comparison: about 1.2–1.4 million rows per day, a
  few hundred MB, not gigabytes. It is the raw GPS positions and the
  per-sighting geometry working-out that are the bulk, not the final
  answer.

So the day-by-day loop (`scripts/process-week.sh`) does exactly what the
earlier write-up called for: load one day, compute, extract the small
useful result into a table that survives, clear the big raw data, move
to the next day. Database size stayed flat at ~12–13 GB throughout the
whole 7-day run instead of climbing to 80+ GB, and the final accumulated
`observed_stop_passage` table — the thing actually needed for Phase 4 —
stays small no matter how many days get processed this way.

---

## Why MongoDB or MySQL would not have been a better choice (2026-08-19)

Came up mid-project as a "would this be faster" question. Worth writing
down why the answer is no, because it's specific to what this project
actually needs — not a generic database preference.

**The core operation this whole pipeline depends on:** turning one GPS
point into "this many metres along the bus route." That needs a database
that understands a route as a *line with real-world distance markers
along it*, and can answer "what point on this line is closest to my GPS
fix, and how far along the line is that point?" In PostGIS this is two
built-in functions, `ST_LineLocatePoint` and `ST_LineInterpolatePoint`,
backed by a mature, compiled geometry library (GEOS) that's been
developed for decades.

**MongoDB** has geospatial support, but only for "find things near this
point" — nearest-neighbour and radius searches. It has nothing equivalent
to measuring distance *along* a line. That calculation would have to be
written by hand in application code instead of using a battle-tested
library — slower to build, slower to run, and far more likely to hide a
subtle bug (exactly the kind of bug this project already found three of
in its own hand-written matching logic).

**MySQL** has spatial functions too (`ST_Distance`, `ST_Contains`, point-
in-polygon checks), but the same gap applies — no linear referencing
system, no equivalent of "distance along this specific line." The kind of
question this project asks constantly (how far along its route is this
bus, right now) simply isn't a question either of those databases was
built to answer directly.

On top of that, GTFS itself — the format Delhi's data comes in — is
inherently relational: routes have trips, trips have stop_times, stops
belong to routes. That maps directly onto SQL joins. In a document
database like MongoDB, the same relationships mean either duplicating
route and shape data into every record that needs it, or doing the joins
by hand across several queries from application code.

So the choice wasn't "Postgres because it's popular" — it was "Postgres
+ PostGIS because it's the only mainstream option that has a real answer
to the specific question this project asks over and over again."

---

## Why the free Azure VM tiers looked promising but weren't (2026-08-19)

Also came up mid-project: since Azure for Students gives 750 free hours
a month of a virtual machine, could the slow local processing be moved
there for free? Checked properly rather than guessing, because this
touches real money if wrong.

The free-tier VMs (`B1s`, `B2pts_v2`, `B2ats_v2`) all cap out at
**1–2 GiB of RAM**, regardless of which one is picked, and regardless of
CPU core count — one option even trades RAM for extra cores, ending up
with *less* memory than the plainest option. A "64 GB free" figure that
comes up in searches refers to free managed *disk* space, not memory —
easy to misread as a powerful free machine when it is not one.

This project's slow steps (the geometry math, the vehicle-by-vehicle
trust decisions) are memory- and CPU-hungry, already tuned locally to use
256 MB of working memory per query and four parallel workers. A machine
with 1–2 GB of RAM total has less room than that tuning already assumes,
before Postgres itself and the operating system take their share. Moving
to a free-tier VM would very likely have made processing slower, not
faster — the opposite of the goal.

A real (paid) VM with enough memory to actually help — around 16 GB RAM —
was priced at roughly $0.19/hour, which is affordable within the $100
student credit for a short burst of work. But moving mid-pipeline would
have meant migrating a live database, re-pointing every script at a new
machine, and losing the safety of "this works, tested, on the machine
it's always run on" — a bigger risk than the time saved was worth, for a
project already partway through a working run. Left for a future,
deliberate decision instead, made cold rather than mid-flight.

---

## Turning "where was the bus" into "how long does this hop usually take" (2026-08-19)

The 7-day run produced 9.73 million rows saying, in effect, "this bus
passed this stop at this exact time." That's raw material, not an
answer. What Phase 3 is actually meant to produce is: "how long does it
usually take to get from stop A to stop B on this route" — with enough
honesty about how much that varies to support the confidence-banded ETA
this whole project is built around.

**Turning one into the other, in plain terms:** for each bus, on each
day, look at its passages in the order they happened. Whenever two
passages in a row are for *consecutive* stops on the same route (stop 6
right after stop 5, not stop 9 after stop 5, and not stop 1 after the
route's last stop), the time between them is one real measurement of
"how long that one hop took." Anything that doesn't look like that — a
skipped stop, a route change, a bus finishing its route and starting the
next lap — is left out rather than guessed at.

Out of 9.73 million passages, **9.14 million (94%) turned into genuine
hop measurements.** The other 6% were exactly the excluded cases above —
mostly lap boundaries, which are expected and correct to drop, not a
sign anything went wrong.

**Then those measurements get boiled down two ways at once**, for every
one of the 68,758 distinct route segments found:
- One figure pooled across the whole day, for when there isn't enough
  data to say anything more specific.
- One figure per hour of day (a segment during evening rush hour is a
  different question from the same segment at 2am), for when there is.

Both come with more than just a single number: the median, the 25th and
75th percentile, the mean, and how many actual bus trips it's based on
(sample count). That's deliberate — a number with no sense of its own
spread is exactly the "one unqualified ETA" this project exists to not
do (CLAUDE.md's framing: "a range plus the source of the estimate, not a
bare number").

**The numbers came out sane:** a typical hop's median travel time is 86.5
seconds, backed by an average of 133 real bus trips per segment (median
78). At the roughly 19-22 km/h buses were measured moving at earlier,
86.5 seconds covers about 450-480 metres — a completely ordinary distance
between two stops on a city route. Nothing here needed forcing to look
right.

**One honest gap, worth stating rather than hiding:** these hop times
come from GPS readings that are already themselves interpolated (Phase 2
estimated exactly when a bus crossed a stop's position, between two real
10-second GPS fixes). So a very short hop — two stops close together,
both landing inside the same 10-second gap — is measuring a straight-line
guess against another straight-line guess, not two independent sightings
of the bus. Longer hops, spanning several real GPS fixes, are on firmer
ground. This is a known property of the method, not a bug, and it's
exactly what the sample-count column is for: a low sample count and a
short hop distance are both signals a downstream ETA should weigh less
heavily, not evidence to throw the number out.

---

## Does the travel-time model actually predict anything? (2026-08-19)

CLAUDE.md is explicit that this check has to happen early: "without a
number, 'I improved the ETA' is a feeling rather than a result." So
before building anything that shows a bus ETA to anyone, the honest
question first: trained on some days, does this actually predict a day
it has never seen?

**The test, in plain terms:** pick one day out of the seven and hide it
completely. Build the travel-time statistics from the other six days
only. Then, for every real bus hop that actually happened on the hidden
day, ask the six-day model what it would have predicted, and compare
that prediction to what really happened. The hidden day was Thursday
August 13 — an ordinary weekday, not cherry-picked as easy or hard.

**The result:** on 1,264,062 real hops the model had never seen, the
**median** prediction was off by **16.5 seconds**. The average error was
higher, 44.4 seconds, because a smaller number of harder segments pull
the average up — worth saying plainly rather than only quoting whichever
number looks better. 67% of predictions landed within half a minute of
the truth. Only 160 hops out of 1.26 million (about 1 in 8,000) had a
route segment the model had literally never seen in training, so
coverage is essentially complete for a week's worth of routes.

**The one design decision that most needed testing — does it actually
help to prefer an hour-of-day-specific figure over one flat number for
the whole day — turned out to be worth it, measured rather than assumed:**

| approach | how often used | typical error |
|---|---|---|
| hour-of-day-specific figure | 94.4% of hops | 43.8s average |
| falls back to the all-day figure | 5.6% of hops (too little hourly data) | 53.5s average |
| always use the all-day figure, never hourly | (comparison baseline) | 47.3s average |

The hour-aware approach beats the flat baseline by a real, measured
margin, and the two-tier fallback design (specific figure when there's
enough data, coarser figure when there isn't) is exactly what let it do
that without leaving the 5.6% of thinner-data segments with nothing to
predict at all.

This is the number this project needed before building anything user-
facing: the underlying model genuinely generalises to a day it never
saw, not just to the data it was built from. See
[db/evaluate_travel_time_predictions.sql](../db/evaluate_travel_time_predictions.sql).

**Important caveat, found immediately afterwards:** this measures ONE hop.
A real ETA is a sum of many hops, and that turned out to behave much
worse — see the next entry, which is the more honest headline number.

---

## The single-hop result was flattering, and the real ETA number is worse (2026-08-19)

The 16.5-second result above is real, but it answers a question no
commuter asks. Nobody stands at a stop wondering how long one hop takes.
They ask "when does the bus get to MY stop," which is five, ten,
sometimes twenty hops away — a SUM of predictions, not one prediction.

Sums do not behave like their parts, so this had to be measured
separately rather than assumed. Two things could have happened:

- If each hop's error were independent and random, errors would partly
  cancel, and a 20-hop journey would only be about 4.5 times worse than
  one hop (the square root of 20).
- If errors are correlated — which is exactly what traffic does, since a
  jam slows a whole corridor at once rather than one gap between two
  stops — errors stack, and a 20-hop journey is up to 20 times worse.

**Measured on the same held-out day, the real answer is much closer to
the bad case.** Error grows roughly in proportion to the number of hops,
not its square root:

| journey length | typical actual duration | average error | within 2 minutes |
|---|---|---|---|
| 1 hop | 2m 18s | 50.5s | 92.2% |
| 5 hops | 11m | 179.5s | 63.4% |
| 10 hops | 21m 36s | 319.1s | 40.2% |
| 20 hops | 42m 22s | 581.0s | 19.3% |

So the honest headline for a commuter asking about a bus ten stops away
is "within two minutes, about 40% of the time" — not the much prettier
single-hop number.

### The worse problem: the answer was systematically optimistic

Every one of those errors leaned the same direction. The bus consistently
took LONGER than predicted — by about half a minute over one hop, and by
**more than eight minutes** over twenty. An ETA that is wrong in a random
direction is a nuisance; one that is reliably too optimistic actively
misleads the person relying on it, which is the exact failure this whole
project exists to avoid.

Two possible explanations, deliberately tested against each other rather
than assuming the flattering one
([db/diagnose_eta_bias.sql](../db/diagnose_eta_bias.sql)):

**Explanation 1 — "the held-out day was just slow."** Partly true, and
worth about a fifth of the problem. Thursday August 13 really did run
about 8% slower than the six training days (average hop 131.2s versus
121.2s). No model can predict away a day that is genuinely slower than
the days it learned from.

**Explanation 2 — a statistical trap: the sum of medians is not the
median of the sum.** This turned out to be the bigger half, and it was a
genuine mistake in the method rather than bad luck with the data.

Bus travel times are lopsided: a bus can be enormously late, but it can
never be more than slightly early — there is a floor on how fast the hop
can physically be driven, and no ceiling on how long a traffic jam
lasts. Measured across the training days, **91.2% of route segments are
lopsided in exactly this direction**, with the average sitting about 18
seconds above the middle value.

The middle value (median) deliberately ignores that long tail — that is
what makes it a good, robust summary of a SINGLE hop. But it means every
single hop prediction is a little below the true average. Add twenty of
them together and twenty small underestimates become one large one.

### The fix, and why it is the textbook-correct one

Swapping the median for the mean when summing hops cuts the bias roughly
in half at every distance:

| journey | bias when summing medians | bias when summing means |
|---|---|---|
| 1 hop | +30.2s | +16.7s |
| 5 hops | +133.5s | +70.5s |
| 10 hops | +259.3s | +135.9s |
| 20 hops | +504.7s | +261.2s |

And it improves the raw error too, from 5 hops onward — 581s down to
482s at twenty hops, a 17% improvement.

There is a clean crossover worth understanding rather than just
observing: **for one hop the median is better (50.5s versus 52.9s
average error), but for any sum the mean is better.** That is not a
coincidence of this dataset, it is how the two measures behave. The
median is the value that minimises error for a single guess. But
averages are what add up correctly — the expected total of several
journeys equals the total of their expected values, and that property
belongs to the mean, not the median. So: use the median when answering
about one hop, use the mean when adding hops together.

### What is left over, and why that is not a bug

Even after the fix, a twenty-hop journey is still about four minutes
optimistic on average. Most of that is Explanation 1 — the test day was
genuinely slower, and no amount of better arithmetic on historical data
can know that in advance.

That residue is not a failure to be engineered away. It is the honest
size of "we do not know whether today is a slow day," and it is exactly
the quantity this project promised to show the user rather than hide
(CLAUDE.md: "a range plus the source of the estimate, not a bare
number"). It is also precisely the gap that live vehicle positions are
supposed to close: a bus already running late today is observably late
right now, even if history could not have predicted it.

### Why this was worth finding before building anything

Had the ETA been built straight off the single-hop result, it would have
shipped a confidently optimistic number, and the error would have been
invisible — every individual hop prediction looks fine in isolation. It
only shows up when you add them, which is the only way the number is
ever actually used.

This is the entire argument for CLAUDE.md's working convention #3
("build the evaluation harness early"), demonstrated on real data rather
than taken on faith.

> **Follow-up: most of the numbers in this entry did not survive.** Testing
> against a second, third... seventh day showed the "systematic optimism"
> above was mostly a property of Thursday, not of the method. See the next
> entry. The reasoning about medians and sums is still correct; the
> measured sizes were not.

---

## Testing on one day is not testing (2026-08-19)

The entry above drew four conclusions from holding out a single day
(Thursday 13 August) and checking predictions against it. That felt like
a proper test — over a million real journeys the model had never seen,
which is not a small sample.

Then the same experiment was run seven times, holding out each recorded
day in turn. **Three of the four conclusions collapsed.**

| what one day said | what seven days said |
|---|---|
| ETAs are systematically optimistic by ~8 minutes over 20 stops | that was mostly Thursday. The seven-day average is under 1 minute |
| the error is strongly lopsided, so the range must be strongly lopsided | mostly an artefact of a different bug. The real lopsidedness is mild |
| "always add up averages, never middles" | true on weekdays, **backwards** on weekends |

Nothing was wrong with the Thursday measurement. It correctly measured
Thursday. The mistake was treating "how the model did on one day" as "how
the model does" — and one of those days happened to suit it.

### The bug hiding underneath

The weekday/weekend reversal was the thread worth pulling. Splitting the
seven results by kind of day showed the model failing in **opposite
directions**:

| kind of day | error over 20 stops |
|---|---|
| weekdays | bus arrives about **4½ minutes later** than predicted |
| weekends | bus arrives about **9 minutes earlier** than predicted |

Averaged together, those two large errors partly cancel into a small,
healthy-looking one. That is precisely why a single weekday's test looked
fine — and why an average across days would also have looked fine without
splitting it apart.

**The cause, in plain terms:** the model was learning from every day at
once. Of the seven recorded days, five are weekdays. So when it predicted
a Sunday, it was mostly applying weekday traffic to a day when Delhi's
roads are visibly emptier — and expected congestion that was not there.

It also explains something that had looked like a genuine finding. On
weekends, using the "middle" travel time beat using the "average" one.
That was never because middles are better on weekends. The middle value
runs slightly low, the weekday contamination ran high, and the two errors
happened to cancel. Building on that would have meant building on a
coincidence.

### The fix, and what it bought

Teach the model what kind of day it is looking at, and let it fall back
gracefully when a particular weekend hour has too little data:

1. this stop, this hour, this kind of day
2. this stop, this kind of day, any hour
3. this stop, any day, any hour

Measured across all seven days:

| kind of day | error over 20 stops, before | after |
|---|---|---|
| weekdays | 4m 39s off, leaning late | **47s off** |
| weekends | 8m 48s off, leaning early | **7s off** |

Weekend predictions also got 25–41% more accurate outright, because they
stopped being contaminated by weekday traffic. Weekday accuracy stayed
about the same — splitting the data leaves fewer examples per weekday
slot, and that small loss roughly cancels the gain from removing the bias.

### The honest caveat

There are only **two weekend days** in the whole archive. Hold one out and
exactly one remains to learn from. So while the weekend improvement is
large, it rests on very thin evidence, and the right fix is more weekend
data rather than more clever statistics. The recorder has since been
stopped, so that limit stands unless it is restarted.

Also unhandled: 15 August is Independence Day and falls inside the
recorded week. It is currently treated as an ordinary Saturday. A public
holiday probably behaves like a weekend whatever day it lands on, and
nothing in the model knows that.

### The transferable lesson

**A held-out day is not cross-validation.** One fold tells you how the
model did on one day. It cannot tell the difference between "this method
works" and "that day happened to suit this method" — and those two look
identical from inside a single result.

It took a second pass to apply the project's own convention properly.
Worth remembering that the first pass *felt* rigorous: a real held-out
day, over a million unseen journeys, sensible-looking numbers. None of
that was enough.

