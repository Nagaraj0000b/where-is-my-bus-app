// The home screen: the stop you are standing at, and the buses coming to it.
//
// No sign-in wall, no "where are you going" form. The map is context; the
// board is the product. The board is built from the recorded Delhi feed and
// observed frequencies; it never claims a live position it does not have.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'arrival_widgets.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'ride_screen.dart';
import 'route_screen.dart';
import 'search_screen.dart';
import 'stop_screen.dart';
import 'theme.dart';
import 'transit_map.dart';

class _DemoHub {
  final String name;
  final String shortName;
  final double lat;
  final double lon;

  const _DemoHub({
    required this.name,
    required this.shortName,
    required this.lat,
    required this.lon,
  });
}

/// Places a demonstrator can stand when they are not in Delhi. The app
/// never uses these silently; choosing one keeps the SIMULATED tag on the
/// map chip.
const _demoHubs = [
  _DemoHub(
    name: 'Connaught Place',
    shortName: 'CP',
    lat: 28.6323,
    lon: 77.2165,
  ),
  _DemoHub(name: 'AIIMS', shortName: 'AIIMS', lat: 28.5670, lon: 77.2080),
  _DemoHub(
    name: 'Nehru Place',
    shortName: 'Nehru Place',
    lat: 28.5487,
    lon: 77.2570,
  ),
  _DemoHub(
    name: 'Kashmere Gate',
    shortName: 'Kashmere Gate',
    lat: 28.6668,
    lon: 77.2294,
  ),
  _DemoHub(
    name: 'Anand Vihar',
    shortName: 'Anand Vihar',
    lat: 28.6470,
    lon: 77.3176,
  ),
  _DemoHub(
    name: 'Dhaula Kuan',
    shortName: 'Dhaula Kuan',
    lat: 28.5947,
    lon: 77.1661,
  ),
];

/// A short place name for the map chip. "Shivaji Stadium Terminal
/// (Connaught Place)" becomes "Shivaji Stadium".
String _shortLocationName(String name) {
  final withoutParenthetical = name.split('(').first.trim();
  return withoutParenthetical.replaceAll(RegExp(r'\s+Terminal$'), '').trim();
}

class NearbyScreen extends ConsumerStatefulWidget {
  final VoidCallback? onOpenPlan;
  final bool enableMapTiles;

  const NearbyScreen({super.key, this.onOpenPlan, this.enableMapTiles = true});

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen> {
  LatLng? _userLocation;
  List<NearbyStop> _nearby = [];
  NearbyStop? _selected;
  StopArrivals? _board;
  String? _error;

  bool _locating = true;
  bool _loadingBoard = false;
  bool _locationDenied = false;
  bool _outsideDelhi = false;
  bool _demo = false;
  bool _showMap = true;
  String? _demoName;

  /// The official feed state, so the board can say honestly whether it is
  /// showing live buses or a recorded moment.
  TransitFeedStatus? _feed;

  /// When this is set the board is replaying that recorded moment. The
  /// recorder is stopped, so without a moment to replay the board would have
  /// no buses at all - only frequency rows - and there would be no positions
  /// (and so no location proofs) to show. Null means "ask for live buses".
  DateTime? _replayAt;

  /// The place the rider is heading to, when the "Where to?" filter is on.
  ///
  /// It is deliberately not reset when the boarding stop changes: once a
  /// rider has said where they are going, changing the stop should keep
  /// answering about the same destination. Null means the board shows every
  /// bus arriving here, in whichever direction it continues.
  PlaceSuggestion? _destination;

  /// Counts board requests, so a slow, older answer cannot overwrite a newer
  /// one. This can happen for real: the 20 s poll is in flight, and the
  /// rider picks a destination before the old answer lands.
  int _boardRequestId = 0;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // A recorded moment never changes, so only poll while asking for live
    // buses. Polling a replay would re-fetch exactly the same board.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_replayAt == null) _refreshBoard();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    await _locate();
    // After locating: work out whether the feed is live. If it is not (the
    // normal case - the recorder was stopped), the board falls back to a
    // clearly labelled recorded moment instead of showing nothing.
    await _loadFeedStatus();
  }

  /// Ask the API whether the official feed is live, and if not, choose a
  /// recorded moment to replay.
  Future<void> _loadFeedStatus() async {
    try {
      final status = await fetchTransitFeedStatus();
      if (!mounted) return;
      setState(() {
        _feed = status;
        if (!status.live && status.replayDays.isNotEmpty) {
          _replayAt = _defaultReplayMoment(status);
        }
      });
      if (_selected != null) await _refreshBoard();
    } catch (_) {
      // No feed status means no proof of what the board is showing, so stay
      // on the honest default: ask for live buses and let the board's own
      // fallback (observed frequency) explain the gap.
    }
  }

  /// The moment the board replays when there is no live feed.
  ///
  /// A recorded day whose RAW GPS readings are still loaded is preferred,
  /// because only those days can attach a location proof - the proof needs
  /// the raw fix, not the interpolated replay position. 1:30 pm is a busy
  /// midday moment, so the board has buses on it.
  DateTime _defaultReplayMoment(TransitFeedStatus status) {
    final rawDays = status.rawPositionDays.toSet();
    FeedDay? preferred;
    for (final day in status.replayDays) {
      if (rawDays.contains(day.day)) {
        preferred = day;
        break;
      }
    }
    final day = preferred ?? status.replayDays.first;
    final firstLocal = day.firstAt.toLocal();
    final lastLocal = day.lastAt.toLocal();

    final afternoon = DateTime(
      firstLocal.year,
      firstLocal.month,
      firstLocal.day,
      13,
      30,
    );
    if (afternoon.isBefore(firstLocal)) return firstLocal;
    if (afternoon.isAfter(lastLocal)) {
      return lastLocal.subtract(const Duration(minutes: 20));
    }
    return afternoon;
  }

  /// Stop replaying and ask the API for live buses instead.
  void _useFrequencyInstead() {
    setState(() => _replayAt = null);
    _refreshBoard();
  }

  /// Go back to the recorded moment, e.g. after "use frequency instead".
  void _replayLastRecorded() {
    final feed = _feed;
    if (feed == null || feed.replayDays.isEmpty) return;
    setState(() => _replayAt = _defaultReplayMoment(feed));
    _refreshBoard();
  }

  Future<void> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setLocationProblem('Location is turned off.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setLocationProblem('Location permission was refused.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );

      final inDelhi =
          position.latitude >= 28.2 &&
          position.latitude <= 29.0 &&
          position.longitude >= 76.7 &&
          position.longitude <= 77.6;

      if (!inDelhi) {
        setState(() {
          _locating = false;
          _outsideDelhi = true;
        });
        return;
      }

      final location = LatLng(position.latitude, position.longitude);
      setState(() {
        _userLocation = location;
        _locating = false;
        _outsideDelhi = false;
      });
      await _loadNearby(location);
    } catch (_) {
      _setLocationProblem('Could not read your location.');
    }
  }

  void _setLocationProblem(String message) {
    setState(() {
      _locating = false;
      _locationDenied = true;
      _error = message;
    });
  }

  Future<void> _loadNearby(LatLng location) async {
    final stops = await fetchNearbyStops(
      lat: location.latitude,
      lon: location.longitude,
      radiusMetres: 800,
    );

    if (!mounted) return;
    setState(() {
      _nearby = stops;
      _selected = stops.isNotEmpty ? stops.first : null;
    });

    if (_selected != null) {
      await _refreshBoard();
    }
  }

  Future<void> _refreshBoard() async {
    final stop = _selected;
    if (stop == null) return;

    final destinationRequested = _destination != null;
    final requestId = ++_boardRequestId;
    setState(() {
      _loadingBoard = true;
      _error = null;
    });

    try {
      final board = await fetchStopArrivals(
        placeId: stop.placeId,
        at: _replayAt,
        // The destination filter, when the rider has set one. Every refresh
        // carries it, otherwise the board would quietly fall back to "all
        // buses here" while the label still said "to B".
        toPlaceId: _destination?.placeId,
      );
      if (!mounted || requestId != _boardRequestId) return;

      // A server that does not know about `to` ignores it and answers with
      // the plain board - which has no destination in the reply. Labeling
      // those rows "to B" would be false, so the filter is dropped and the
      // rider is told why, instead of pretending the question was answered.
      final serverIgnoredDestination =
          destinationRequested && board.destination == null;

      setState(() {
        _board = board;
        _loadingBoard = false;
        if (serverIgnoredDestination) _destination = null;
      });
      if (serverIgnoredDestination) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The destination filter is not available right now. '
              'Showing every bus arriving here.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted || requestId != _boardRequestId) return;
      setState(() {
        _error = error.toString();
        _loadingBoard = false;
      });
    }
  }

  /// The destination's short name for labels, or null when no destination
  /// is set. "Shivaji Stadium Terminal (Connaught Place)" becomes
  /// "Shivaji Stadium", so the board label stays one readable line.
  String? get _destinationShortName {
    final destination = _destination;
    if (destination == null) return null;
    return _shortLocationName(destination.stopName);
  }

  /// Opens the destination search, then rebuilds the board around the
  /// picked place.
  ///
  /// The server filters by a real place id, so a suggestion without one -
  /// the hardcoded "popular hub" shortcuts in the search page, for example
  /// - cannot be used here. Saying that plainly is better than setting a
  /// destination that would never be sent.
  Future<void> _pickDestination() async {
    final picked = await Navigator.of(context).push<PlaceSuggestion>(
      MaterialPageRoute(
        builder: (_) => const PlaceSearchPage(title: 'Your destination'),
      ),
    );
    if (picked == null || !mounted) return;

    if (picked.placeId == null || picked.placeId! <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a stop as your destination')),
      );
      return;
    }

    setState(() {
      _destination = picked;
      // Clear the old rows: they were filtered for a different question
      // ("every bus here"), and showing them under the new "to B" label
      // even for a moment would be dishonest.
      _board = null;
    });
    await _refreshBoard();
  }

  /// Removes the destination filter and goes back to the plain board of
  /// every bus arriving at this stop.
  void _clearDestination() {
    setState(() {
      _destination = null;
      _board = null;
    });
    _refreshBoard();
  }

  /// The stop the destination filter is aiming at, used when a route is
  /// opened from a board row.
  ///
  /// Passing it lets the route screen highlight the destination on its
  /// ribbon immediately, instead of asking the rider to pick a stop they
  /// have already picked. A frequency-only route has no bus row, so there
  /// is no target to pass.
  int? _routeTargetFor(RouteArrivalGroup group) {
    if (_destination == null) return null;
    if (group.arrivals.isEmpty) return null;
    return group.arrivals.first.targetStopSequence;
  }

  /// What to say when the board has no bus and no frequency rows at all.
  /// With a destination set, the copy is about that trip; without one it
  /// stays the old "no buses tracked" state.
  Widget _emptyBoardState() {
    final destination = _destinationShortName;
    if (destination == null) {
      return const EmptyState(
        icon: Icons.directions_bus_outlined,
        title: 'No buses tracked',
        body: 'Try another stop, or search the city.',
      );
    }
    return EmptyState(
      icon: Icons.directions_bus_outlined,
      title: 'No buses to $destination right now',
      body: 'No tracked bus and no observed frequency for this trip at this moment.',
    );
  }

  Future<void> _searchStop() async {
    final picked = await Navigator.of(context).push<PlaceSuggestion>(
      MaterialPageRoute(
        builder: (_) => const PlaceSearchPage(title: 'Find a stop'),
      ),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _selected = NearbyStop(
        placeId: picked.placeId ?? 0,
        name: picked.stopName,
        lat: picked.lat,
        lon: picked.lon,
        metresAway: 0,
      );
      _nearby = [_selected!];
      _locationDenied = false;
      _outsideDelhi = false;
      _error = null;
    });

    if (_selected!.placeId > 0) {
      await _refreshBoard();
    } else {
      await _loadNearby(LatLng(picked.lat, picked.lon));
    }
  }

  void _useDelhiDemo() => _useDemoHub(_demoHubs.first);

  void _useDemoHub(_DemoHub hub) {
    final location = LatLng(hub.lat, hub.lon);
    setState(() {
      _demo = true;
      _demoName = hub.name;
      _outsideDelhi = false;
      _locationDenied = false;
      _userLocation = location;
      _selected = null;
      _nearby = [];
      _board = null;
      _error = null;
    });
    _loadNearby(location);
  }

  void _chooseDemoLocation() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Choose a demo location'),
              for (final hub in _demoHubs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.location_on_outlined,
                    color: WimbColors.dtcRed,
                  ),
                  title: Text(hub.name),
                  subtitle: const Text('Simulated position'),
                  trailing: _demoName == hub.name
                      ? const Icon(Icons.check, color: WimbColors.delhiGreen)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _useDemoHub(hub);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectStop(NearbyStop stop) {
    setState(() {
      _selected = stop;
      _board = null;
    });
    _refreshBoard();
  }

  void _showArrival(BusArrival arrival) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  RouteBoard(routeName: arrival.routeNumber),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      arrival.destination,
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // With the destination filter on, the big number is the time
              // to that destination, not to this stop. Say which one, so the
              // sheet cannot be read the old way.
              if (_destinationShortName != null) ...[
                Row(
                  children: [
                    const Icon(Icons.flag, size: 14, color: WimbColors.dtcRed),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'To: ${_destinationShortName!}',
                        style: Theme.of(sheetContext).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              Text(
                arrival.isAtStop
                    ? 'At this stop'
                    : (arrival.rangeText ?? 'No estimate'),
                style: Theme.of(sheetContext).textTheme.displaySmall
                    ?.copyWith(fontSize: 30, color: WimbColors.ink),
              ),
              const SizedBox(height: 6),
              if (arrival.offsetM != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Route match: ${arrival.offsetM} m from the route line. '
                  '${arrival.isPassenger ? 'Reported by a passenger.' : 'Matched to the bus route.'}',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SearchScreen()));
  }

  void _openStop(NearbyStop stop) {
    if (stop.placeId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This stop has no detail in the feed.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StopScreen(
          placeId: stop.placeId,
          stopName: stop.name,
          at: _replayAt,
        ),
      ),
    );
  }

  Future<void> _openFollow(BusArrival arrival) async {
    // With the destination filter on, the server has already retargeted
    // this arrival at the rider's destination stop, so `target` is the B of
    // A→B. Passing it to RideScreen is what stops the ride screen asking
    // "Where are you getting off?" a second time. Without a filter, it is
    // the next stop, exactly as before.
    final target = arrival.targetStopSequence;
    if (target == null) {
      _showArrival(arrival);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Finding ${arrival.routeNumber}...'),
        duration: const Duration(milliseconds: 1200),
      ),
    );

    try {
      final detail = await fetchRouteDetail(
        routeId: arrival.routeId,
        at: _replayAt,
        toStopSequence: target,
      );
      if (!mounted) return;

      final run = detail.runs.where(
        (candidate) => candidate.vehicleId == arrival.vehicleId,
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RideScreen(
            detail: detail,
            run: run.isNotEmpty ? run.first : arrival,
            destinationSequence: target,
            enableMapTiles: widget.enableMapTiles,
            userLocation: _userLocation,
            simulatedLocation: _demo,
            locationLabel: _demo
                ? (_demoName ?? 'Demo location')
                : (_nearby.isNotEmpty
                      ? _shortLocationName(_nearby.first.name)
                      : 'You'),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _openRoute(
    String routeId,
    String routeNumber,
    String destination,
    int? target,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteScreen(
          routeId: routeId,
          routeNumber: routeNumber,
          destination: destination,
          targetStopSequence: target,
          at: _replayAt,
          enableMapTiles: widget.enableMapTiles,
          userLocation: _userLocation,
          simulatedLocation: _demo,
          locationLabel: _demo
              ? (_demoName ?? 'Demo location')
              : (_nearby.isNotEmpty
                    ? _shortLocationName(_nearby.first.name)
                    : 'You'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final board = _board;
    final selected = _selected;

    return Scaffold(
      backgroundColor: WimbColors.cream,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
          children: [
            Row(
              children: [
                const Expanded(child: WimbWordmark(color: WimbColors.ink)),
                _LocationPill(
                  label: _demo
                      ? (_demoName ?? 'Demo location')
                      : (_nearby.isNotEmpty
                            ? _shortLocationName(_nearby.first.name)
                            : 'Your location'),
                  demo: _demo || kIsWeb,
                  onTap: _chooseDemoLocation,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SearchBar(onTap: _openSearch),
            const SizedBox(height: 14),

            // Say up front what the board is showing. The recorder is
            // stopped, so the honest options are "a recorded moment,
            // labelled" or "observed frequency, labelled" - never a silent
            // pretend-live board.
            if (_replayAt != null) ...[
              _ReplayBanner(
                moment: _replayAt!,
                onUseFrequency: _useFrequencyInstead,
              ),
              const SizedBox(height: 12),
            ] else if (_feed != null &&
                !_feed!.live &&
                _feed!.replayDays.isNotEmpty) ...[
              _ReplayOffer(onReplay: _replayLastRecorded),
              const SizedBox(height: 12),
            ],

            if (_locating)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_outsideDelhi || _locationDenied)
              _OutsideState(
                demo: _demo,
                message: _error,
                onSearch: _searchStop,
                onDemo: _useDelhiDemo,
              )
            else if (selected == null)
              _NoStopState(onSearch: _searchStop)
            else ...[
              if (_showMap) ...[
                TransitMap(
                  height: 210,
                  center: LatLng(selected.lat, selected.lon),
                  userLocation: _userLocation,
                  locationLabel: _demo
                      ? (_demoName ?? 'Demo location')
                      : (_nearby.isNotEmpty
                            ? _shortLocationName(_nearby.first.name)
                            : 'Your location'),
                  simulatedLocation: _demo,
                  onLocationTap: _chooseDemoLocation,
                  nearbyStops: _nearby.take(6).toList(),
                  selectedStop: selected,
                  buses: [
                    for (final arrival
                        in (board?.arrivals ?? const <BusArrival>[]).take(8))
                      if (arrival.snappedLat != null &&
                          arrival.snappedLon != null)
                        MapBus(
                          point: LatLng(
                            arrival.snappedLat!,
                            arrival.snappedLon!,
                          ),
                          routeNumber: arrival.routeNumber,
                          source: arrival.source,
                          onTap: () => _openFollow(arrival),
                        ),
                  ],
                  enableTiles: widget.enableMapTiles,
                  onStopTap: _selectStop,
                ),
                const SizedBox(height: 12),
              ],
              _StopCard(
                stop: selected,
                onPick: () => _showStopPicker(context),
                onOpen: () => _openStop(selected),
              ),
              const SizedBox(height: 10),
              // The headline fix: the rows below are buses arriving at this
              // stop, not buses going where the rider is going. This control
              // is what makes the board answer "from here to B".
              _DestinationControl(
                destinationName: _destinationShortName,
                onPick: _pickDestination,
                onClear: _clearDestination,
              ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _showMap = !_showMap),
                  icon: Icon(
                    _showMap ? Icons.map_outlined : Icons.map,
                    size: 16,
                  ),
                  label: Text(_showMap ? 'Hide map' : 'Show map'),
                  style: TextButton.styleFrom(
                    foregroundColor: WimbColors.inkMuted,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // The label says exactly what the list below means. Without a
              // destination that is "arriving at this stop, whichever way
              // it is heading" - the misunderstanding this round fixes.
              SectionLabel(
                _destinationShortName == null
                    ? 'Buses arriving at this stop'
                    : 'Buses from here to ${_destinationShortName!}',
              ),
              if (_destinationShortName == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Every route that stops here, whichever way it is heading. '
                    'Tap a bus to track it on the map.',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.3,
                      color: WimbColors.inkMuted,
                    ),
                  ),
                )
              else
                // A row still shows the bus's own terminus after its route
                // number. Say once, plainly, that the time on the right is
                // the time to YOUR destination - the two names are different
                // things and that is exactly what confused the first user.
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Times are to ${_destinationShortName!}. The name after a '
                    "route number is where that bus itself terminates.",
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.3,
                      color: WimbColors.inkMuted,
                    ),
                  ),
                ),
              if (_loadingBoard && board == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                ErrorCard(message: _error!, onRetry: _refreshBoard)
              else if (board != null) ...[
                if (_destination != null && board.noDirect)
                  // The honest answer when no single bus runs to B: say so,
                  // and point at a planned trip with one change. No rows are
                  // invented for a trip that does not exist.
                  _NoDirectCard(
                    destinationName:
                        _destinationShortName ?? 'your destination',
                    onPlan: widget.onOpenPlan,
                    onClear: _clearDestination,
                  )
                else ...[
                  if (board.arrivals.isNotEmpty) ...[
                    FilledButton.icon(
                      onPressed: () => _openFollow(board.arrivals.first),
                      icon: const Icon(Icons.near_me, size: 18),
                      label: Text(
                        _destinationShortName == null
                            ? 'Track the next bus'
                            : 'Track the next bus to ${_destinationShortName!}',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  for (final group in groupArrivals(board))
                    RouteBoardRow(
                      group: group,
                      // Tapping a row starts tracking the next bus on it - the
                      // ride/tracking screen is the main feature. A route with
                      // no tracked bus still opens its route page.
                      onRouteTap: group.arrivals.isEmpty
                          ? () => _openRoute(
                              group.routeId,
                              group.routeNumber,
                              group.destination,
                              _routeTargetFor(group),
                            )
                          : () => _openFollow(group.arrivals.first),
                      onArrivalTap: _openFollow,
                    ),
                  if (board.arrivals.isEmpty && board.frequency.isEmpty)
                    _emptyBoardState(),
                ],
              ],
              OutlinedButton.icon(
                onPressed: widget.onOpenPlan,
                icon: const Icon(Icons.alt_route, size: 18),
                label: const Text('Plan a trip'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: WimbColors.ink,
                  backgroundColor: WimbColors.cardCream,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showStopPicker(BuildContext context) {
    if (_nearby.isEmpty) {
      _searchStop();
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Nearby stops'),
              for (final stop in _nearby)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.place_outlined,
                    color: WimbColors.dtcRed,
                  ),
                  title: Text(stop.name),
                  subtitle: Text('${stop.metresAway} m away'),
                  trailing: stop.placeId == _selected?.placeId
                      ? const Icon(Icons.check, color: WimbColors.delhiGreen)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _selectStop(stop);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationPill extends StatelessWidget {
  final String label;
  final bool demo;
  final VoidCallback onTap;

  const _LocationPill({
    required this.label,
    required this.demo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WimbColors.cardCream,
      borderRadius: BorderRadius.circular(WimbRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 158),
          padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WimbRadius.pill),
            border: Border.all(color: WimbColors.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on, size: 12, color: WimbColors.dtcRed),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: WimbColors.ink,
                  ),
                ),
              ),
              if (demo) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: WimbColors.statusEstimated.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(WimbRadius.pill),
                  ),
                  child: const Text(
                    'DEMO',
                    style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: WimbColors.statusEstimated,
                    ),
                  ),
                ),
              ],
              const Icon(
                Icons.expand_more,
                size: 13,
                color: WimbColors.inkFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WimbColors.cardCream,
      borderRadius: BorderRadius.circular(WimbRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WimbRadius.pill),
            border: Border.all(color: WimbColors.hairline),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 20, color: WimbColors.ink),
              const SizedBox(width: 10),
              Text(
                'Search route, stop or place',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: WimbColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopCard extends StatelessWidget {
  final NearbyStop stop;
  final VoidCallback onPick;
  final VoidCallback onOpen;

  const _StopCard({
    required this.stop,
    required this.onPick,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final walkMinutes = (stop.metresAway / 83).ceil();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onOpen,
                borderRadius: BorderRadius.circular(WimbRadius.field),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        stop.metresAway == 0
                            ? 'Selected stop'
                            : '${stop.metresAway} m · $walkMinutes min walk',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onPick,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutsideState extends StatelessWidget {
  final bool demo;
  final String? message;
  final VoidCallback onSearch;
  final VoidCallback onDemo;

  const _OutsideState({
    required this.demo,
    required this.message,
    required this.onSearch,
    required this.onDemo,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.location_off_outlined,
              size: 30,
              color: WimbColors.dtcRed,
            ),
            const SizedBox(height: 12),
            Text(
              demo ? 'Delhi demo' : 'Outside Delhi NCR',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              demo
                  ? 'You are browsing Connaught Place as a demo location.'
                  : (message ??
                        'This app only has Delhi data. Choose a stop, or explore Delhi as a demo.'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onDemo,
              child: const Text('Explore Delhi demo'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: onSearch,
              style: OutlinedButton.styleFrom(
                foregroundColor: WimbColors.ink,
                backgroundColor: WimbColors.cardCream,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Search a stop'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoStopState extends StatelessWidget {
  final VoidCallback onSearch;
  const _NoStopState({required this.onSearch});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.search, size: 30, color: WimbColors.inkMuted),
            const SizedBox(height: 12),
            Text(
              'No stops nearby',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Search for a stop to see what is coming.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onSearch,
              child: const Text('Search a stop'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "this board is a recorded moment, not live" banner.
///
/// It exists because the recorder is stopped: without it, a board full of
/// buses would look live, which is the exact dishonesty this project exists
/// to avoid. The blue is the same historical-data colour the rest of the app
/// uses for recorded sources.
class _ReplayBanner extends StatelessWidget {
  final DateTime moment;
  final VoidCallback onUseFrequency;

  const _ReplayBanner({required this.moment, required this.onUseFrequency});

  @override
  Widget build(BuildContext context) {
    final local = moment.toLocal();
    final when = DateFormat('d MMM yyyy, h:mm a').format(local);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: WimbColors.statusHistorical.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(WimbRadius.field),
        border: Border.all(
          color: WimbColors.statusHistorical.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.history,
            size: 16,
            color: WimbColors.statusHistorical,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Recorded buses · $when · not live',
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: WimbColors.statusHistorical,
              ),
            ),
          ),
          TextButton(
            onPressed: onUseFrequency,
            style: TextButton.styleFrom(
              foregroundColor: WimbColors.statusHistorical,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Frequency',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// The offer to go back to the recorded moment after "Frequency" was chosen.
class _ReplayOffer extends StatelessWidget {
  final VoidCallback onReplay;

  const _ReplayOffer({required this.onReplay});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: WimbColors.surfaceMuted,
        borderRadius: BorderRadius.circular(WimbRadius.field),
        border: Border.all(color: WimbColors.hairline),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, size: 16, color: WimbColors.inkMuted),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'No live feed. Replay the last recorded buses?',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: WimbColors.inkMuted,
              ),
            ),
          ),
          TextButton(
            onPressed: onReplay,
            style: TextButton.styleFrom(
              foregroundColor: WimbColors.ink,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Replay',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Where to? (optional)" control under the stop card.
///
/// The board's rows are buses arriving at this stop, whichever direction
/// they continue in - the place name after a route number is the bus's own
/// last stop, not the rider's. This control is what turns the board into
/// "buses from here to B". Unpicked, it stays an optional button rather than
/// a form field, because the board must work without it.
class _DestinationControl extends StatelessWidget {
  /// Short name of the picked destination, or null when none is picked.
  final String? destinationName;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _DestinationControl({
    required this.destinationName,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (destinationName == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.flag_outlined, size: 18),
          label: const Text('Where to? (optional)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: WimbColors.ink,
            backgroundColor: WimbColors.cardCream,
            minimumSize: const Size(0, 42),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      );
    }

    // Picked: one compact row. Tapping the row changes the destination;
    // the X clears it and goes back to the unfiltered board.
    return Material(
      color: WimbColors.cardCream,
      borderRadius: BorderRadius.circular(WimbRadius.pill),
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WimbRadius.pill),
            border: Border.all(color: WimbColors.hairline),
          ),
          child: Row(
            children: [
              const Icon(Icons.flag, size: 15, color: WimbColors.dtcRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'To: $destinationName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WimbColors.ink,
                  ),
                ),
              ),
              IconButton(
                onPressed: onClear,
                tooltip: 'Clear destination',
                icon: const Icon(Icons.close, size: 17),
                color: WimbColors.inkMuted,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The honest card for "no single bus runs from here to your destination".
///
/// It exists so the board never fills the space with buses heading somewhere
/// else: the answer is "not directly", the next step is a planned trip with
/// one change, and the rider can clear the filter from here.
class _NoDirectCard extends StatelessWidget {
  final String destinationName;
  final VoidCallback? onPlan;
  final VoidCallback onClear;

  const _NoDirectCard({
    required this.destinationName,
    required this.onPlan,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.alt_route,
                  size: 20,
                  color: WimbColors.inkMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No direct bus from here to $destinationName.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The Plan tab can look for a trip with one change.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onPlan,
              icon: const Icon(Icons.alt_route, size: 18),
              label: const Text('Plan a trip with one change'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onClear,
                child: const Text('Clear destination'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
