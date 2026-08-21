// The journey planner screen - the first real screen of the app.
//
// Two points in, ranked ways to travel out - see api/src/journey.ts for why
// this (not a live map) is "the screen the whole app is really for". It's
// also the honest first screen to build: there's no live vehicle feed right
// now (the recorder was deliberately stopped), so a "buses arriving now"
// screen would have to fake it. This screen only ever shows things the data
// can actually back up.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'api_client.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'theme.dart';

/// Turns a number of minutes from now into a real clock time, e.g. "7:15 PM".
/// The backend only ever gives back a DURATION (never a clock time - see
/// api/src/journey.ts), so turning that into "arrives around..." is done
/// here, on the device, using the moment the search was actually made.
final _clockFormat = DateFormat('h:mm a');
String _clockTime(DateTime askedAt, double minutesFromAskedAt) {
  final at = askedAt.add(Duration(minutes: minutesFromAskedAt.round()));
  return _clockFormat.format(at);
}

/// The two points a journey is being planned between, plus the moment the
/// search was made. `askedAt` is part of the query (not just a display
/// detail) so that pressing "Find buses" again always asks the backend
/// fresh, and so the clock times shown next to a result never silently
/// drift if the screen happens to rebuild later.
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
  const JourneyScreen({super.key});

  @override
  ConsumerState<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends ConsumerState<JourneyScreen> {
  // The two chosen places, each with the real coordinates behind it. Null
  // until something is picked - a commuter has no pre-filled journey.
  //
  // There are no text controllers any more. A place can now ONLY arrive by
  // being picked from the search page or from GPS, so the old problem of
  // text that no longer matches the coordinates behind it - someone typing
  // over a chosen suggestion - cannot happen at all rather than being
  // guarded against.
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;

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

  /// Fills in the "From" point using the phone's real GPS position, instead
  /// of asking someone to search for wherever they're currently standing.
  ///
  /// Three things can stop this working, and each gets its own honest
  /// message rather than one generic failure: location turned off on the
  /// phone, permission refused once, or permission refused permanently
  /// (which needs a trip to phone Settings, not just asking again).
  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage('Location is turned off. Turn it on in phone settings to use this.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _showMessage('Location permission was refused, so "From" can\'t be filled in automatically.');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _showMessage('Location permission is permanently refused. Enable it for this app in phone Settings.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      // Setting the place is all that is needed now - the From row reads
      // straight from it, where before the text box had to be kept in step
      // separately.
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(journeyQueryProvider);

    final canSearch = _fromPlace != null && _toPlace != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Plan a journey')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: [
          _whereToWhereCard(context),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: canSearch ? _search : null,
            child: const Text('Find buses'),
          ),
          const SizedBox(height: 24),
          if (query == null) _emptyState(context) else _ResultsArea(query: query),
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
          const Divider(height: 1, indent: 48),
          PlacePickerRow(
            label: 'TO',
            place: _toPlace,
            icon: Icons.place,
            iconColor: WimbColors.dtcRed,
            onPicked: (place) => setState(() => _toPlace = place),
          ),
          const Divider(height: 1),
          // A quiet strip along the bottom rather than a button floating
          // in the middle of the form.
          InkWell(
            onTap: _locating ? null : _useMyLocation,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_locating)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.my_location, size: 17, color: WimbColors.delhiGreen),
                  const SizedBox(width: 9),
                  Text(
                    _locating ? 'Finding you...' : 'Use my location as the start',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: WimbColors.delhiGreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the screen shows before anything has been searched. Explains what
  /// will happen rather than leaving a blank space.
  Widget _emptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 22),
      child: Column(
        children: [
          Icon(Icons.alt_route, size: 44, color: WimbColors.hairline),
          const SizedBox(height: 14),
          Text(
            'Pick a From and a To.',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'You will get ways to make the trip ranked by total time - '
            'walking, waiting and riding all counted - each with an honest '
            'range rather than one number.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Shows loading / error / results for whatever query is currently set.
/// Split out from the main screen so it only rebuilds itself when the
/// fetch's state changes, not the whole form.
class _ResultsArea extends ConsumerWidget {
  final JourneyQuery query;
  const _ResultsArea({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(journeyResultProvider(query));

    return result.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      // Unlike "no route found" below, this branch means the request
      // itself never completed honestly (unreachable server, bad
      // response) - so, unlike that branch, retrying the SAME query can
      // actually give a different answer, and is worth offering.
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Ways to travel'),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const Icon(Icons.trip_origin, size: 14, color: WimbColors.delhiGreen),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${query.fromName}  →  ${query.toName}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            // Numbered, because the list is RANKED - the first really is
            // the best by total time, and a plain list would hide that.
            for (var i = 0; i < journey.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OptionCard(
                  option: journey.options[i],
                  askedAt: query.askedAt,
                  rank: i + 1,
                ),
              ),
            const SizedBox(height: 6),
            ...journey.caveats.map((c) => CaveatLine(c)),
          ],
        );
      },
    );
  }
}

/// One ranked way to make the journey: the buses to take, drawn as real
/// destination boards, and the time range as both a duration and a clock
/// time - with the reason to trust or distrust it. Never a bare number.
class _OptionCard extends StatelessWidget {
  final JourneyOption option;
  final DateTime askedAt;

  /// 1 for the best option, 2 for the next, and so on.
  final int rank;

  const _OptionCard({required this.option, required this.askedAt, required this.rank});

  @override
  Widget build(BuildContext context) {
    final earliestClock = _clockTime(askedAt, option.earliestMinutes);
    final latestClock = _clockTime(askedAt, option.latestMinutes);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _headline(context, earliestClock, latestClock),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < option.legs.length; i++) ...[
                  _leg(context, option.legs[i], isLastLeg: i == option.legs.length - 1),
                  if (i < option.legs.length - 1) const SizedBox(height: 14),
                ],
                const SizedBox(height: 14),
                _breakdownBar(context),
                const SizedBox(height: 12),
                TrustDots(level: option.confidence.level),
                const SizedBox(height: 5),
                Text(option.confidence.because, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The top strip: rank, total time, and when you would actually arrive.
  /// Tinted green for the best option so the ranking is visible instantly.
  Widget _headline(BuildContext context, String earliestClock, String latestClock) {
    final isBest = rank == 1;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isBest ? WimbColors.delhiGreenLight : WimbColors.cardCream,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${option.earliestMinutes.round()}–${option.latestMinutes.round()}',
                      style: TextStyle(
                        fontFamily: WimbFonts.condensed,
                        fontFamilyFallback: WimbFonts.fallback,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                        color: isBest ? WimbColors.delhiGreen : WimbColors.ink,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        'min',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isBest ? WimbColors.delhiGreen : WimbColors.inkMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'arrive $earliestClock – $latestClock · typically '
                  '${option.totalMinutes.round()} min',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (isBest)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: WimbColors.delhiGreen,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'FASTEST',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            )
          else
            Text(
              '#$rank',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: WimbColors.inkMuted,
              ),
            ),
        ],
      ),
    );
  }

  /// One bus: which one to board, where, and where to get off. The route
  /// is drawn as the destination board it would carry on the road, so it
  /// matches what someone is actually looking for at the stop.
  Widget _leg(BuildContext context, JourneyLeg leg, {required bool isLastLeg}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Capped, same reasoning as the search list in routes_screen.dart -
        // a route number or a destination board text long enough (both
        // happen in Delhi's GTFS) would otherwise push this row past the
        // card's edge.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: RouteBoard(routeName: leg.routeName, destination: leg.routeDesc),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _step(context, Icons.arrow_circle_up, 'Board at ${leg.boardPlace}',
                  WimbColors.delhiGreen),
              const SizedBox(height: 3),
              _step(
                context,
                Icons.arrow_circle_down,
                isLastLeg
                    ? 'Get off at ${leg.alightPlace}'
                    : 'Get off at ${leg.alightPlace}, then change',
                isLastLeg ? WimbColors.dtcRed : WimbColors.trustMedium,
              ),
              if (leg.busEveryMinutes != null) ...[
                const SizedBox(height: 4),
                Text(
                  'about every ${leg.busEveryMinutes!.round()} min · ${leg.stops} stops',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
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
          child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.3)),
        ),
      ],
    );
  }

  /// Walk / wait / ride as one proportional bar.
  ///
  /// Worth showing because the whole ranking rests on it: this app ranks by
  /// TOTAL time, so an option can win with a slower ride simply because its
  /// bus comes more often. The bar makes that visible instead of asking
  /// someone to trust the ordering.
  Widget _breakdownBar(BuildContext context) {
    final walk = option.walkMinutes;
    final wait = option.waitMinutes;
    final ride = option.rideMinutes;
    final total = walk + wait + ride;
    if (total <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 7,
            child: Row(
              children: [
                // flex takes whole numbers, so the minutes are scaled up
                // before rounding - otherwise a 0.4-minute walk would
                // round to 0 and vanish from the bar entirely.
                Expanded(flex: (walk * 100).round(), child: Container(color: WimbColors.inkMuted)),
                Expanded(flex: (wait * 100).round(), child: Container(color: WimbColors.trustMedium)),
                Expanded(flex: (ride * 100).round(), child: Container(color: WimbColors.dtcRed)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 13,
          children: [
            _legendItem(WimbColors.inkMuted, 'walk ${walk.round()}m'),
            _legendItem(WimbColors.trustMedium, 'wait ${wait.round()}m'),
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
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11.5, color: WimbColors.inkMuted)),
      ],
    );
  }
}
