# ETA design — how the arrival estimate is actually computed

Phase 4's design. Every number here is from **7-fold cross-validation** on
real recorded data — each of the seven recorded days held out in turn,
the model trained on the other six, then scored against journeys it had
never seen. The scripts are named so any figure can be re-derived.

This document was rewritten once, after its first version was found to be
wrong. §7 records what was wrong and how it was caught, because that is
the most reusable part of the whole exercise.

---

## 1. What the ETA answers

> Given a bus at a known point on its route, and a stop further along,
> when will it reach that stop — and how much should that be trusted?

**Inputs:** `route_id`, the bus's current `stop_sequence`, the target
stop's `stop_sequence`, the current time, and whether today is a weekday
or a weekend.

**Output:** never a bare timestamp. A point estimate, a range around it,
and a label saying where the estimate came from.

---

## 2. The point estimate

For a bus at stop *S* travelling to stop *T*:

```
predicted_seconds = Σ  hop_prediction(route_id, seq, hour_of_day, day_type)
                   for seq in (S+1 .. T)
```

Two things decide each `hop_prediction`, and both were established by
measurement rather than assumption.

### 2.1 Use the mean, not the median

For predicting **one** hop the median is genuinely better (50.5s vs 52.9s
average error). The median is the value that minimises absolute error for
a single guess.

But an ETA is a **sum**, and sums do not inherit that property. Averages
add up correctly — the expected total of several hops equals the total of
their expected values — and that is true of the mean and *not* the
median. Bus hop times are lopsided (91.2% of route segments have a mean
above their median, by ~18s), so every median sits slightly below its own
average, and twenty small under-estimates become one large one.

**Rule: median for a single hop, mean for anything summed.** The ETA is
always a sum, so the ETA always uses means. `route_segment_travel_time`
stores both.

Source: [db/diagnose_eta_bias.sql](../db/diagnose_eta_bias.sql)

### 2.2 Split the model by day type

This was the single biggest error found, and it was invisible until
cross-validation. A day-blind model fails in **opposite directions**
depending on the day:

| day type | 20-hop bias, day-blind | meaning |
|---|---|---|
| weekday (5 folds) | **+279s** | bus arrives LATER than predicted |
| weekend (2 folds) | **−527s** | bus arrives EARLIER than predicted |

Averaged together those partly cancel to a harmless-looking +49s — which
is exactly how a single-day calibration hid the problem entirely.

**Cause:** with only two weekend days in seven, a model trained on "all
other days" is overwhelmingly learning weekday traffic, then applying it
to a Sunday when Delhi's roads are visibly emptier.

**Fix — a fallback chain, most specific first:**

```
1. this route+stop, this hour, this day type   (needs >= 3 samples)
2. this route+stop, this day type, any hour    (needs >= 3 samples)
3. this route+stop, any day, any hour          (last resort)
```

**Measured effect, 7-fold cross-validated:**

| day type | journey | bias before | bias after | MAE before | MAE after |
|---|---|---|---|---|---|
| weekday | 20 hops | +276.4s | **+43.8s** | 496.1s | 484.9s |
| weekday | 10 hops | +139.5s | **+25.6s** | 291.2s | 296.0s |
| weekend | 20 hops | −528.5s | **+8.9s** | 627.3s | **368.4s** |
| weekend | 10 hops | −261.2s | **+8.0s** | 339.1s | **209.6s** |

Bias falls by 83% on weekdays and 99% on weekends. Weekend accuracy
improves 25–41%. Weekday accuracy is roughly neutral — slightly worse on
short journeys (splitting the data leaves fewer samples per cell, so
estimates are noisier) and slightly better at 20 hops, where removing the
bias outweighs the extra noise.

`hour_of_day` is the hour **at prediction time**. A real system does not
know what hour the bus will arrive, so neither does this.

### 2.3 Hours and days are read in Delhi time, not UTC

The database stores timestamps with a timezone and its session runs in
UTC. Reading the hour straight off would give the UTC hour, and Delhi is
UTC+5:30 — so "hour 9" would mean 14:30 in Delhi. Two problems follow:

- Every figure becomes impossible to sanity-check by eye. With UTC hours
  the slowest traffic appeared at "hours 12–15", which looks like midday.
  Read in Delhi time it is **17:00–20:00** — the evening rush, exactly
  where it should be. Same data, and only one version can be checked
  against reality.
- Because the offset includes a half hour, UTC buckets straddle two Delhi
  hours, mixing rush-hour and off-peak traffic into one bucket.
- A bus running at 02:00 on a Saturday in Delhi is still Friday in UTC,
  and was being filed as **weekday** traffic.

Everything is now read as Delhi local time
(`AT TIME ZONE 'Asia/Kolkata'`), and the API does the same conversion so
it looks up the same buckets the history was built from.

**Honest note: this did not measurably improve accuracy.** Re-running the
full 7-fold cross-validation on Delhi-local buckets moved every figure by
under 2% (e.g. weekday 20-hop band −652s → −662s). Since training and
testing shared the same buckets either way, the shift largely cancelled
out. It was worth doing for correctness and interpretability, and for the
Saturday-morning misfiling — not because it made the model better.

Source: [db/crossvalidate_eta_daytype.sql](../db/crossvalidate_eta_daytype.sql)

---

## 3. Expected accuracy

7-fold cross-validated, day-type aware. This is the honest picture:

| day type | journey | typical duration | average error | bias |
|---|---|---|---|---|
| weekday | 1 hop | ~2m | 56.3s | +6.2s |
| weekday | 5 hops | ~10m | 181.7s | +16.4s |
| weekday | 10 hops | ~20m | 296.0s | +25.6s |
| weekday | 20 hops | ~40m | 484.9s | +43.8s |
| weekend | 1 hop | ~2m | 37.2s | +3.6s |
| weekend | 5 hops | ~10m | 121.9s | +6.7s |
| weekend | 10 hops | ~20m | 209.6s | +8.0s |
| weekend | 20 hops | ~40m | 368.4s | +8.9s |

**Errors compound rather than cancel.** Error grows roughly in proportion
to journey length, not its square root — traffic correlates along a
corridor, so one slow hop predicts more slow hops. A 20-hop ETA is about
8× worse than a 1-hop ETA, not 4.5× as independent errors would give.

**Weekends are genuinely more predictable** than weekdays — about 25%
lower error at every distance. Lighter, more consistent traffic.

---

## 4. The confidence band

Built from the model's own measured residuals, per day type. These are
averages across folds; the *centre* is now reliable, the *width* still
varies day to day.

**Weekday** (5 folds):

| journey | p10 | p50 | p90 |
|---|---|---|---|
| 1 hop | −70s | −5s | +59s |
| 5 hops | −245s | −20s | +243s |
| 10 hops | −402s | −33s | +431s |
| 20 hops | −662s | −42s | +760s |

**Weekend** (2 folds — thin, see §6):

| journey | p10 | p50 | p90 |
|---|---|---|---|
| 1 hop | −43s | −3s | +40s |
| 5 hops | −151s | −10s | +146s |
| 10 hops | −257s | −16s | +255s |
| 20 hops | −438s | −27s | +438s |

### The band is only mildly lopsided — a correction

An earlier version of this document claimed the residual was *strongly*
right-skewed (buses run very late but never very early) and specified a
strongly asymmetric band. **That was largely an artefact of the day-type
bias**, not a property of bus travel.

Once the day-type error is removed, the skew is mild and grows slowly
with distance:

| day type | 1 hop | 5 hops | 10 hops | 20 hops |
|---|---|---|---|---|
| weekday | 1.00 | 1.18 | 1.27 | 1.30 |
| weekend | 1.07 | 1.11 | 1.13 | 1.14 |

(ratio of the upper half of the band to the lower half; 1.00 = perfectly
symmetric)

So: **mildly asymmetric on weekdays at long range, near-symmetric
otherwise.** A modest lean, correctly measured, rather than the dramatic
one first reported. Note also that `p50` is slightly negative throughout —
the *typical* journey finishes a little early, while a minority of very
slow journeys pull the average late. That is the mild right skew showing
up, and it is why the mean and median disagree.

**Remaining caveat:** width still varies between days (weekday 20-hop p90
ranged from +476s to +1135s across folds). The centre is now trustworthy;
treat the width as a good central estimate, not a guarantee.

Source: [scripts/crossvalidate-eta.sh](../scripts/crossvalidate-eta.sh),
[db/crossvalidate_eta_daytype.sql](../db/crossvalidate_eta_daytype.sql)

---

## 5. Live position: what it is and is not for

### What live position IS for

Knowing **where the bus is** — which determines *which hops remain* to be
summed. Essential and non-negotiable. All of Phase 2's map-matching
exists to answer this.

### What live position is NOT for

**Extrapolating delay.** The intuitive move — "this bus is three minutes
late, so add three minutes" — was tested and is actively harmful.

Correlation between a bus's lateness over its previous 5 hops and its
lateness over the next 10 is **0.088**. Essentially nothing. Measured
over 414,225 real observations:

| correction | MAE | effect |
|---|---|---|
| none (history only) | 282.24s | baseline |
| 0.115× (statistical optimum) | 280.03s | −0.78%, negligible |
| 1.0× ("add the delay") | 330.4s | **16% worse** |
| 2.0× ("delay is accelerating") | 439.9s | **55% worse** |

Even at its optimal strength it buys under 1%. At the strength a
developer would naturally reach for, it does real damage.

**Why:** the per-hop predictions already condition on hour of day and day
type, capturing the systematic traffic pattern. What remains is mostly
idiosyncratic — one bad light, one blocked lane — and does not carry
forward. Extrapolating it amplifies noise.

**Decision: no delay extrapolation.** Live position decides which hops
remain; it does not adjust how long those hops take.

**Untested variant:** whether *many buses being slow at once* on a
corridor predicts future slowness — a network-conditions signal rather
than a per-bus one. Plausible, unmeasured, noted as future work rather
than assumed.

Source: [db/calibrate_live_correction.sql](../db/calibrate_live_correction.sql)

---

## 6. The trust label

Three levels, in descending order of trust:

| label | when | what is shown |
|---|---|---|
| **Live** | a recent, accepted GPS fix places the bus on this route | estimate + band |
| **Estimated** | seen recently but position now stale, or readings being rejected | estimate + **widened** band, marked as extrapolated |
| **Timetable** | no live vehicle — a scheduled trip with nothing tracking it | scheduled time only, marked *scheduled, not observed* |

**Timetable must carry a stronger warning than the others.** Delhi's
published timetable is not a real timetable: OTD's own documentation
states its stop times are "a rough estimate generated by assuming a
constant speed of travel" (CLAUDE.md §2). Presenting it with the same
confidence as an observed estimate would be the exact failure this
project exists to correct.

A bus whose GPS has dropped must **never** be shown at its last known
position as though live. It degrades to **Estimated**, or disappears with
an explanation — it does not silently freeze.

---

## 7. Known limits

**Only two weekend days exist in the archive.** Holding one out leaves
exactly *one* to learn weekend behaviour from. Every weekend figure here
rests on a single day of training data and is far weaker evidence than
the weekday equivalent. The fix is more weekend data, not better
statistics — and the recorder is now stopped, so this limit is fixed
unless it is restarted.

**Band widths vary by day** (§4). The centre is reliable; the width is a
central estimate.

**Short hops rest on interpolation.** Stop passage times were themselves
interpolated between 10-second GPS fixes. Two stops close enough to fall
inside one GPS gap are measuring one straight-line guess against another.
`sample_count` is the flag for weighing these less.

**Buses travelling backward on one-way route shapes** remain a known
Phase 2 issue (~13% of raw readings rejected). Excluded rather than
mis-used — costs coverage, not correctness.

**No holiday handling.** Aug 15 (Independence Day) falls inside the
recorded week and is treated as an ordinary Saturday. A public holiday
plausibly behaves like a weekend regardless of weekday, and this is not
modelled.

---

## 8. What was wrong the first time, and how it was caught

Worth keeping, because it is the most transferable lesson here.

The first version of this design was calibrated on **one** held-out day
(Thursday 13 August) and reported:

- median single-hop error of 16.5s — *real, but answering a question no
  commuter asks*
- a systematic optimism of +261s at 20 hops — *mostly a Thursday
  artefact; the 7-day average is +49s*
- a strongly asymmetric confidence band — *mostly an artefact of the
  day-type bias; the real skew is 1.0–1.3, not ~2.6*
- no day-type awareness at all — *the single biggest source of error, and
  completely invisible on one weekday*

Every one of those was found by rotating the held-out day across all
seven days. Three separate conclusions did not survive. The single-day
result was not wrong data — it was a correct measurement of one day,
mistaken for a property of the method.

**The practical rule:** a held-out day is not cross-validation. One fold
tells you how the model did on one day, and cannot distinguish "the model
works" from "that day happened to suit the model." This is exactly what
CLAUDE.md's working convention #3 is for, and it took a second pass to
apply properly.

---

## 9. Implementation checklist (Phase 5)

1. Read **means**, not medians, from `route_segment_travel_time`.
2. Key predictions on **(route, stop, hour, day type)**, with the §2.2
   fallback chain.
3. Attach a band from §4, **chosen by day type**, interpolating by hop
   count.
4. Use live position **only** to decide which hops remain — never to
   extrapolate delay.
5. Label every answer Live / Estimated / Timetable; never present a stale
   position as live.
6. Never show a bare number.
7. Treat weekend figures as provisional until more weekend data exists.
