// Two points in, ranked ways to travel out. The clock times under each
// result are computed from the current time, and the results refresh while
// the screen is open, so they do not freeze at the moment of the search.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'api_client.dart';
import 'arrival_alarm_service.dart';
import 'by_hour_screen.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'route_map_widget.dart';
import 'theme.dart';

import 'package:latlong2/latlong.dart';

/// Turns a number of minutes from now into a real clock time, e.g. "7:15 PM".
/// The backend only ever gives back a DURATION (never a clock time - see
/// api/src/journey.ts), so turning that into "arrives around..." is done
/// here, on the device, using the moment the search was actually made.
final _clockFormat = DateFormat('h:mm a');
String _clockTime(DateTime now, double minutesFromNow) {
  final at = now.add(Duration(minutes: minutesFromNow.round()));
  return _clockFormat.format(at);
}

/// The current clock time in the same format as the arrival lines above.
/// The "leaving now" strip uses it to name the actual moment the ranked
/// list is costed from, so the times below it cannot be mistaken for a
/// timetable of fixed departures.
String _nowClockTime() => _clockFormat.format(DateTime.now());

/// The two points a journey is being planned between. `askedAt` makes each
/// search a distinct query; the clock times on screen are computed from the
/// current time so they do not freeze at the moment of the search.
class JourneyQuery {
  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final DateTime askedAt;
  // Display-only - the names someone picked, so results can be headed
  // "Shivaji Park -> Madi Pur JJ Colony" instead of just showing a list
  // of options with no reminder of what was actually asked.
  final String fromName;
  final String toName;

  const JourneyQuery({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.askedAt,
    required this.fromName,
    required this.toName,
  });

  @override
  bool operator ==(Object other) =>
      other is JourneyQuery &&
      other.fromLat == fromLat &&
      other.fromLon == fromLon &&
      other.toLat == toLat &&
      other.toLon == toLon &&
      other.askedAt == askedAt;

  @override
  int get hashCode => Object.hash(fromLat, fromLon, toLat, toLon, askedAt);
}

/// Holds the query currently being searched for. Null means "nothing
/// searched yet" - the screen shows the input form only, no results area.
final journeyQueryProvider = StateProvider<JourneyQuery?>((ref) => null);

/// Fetches journey options for whatever query is currently set. `.family`
/// means Riverpod keeps a separate cached result per distinct query;
/// `.autoDispose` throws each one away once nothing is watching it any
/// more, so old searches don't pile up in memory as someone tries several.
final journeyResultProvider = FutureProvider.autoDispose
    .family<JourneyResult, JourneyQuery>((ref, query) {
      return fetchJourney(
        fromLat: query.fromLat,
        fromLon: query.fromLon,
        toLat: query.toLat,
        toLon: query.toLon,
      );
    });

class JourneyScreen extends ConsumerStatefulWidget {
  final PlaceSuggestion? initialFrom;
  final PlaceSuggestion? initialTo;

  /// Whether the result map may fetch OpenStreetMap tiles. The app leaves
  /// this on; widget tests and screenshot runs turn it off so the route
  /// geometry still renders without the test harness blocking the network.
  final bool enableMapTiles;

  const JourneyScreen({
    super.key,
    this.initialFrom,
    this.initialTo,
    this.enableMapTiles = true,
  });

  @override
  ConsumerState<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends ConsumerState<JourneyScreen> {
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;

  @override
  void initState() {
    super.initState();
    _fromPlace = widget.initialFrom;
    _toPlace = widget.initialTo;
    if (_fromPlace != null && _toPlace != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  // True while waiting on the phone's GPS, so the row can show a spinner
  // instead of looking like it did nothing.
  bool _locating = false;

  void _search() {
    // The button is disabled until both are set, so this is belt and
    // braces rather than the main guard.
    if (_fromPlace == null || _toPlace == null) return;

    final query = JourneyQuery(
      fromLat: _fromPlace!.lat,
      fromLon: _fromPlace!.lon,
      toLat: _toPlace!.lat,
      toLon: _toPlace!.lon,
      askedAt: DateTime.now(),
      fromName: _fromPlace!.stopName,
      toName: _toPlace!.stopName,
    );
    ref.read(journeyQueryProvider.notifier).state = query;
  }

  /// Fills in the "From" point using the phone's real GPS position.
  ///
  /// If the phone is outside Delhi NCR, say so and leave the field empty.
  /// Silently substituting Connaught Place made the answer look local when
  /// it was not.
  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage(
          'Location is turned off. Turn it on in phone settings, or search for a stop.',
        );
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showMessage(
          'Location permission was refused. Search for a stop instead.',
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );

      // Delhi NCR bounding box (~28.2-29.0 N, 76.7-77.6 E).
      final inDelhi =
          position.latitude >= 28.2 &&
          position.latitude <= 29.0 &&
          position.longitude >= 76.7 &&
          position.longitude <= 77.6;

      if (!inDelhi) {
        _showMessage(
          'Location is outside Delhi NCR. Search for a Delhi stop instead.',
        );
        return;
      }

      setState(() {
        _fromPlace = PlaceSuggestion(
          stopName: 'Your location',
          lat: position.latitude,
          lon: position.longitude,
        );
      });
    } catch (e) {
      _showMessage("Couldn't get your location: $e");
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(journeyQueryProvider);

    final canSearch = _fromPlace != null && _toPlace != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Plan a trip')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          WimbSpace.screen,
          4,
          WimbSpace.screen,
          32,
        ),
        children: [
          _whereToWhereCard(context),
          const SizedBox(height: 18),
          // One full-width primary action. The old row squeezed "Find
          // buses" and "Hourly" side by side, which made the main action
          // look like a secondary one. The by-hour comparison has moved to
          // the results area (see _LeavingNowStrip), so "Find buses" is the
          // only thing to press here and there is exactly one obvious way
          // into the hour-by-hour screen.
          FilledButton(
            onPressed: canSearch ? _search : null,
            child: const Text('Find buses'),
          ),
          const SizedBox(height: 20),
          if (query != null)
            _ResultsArea(query: query, enableMapTiles: widget.enableMapTiles),
        ],
      ),
    );
  }

  /// The from/to block: two tall tappable rows joined by a route line, the
  /// way a map app does it - not two text fields and a label.
  Widget _whereToWhereCard(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          PlacePickerRow(
            label: 'FROM',
            place: _fromPlace,
            icon: Icons.trip_origin,
            iconColor: WimbColors.delhiGreen,
            onPicked: (place) => setState(() => _fromPlace = place),
          ),
          // Indented so the divider starts past the icons, letting the two
          // rows read as one connected block rather than two separate ones.
          const Divider(height: 1, indent: 52),
          PlacePickerRow(
            label: 'TO',
            place: _toPlace,
            icon: Icons.place,
            iconColor: WimbColors.dtcRed,
            onPicked: (place) => setState(() => _toPlace = place),
          ),
          const Divider(height: 1),
          // The location strip at the bottom: live GPS pickup alongside an
          // instant "Simulate in Delhi" toggle for remote testing.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _locating ? null : _useMyLocation,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    if (_locating)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(
                        Icons.my_location,
                        size: 18,
                        color: WimbColors.delhiGreen,
                      ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        _locating
                            ? 'Finding you...'
                            : 'Use my location as start',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: WimbColors.delhiGreen,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows loading / error / results for whatever query is currently set.
/// Split out from the main screen so it only rebuilds itself when the
/// fetch's state changes, not the whole form.
class _ResultsArea extends ConsumerStatefulWidget {
  final JourneyQuery query;
  final bool enableMapTiles;

  const _ResultsArea({required this.query, required this.enableMapTiles});

  @override
  ConsumerState<_ResultsArea> createState() => _ResultsAreaState();
}

class _ResultsAreaState extends ConsumerState<_ResultsArea> {
  Timer? _clock;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      _ticks += 1;
      if (_ticks % 2 == 0) {
        ref.invalidate(journeyResultProvider(widget.query));
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.query;
    final result = ref.watch(journeyResultProvider(query));

    return result.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      // Unlike "no route found" below, this branch means the request
      // itself never completed (unreachable server, bad response) - so,
      // unlike that branch, retrying the SAME query can actually give a
      // different answer, and is worth offering.
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(journeyResultProvider(query)),
      ),
      data: (journey) {
        if (!journey.available) {
          return ErrorCard(
            message: journey.unavailableReason ?? 'No route found.',
          );
        }
        // One sentence explaining why several results can start with the
        // same bus, or null when the options do not share a first leg.
        final sharedFirstLegNote = _sharedFirstLegNote(journey.options);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _JourneySummaryCard(
              query: query,
              option: journey.options.first,
              count: journey.options.length,
            ),
            const SizedBox(height: 12),
            // Map visualizing the journey path between chosen places.
            RouteMapWidget(
              height: 180,
              enableTiles: widget.enableMapTiles,
              origin: LatLng(query.fromLat, query.fromLon),
              originLabel: query.fromName,
              destination: LatLng(query.toLat, query.toLon),
              destinationLabel: query.toName,
              polylinePoints: [
                LatLng(query.fromLat, query.fromLon),
                LatLng(query.toLat, query.toLon),
              ],
            ),
            const SizedBox(height: 22),
            // These are "from now" times, and this is the way out to another
            // hour. Placed directly above the ranked list so nobody has to
            // wonder whether the list is a timetable of fixed departures.
            _LeavingNowStrip(query: query),
            const SizedBox(height: 20),
            SectionLabel(
              'Ways to travel',
              trailing: Text(
                '${journey.options.length} ${journey.options.length == 1 ? 'option' : 'options'}',
                style: const TextStyle(
                  fontSize: 12,
                  color: WimbColors.inkMuted,
                ),
              ),
            ),
            // Says how the ranking was worked out, so a number like "59 min"
            // reads as walk + wait + ride rather than as a mystery score.
            Padding(
              padding: const EdgeInsets.only(bottom: WimbSpace.card),
              child: Text(
                'Ranked by total time: walk + wait + ride.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (sharedFirstLegNote != null) ...[
              InfoBanner(icon: Icons.directions_bus, text: sharedFirstLegNote),
              const SizedBox(height: WimbSpace.card),
            ],
            // Numbered, because the list is RANKED - the first really is
            // the best by total time, and a plain list would hide that.
            for (var i = 0; i < journey.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OptionCard(
                  option: journey.options[i],
                  rank: i + 1,
                  query: query,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The strip above the ranked list that says the times are for leaving now,
/// and offers the by-hour comparison.
///
/// The list is costed from the moment of the search, which is not obvious
/// from cards that only show durations. This strip names that moment, and it
/// is the single, obvious way into the by-hour screen - the quiet "Compare
/// this trip by hour" text button under "Find buses" is gone.
class _LeavingNowStrip extends StatelessWidget {
  final JourneyQuery query;

  const _LeavingNowStrip({required this.query});

  /// Opens the by-hour comparison already set to this trip's two places, so
  /// nobody has to choose them again on the next screen.
  void _openByHour(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ByHourScreen(
          initialFrom: PlaceSuggestion(
            stopName: query.fromName,
            lat: query.fromLat,
            lon: query.fromLon,
          ),
          initialTo: PlaceSuggestion(
            stopName: query.toName,
            lat: query.toLat,
            lon: query.toLon,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: WimbColors.surfaceMuted,
        borderRadius: BorderRadius.circular(WimbRadius.field),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.schedule,
                  size: 16,
                  color: WimbColors.inkMuted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Times below are for leaving now (${_nowClockTime()}).',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    color: WimbColors.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Full width, and the only button on the results screen besides
          // the cards themselves: this is the one way into the hour view.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openByHour(context),
              style: OutlinedButton.styleFrom(
                backgroundColor: WimbColors.cardCream,
                foregroundColor: WimbColors.ink,
              ),
              icon: const Icon(Icons.insights, size: 17),
              label: const Text('Compare hours of the day'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains the one thing the old results list never said: when several
/// options begin with the same bus, the repeated route number is not the
/// planner repeating itself - only the connection taken after that first
/// ride differs.
///
/// Returns the sentence to show above the list, or null when the options do
/// not share a first leg strongly enough for the note to be worth it.
String? _sharedFirstLegNote(List<JourneyOption> options) {
  if (options.isEmpty) return null;

  // Direct-only results need a different sentence: there is no connection
  // to explain, only the fact that no change is needed at all.
  final directCount = options.where((option) => option.legs.length == 1).length;
  if (directCount == options.length) {
    return '$directCount ${directCount == 1 ? 'direct bus' : 'direct buses'} - no change needed.';
  }

  // Count how many one-change options start with each identical first leg.
  // Only one-change options need this note; a direct option has no second
  // leg whose route could vary.
  final countByFirstLeg = <String, int>{};
  final firstLegByKey = <String, JourneyLeg>{};
  for (final option in options) {
    if (option.legs.length != 2) continue;
    final first = option.legs.first;
    // The three fields that make two first legs "the same bus ride".
    final key = '${first.routeName}|${first.boardPlace}|${first.alightPlace}';
    countByFirstLeg[key] = (countByFirstLeg[key] ?? 0) + 1;
    firstLegByKey[key] = first;
  }
  if (countByFirstLeg.isEmpty) return null;

  var biggestKey = '';
  var biggestCount = 0;
  countByFirstLeg.forEach((key, count) {
    if (count > biggestCount) {
      biggestKey = key;
      biggestCount = count;
    }
  });

  // Below three options the repetition is not confusing enough to explain,
  // unless every single option shares that first leg.
  if (biggestCount < 3 && biggestCount != options.length) return null;

  final first = firstLegByKey[biggestKey]!;
  final opening = biggestCount == options.length
      ? 'All $biggestCount options'
      : '$biggestCount of these ${options.length} options';
  return '$opening begin with ${first.routeName} from '
      '${first.boardPlace} to ${first.alightPlace}. The choice is which '
      'connection you take there; they are ranked by total time.';
}

/// The answer at a glance, in the shape of a departure card: where you are
/// going from, where to, the route between them, and the fastest window.
///
/// The arrangement follows lookap entry "Flight Status Card
/// Microinteraction" by Michael Nowak (@mnowakdesign) - origin and
/// destination set large at the two ends, a thin line with the vehicle in
/// the middle, quiet times underneath. The colours, type and proportions
/// are this app's own; only the information order is borrowed.
class _JourneySummaryCard extends StatelessWidget {
  final JourneyQuery query;
  final JourneyOption option;
  final int count;

  const _JourneySummaryCard({
    required this.query,
    required this.option,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final earliest = _clockTime(DateTime.now(), option.earliestMinutes);
    final latest = _clockTime(DateTime.now(), option.latestMinutes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SummaryLabel('FROM'),
                      const SizedBox(height: 4),
                      Text(
                        query.fromName,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontSize: 17.5),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      StatusPill(
                        label: '$count ${count == 1 ? 'WAY' : 'WAYS'}',
                        color: WimbColors.dtcRed,
                        filled: false,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: WimbColors.dtcRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.directions_bus,
                          size: 19,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const _SummaryLabel('TO'),
                      const SizedBox(height: 4),
                      Text(
                        query.toName,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontSize: 17.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // A continuous route line tying the two names together. The
            // bus sits on it rather than beside it, so the card reads as a
            // trip in progress instead of two unrelated places.
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: WimbColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.arrow_forward,
                    size: 16,
                    color: WimbColors.inkFaint,
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: WimbColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${option.totalMinutes.round()} min',
                        style: const TextStyle(
                          fontFamily: WimbFonts.condensed,
                          fontFamilyFallback: WimbFonts.fallback,
                          fontSize: 28,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: WimbColors.delhiGreen,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Fastest option now',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _TimePill(text: '$earliest – $latest'),
                    const SizedBox(height: 5),
                    Text(
                      'arrival window',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny all-caps label above a value inside the summary card.
class _SummaryLabel extends StatelessWidget {
  final String text;
  const _SummaryLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
        color: WimbColors.inkMuted,
      ),
    );
  }
}

/// A quiet time pill, like the ones under a departure time. One widget so
/// the summary and the option rows cannot drift apart.
class _TimePill extends StatelessWidget {
  final String text;
  const _TimePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: WimbColors.surfaceMuted,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 14, color: WimbColors.inkMuted),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: WimbFonts.tabular,
              color: WimbColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper to calculate and format transit distance between two journey points.
String _calculateDistance(JourneyQuery query) {
  final distM = const Distance().as(
    LengthUnit.Meter,
    LatLng(query.fromLat, query.fromLon),
    LatLng(query.toLat, query.toLon),
  );
  if (distM < 1000) {
    return '${distM.round()} m';
  } else {
    return '${(distM / 1000).toStringAsFixed(1)} km';
  }
}

/// Builds the "how to do this trip" sentence from the actual legs, e.g.
/// "Board 392BDOWN at Noida Sec-10-21 · change at Andrews Ganj · then 724UP
/// to Lady Shri Ram College".
///
/// The old version printed just `<first board place> to <last alight place>`,
/// which was identical for every option in a shared-first-leg list and hid
/// the one thing that actually differs: the connection taken after the first
/// bus. Kept to plain words, with a middle dot between the steps.
String _stepsSentence(JourneyOption option) {
  // Defensive: there is nothing to describe if the planner sent no legs.
  if (option.legs.isEmpty) return option.summary;

  final first = option.legs.first;
  if (option.legs.length == 1) {
    return 'Board ${first.routeName} at ${first.boardPlace} · get off at ${first.alightPlace}';
  }

  final second = option.legs[1];
  return 'Board ${first.routeName} at ${first.boardPlace} · '
      'change at ${first.alightPlace} · then ${second.routeName} to ${second.alightPlace}';
}

/// One route board with a tiny caption above it saying which bus it is
/// ("1ST BUS", "2ND BUS" or "DIRECT BUS").
///
/// Without the caption, two boards side by side in one card read as "this
/// bus goes to several places" - exactly how the repeated 392BDOWN first
/// leg was misread as a planner bug.
class _LabelledRouteBoard extends StatelessWidget {
  final String caption;
  final String routeName;

  const _LabelledRouteBoard({required this.caption, required this.routeName});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          caption,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: WimbColors.inkMuted,
          ),
        ),
        const SizedBox(height: 3),
        RouteBoard(routeName: routeName, compact: true),
      ],
    );
  }
}

/// One ranked way to make the journey: compact by default showing bus badges,
/// duration, distance, and transfer summary, expandable on tap for detailed steps.
class _OptionCard extends ConsumerStatefulWidget {
  final JourneyOption option;
  final int rank;
  final JourneyQuery query;

  const _OptionCard({
    required this.option,
    required this.rank,
    required this.query,
  });

  @override
  ConsumerState<_OptionCard> createState() => _OptionCardState();
}

class _OptionCardState extends ConsumerState<_OptionCard> {
  bool _expanded = false;

  String _friendlyConfidence(String level) {
    switch (level) {
      case 'high':
        return 'High-frequency service with reliable live data';
      case 'medium':
        return 'Regular service based on observed transit patterns';
      case 'low':
      default:
        return 'Estimated schedule timing';
    }
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    final isBest = widget.rank == 1;
    final distanceStr = _calculateDistance(widget.query);
    final totalStops = option.legs.fold<int>(0, (sum, leg) => sum + leg.stops);
    final earliestClock = _clockTime(DateTime.now(), option.earliestMinutes);
    final latestClock = _clockTime(DateTime.now(), option.latestMinutes);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header strip: the two route boards with their role captions,
            // FASTEST / rank, and the expand control. The old DIRECT /
            // 1 CHANGE pill is gone - the caption above each board says the
            // same thing more clearly, and keeping both made this row
            // overflow on a phone-width screen. The coloured band is gone
            // too: on a white card a pill is enough to mark the best option,
            // and tinting the whole header made every option look selected.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
              child: Row(
                children: [
                  // Each board is captioned with its role, so two boards in
                  // one card cannot be read as one bus heading to several
                  // places. The captions are also what makes the shared
                  // first leg visible at a glance.
                  if (option.legs.length == 1)
                    _LabelledRouteBoard(
                      caption: 'DIRECT BUS',
                      routeName: option.legs[0].routeName,
                    )
                  else ...[
                    _LabelledRouteBoard(
                      caption: '1ST BUS',
                      routeName: option.legs[0].routeName,
                    ),
                    // Nudged down by the caption's height so the arrow sits
                    // level with the two boards, not with their captions.
                    const Padding(
                      padding: EdgeInsets.fromLTRB(6, 13, 6, 0),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: WimbColors.inkFaint,
                      ),
                    ),
                    _LabelledRouteBoard(
                      caption: '2ND BUS',
                      routeName: option.legs[1].routeName,
                    ),
                  ],
                  const Spacer(),
                  if (isBest)
                    const StatusPill(
                      label: 'FASTEST',
                      color: WimbColors.delhiGreen,
                    )
                  else
                    Text(
                      '#${widget.rank}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: WimbColors.inkMuted,
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 22,
                    color: WimbColors.inkMuted,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Metrics and summary. The big number is the total, the range
            // sits beside it rather than inside a parenthetical, and the
            // distance is a quiet chip on the right.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${option.totalMinutes.round()}',
                        style: TextStyle(
                          fontFamily: WimbFonts.condensed,
                          fontFamilyFallback: WimbFonts.fallback,
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: isBest
                              ? WimbColors.delhiGreen
                              : WimbColors.ink,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          'min',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isBest
                                ? WimbColors.delhiGreen
                                : WimbColors.inkMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            '${option.earliestMinutes.round()}–${option.latestMinutes.round()} min window',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: WimbColors.surfaceMuted,
                          borderRadius: BorderRadius.circular(WimbRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.straighten,
                              size: 12,
                              color: WimbColors.inkMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              distanceStr,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: WimbColors.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule,
                        size: 14,
                        color: WimbColors.inkMuted,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'Arrive $earliestClock – $latestClock',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '$totalStops stops',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // The trip in steps, built from the actual legs. It is the
                  // line that tells a first-time reader what happens and in
                  // what order; "Noida Sec-10-21 to Lady Shri Ram College"
                  // used to sit here and said the same thing on every card.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _stepsSentence(option),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                            color: WimbColors.ink,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _expanded ? 'Hide steps' : 'View steps',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: WimbColors.dtcRed,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Height animates instead of snapping, so opening an option
            // feels like unfolding it rather than replacing the list.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? _expandedTimeline(context)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _expandedTimeline(BuildContext context) {
    final option = widget.option;
    final lastLeg = option.legs.isNotEmpty ? option.legs.last : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (option.walkMinutes > 0.5) ...[
                _step(
                  context,
                  Icons.directions_walk,
                  'Walk ~${option.walkMinutes.round()} min to ${option.legs.first.boardPlace}',
                  WimbColors.inkMuted,
                ),
                const SizedBox(height: 10),
              ],
              for (var i = 0; i < option.legs.length; i++) ...[
                _legDetail(
                  context,
                  option.legs[i],
                  isLastLeg: i == option.legs.length - 1,
                ),
                if (i < option.legs.length - 1) ...[
                  const SizedBox(height: 10),
                  _step(
                    context,
                    Icons.transfer_within_a_station,
                    'Change at ${option.legs[i].alightPlace} (wait ~${option.legs[i + 1].waitMinutes.round()} min)',
                    WimbColors.statusEstimated,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              const SizedBox(height: 14),
              _breakdownBar(context),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.bar_chart,
                    size: 13,
                    color: WimbColors.statusHistorical,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _friendlyConfidence(option.confidence.level),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: WimbColors.inkMuted,
                      ),
                    ),
                  ),
                ],
              ),
              if (lastLeg != null) ...[
                const SizedBox(height: 12),
                _buildAlarmButton(context, ref, lastLeg),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _legDetail(
    BuildContext context,
    JourneyLeg leg, {
    required bool isLastLeg,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            RouteBoard(routeName: leg.routeName, compact: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                leg.routeDesc.isNotEmpty ? leg.routeDesc : 'To destination',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: WimbColors.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _step(
          context,
          Icons.arrow_circle_up,
          'Board at ${leg.boardPlace}',
          WimbColors.delhiGreen,
        ),
        const SizedBox(height: 4),
        _step(
          context,
          Icons.arrow_circle_down,
          isLastLeg
              ? 'Get off at ${leg.alightPlace}'
              : 'Alight at ${leg.alightPlace}',
          isLastLeg ? WimbColors.dtcRed : WimbColors.statusEstimated,
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Text(
            '${leg.stops} stops · ~${leg.rideMinutes.round()} min ride'
            '${leg.busEveryMinutes != null ? ' · every ~${leg.busEveryMinutes!.round()} min' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _step(BuildContext context, IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5, right: 6),
          child: Icon(icon, size: 14, color: color),
        ),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.3)),
        ),
      ],
    );
  }

  Widget _breakdownBar(BuildContext context) {
    final walk = widget.option.walkMinutes;
    final wait = widget.option.waitMinutes;
    final ride = widget.option.rideMinutes;
    final total = walk + wait + ride;
    if (total <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                Expanded(
                  flex: (walk * 100).round(),
                  child: Container(color: WimbColors.inkMuted),
                ),
                Expanded(
                  flex: (wait * 100).round(),
                  child: Container(color: WimbColors.statusEstimated),
                ),
                Expanded(
                  flex: (ride * 100).round(),
                  child: Container(color: WimbColors.dtcRed),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 12,
          children: [
            _legendItem(WimbColors.inkMuted, 'walk ${walk.round()}m'),
            _legendItem(WimbColors.statusEstimated, 'wait ${wait.round()}m'),
            _legendItem(WimbColors.dtcRed, 'ride ${ride.round()}m'),
          ],
        ),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: WimbColors.inkMuted),
        ),
      ],
    );
  }

  Widget _buildAlarmButton(
    BuildContext context,
    WidgetRef ref,
    JourneyLeg lastLeg,
  ) {
    final alarm = ref.watch(arrivalAlarmProvider);
    final isAlarmActive =
        alarm.isActive &&
        alarm.routeId == lastLeg.routeId &&
        alarm.targetStopName == lastLeg.alightPlace;

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: isAlarmActive
              ? WimbColors.delhiGreen
              : WimbColors.dtcRed,
          side: BorderSide(
            color: isAlarmActive
                ? WimbColors.delhiGreen.withValues(alpha: 0.45)
                : WimbColors.dtcRed.withValues(alpha: 0.30),
            width: 1,
          ),
          backgroundColor: isAlarmActive
              ? WimbColors.delhiGreenLight
              : WimbColors.dtcRed.withValues(alpha: 0.06),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WimbRadius.field),
          ),
        ),
        onPressed: () {
          if (isAlarmActive) {
            ref.read(arrivalAlarmProvider.notifier).dismiss();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Arrival alarm cancelled.'),
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            ref
                .read(arrivalAlarmProvider.notifier)
                .setAlarm(
                  routeId: lastLeg.routeId,
                  routeName: lastLeg.routeName,
                  targetStopName: lastLeg.alightPlace,
                  targetStopSequence: lastLeg.stops,
                  stopThreshold: 1,
                  minuteThreshold: 5,
                );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Arrival alarm set for ${lastLeg.alightPlace}. You will be alerted before arrival!',
                ),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
        icon: Icon(
          isAlarmActive ? Icons.alarm_on : Icons.notification_add_outlined,
          size: 16,
        ),
        label: Text(
          isAlarmActive
              ? 'Alarm Active for ${lastLeg.alightPlace}'
              : 'Set Arrival Alarm for ${lastLeg.alightPlace}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
