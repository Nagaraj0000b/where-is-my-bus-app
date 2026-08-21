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
import 'place_search_field.dart';

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
  // Empty on purpose - a real commuter doesn't have a pre-filled journey
  // to start from. Both fields have to be searched (or "From" filled from
  // GPS) before "Find buses" will do anything.
  final _fromController = TextEditingController();
  final _toController = TextEditingController();

  // The actual coordinates behind each text box. Only set when someone
  // picks a suggestion (or uses their GPS location) - never guessed from
  // whatever text happens to be typed, so a half-typed search can't
  // silently plan a journey from the wrong place.
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;

  // True while waiting on the phone's GPS, so the button can show a
  // spinner instead of looking like it did nothing.
  bool _locating = false;

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _search() {
    // Guards against the case where someone typed over a picked
    // suggestion but never tapped a new one - the text box would show
    // something that isn't backed by real coordinates any more.
    if (_fromPlace == null || _fromController.text != _fromPlace!.stopName) {
      _showMessage('Pick a "From" place from the suggestions.');
      return;
    }
    if (_toPlace == null || _toController.text != _toPlace!.stopName) {
      _showMessage('Pick a "To" place from the suggestions.');
      return;
    }

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
      setState(() {
        _fromPlace = PlaceSuggestion(
          stopName: 'Your location',
          lat: position.latitude,
          lon: position.longitude,
        );
        _fromController.text = _fromPlace!.stopName;
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

    return Scaffold(
      appBar: AppBar(title: const Text('Where Is My Bus')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Where are you, and where are you going?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          PlaceSearchField(
            label: 'From',
            controller: _fromController,
            onPicked: (place) => setState(() => _fromPlace = place),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _locating ? null : _useMyLocation,
              icon: _locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location, size: 18),
              label: const Text('Use my location'),
            ),
          ),
          const SizedBox(height: 8),
          PlaceSearchField(
            label: 'To',
            controller: _toController,
            onPicked: (place) => setState(() => _toPlace = place),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _search, child: const Text('Find buses')),
          const SizedBox(height: 24),
          if (query == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Pick a "From" and a "To", then find buses to see ranked '
                  'ways to make the trip, with an honest time range for each.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            _ResultsArea(query: query),
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
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${query.fromName} → ${query.toName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final option in journey.options)
              _OptionCard(option: option, askedAt: query.askedAt),
            const SizedBox(height: 8),
            ...journey.caveats.map(
              (c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '• $c',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One ranked way to make the journey, with its time range (as both a
/// duration and a real clock time) and the reason to trust - or not trust -
/// that range. Never just a bare number.
class _OptionCard extends StatelessWidget {
  final JourneyOption option;
  final DateTime askedAt;
  const _OptionCard({required this.option, required this.askedAt});

  Color _confidenceColor(BuildContext context) {
    switch (option.confidence.level) {
      case 'high':
        return Colors.green;
      case 'medium':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  /// One "board here, get off there" instruction for a single bus leg -
  /// the direct answer to "what do I actually do", rather than a sentence
  /// that has to be parsed to find the boarding stop.
  Widget _legInstruction(BuildContext context, JourneyLeg leg, {required bool isLastLeg}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Board bus ${leg.routeName} at ${leg.boardPlace}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        if (leg.routeDesc.isNotEmpty)
          Text(
            'Destination board on the bus reads: ${leg.routeDesc}',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        Text(isLastLeg
            ? 'Get off at ${leg.alightPlace}'
            : 'Get off at ${leg.alightPlace}, then change buses'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final earliestClock = _clockTime(askedAt, option.earliestMinutes);
    final latestClock = _clockTime(askedAt, option.latestMinutes);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < option.legs.length; i++) ...[
              _legInstruction(context, option.legs[i], isLastLeg: i == option.legs.length - 1),
              if (i < option.legs.length - 1) const SizedBox(height: 6),
            ],
            const SizedBox(height: 8),
            Text(
              'Arrive $earliestClock – $latestClock',
              style: const TextStyle(fontSize: 18),
            ),
            Text(
              '${option.earliestMinutes.round()}–${option.latestMinutes.round()} min from now '
              '(typically ${option.totalMinutes.round()})',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.circle, size: 10, color: _confidenceColor(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    option.confidence.because,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
