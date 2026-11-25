import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'api_client.dart';
import 'arrival_widgets.dart';
import 'favorites_store.dart';
import 'journey_screen.dart';
import 'ride_screen.dart';
import 'route_screen.dart';
import 'theme.dart';

/// Every route that calls at one physical stop, in one place.
class StopScreen extends ConsumerStatefulWidget {
  final int placeId;
  final String stopName;

  /// A recorded moment to replay, or null to ask for live buses. Passed down
  /// from the board so a replay stays a replay when a stop is opened.
  final DateTime? at;

  const StopScreen({
    super.key,
    required this.placeId,
    required this.stopName,
    this.at,
  });

  @override
  ConsumerState<StopScreen> createState() => _StopScreenState();
}

class _StopScreenState extends ConsumerState<StopScreen> {
  StopArrivals? _board;
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      // A recorded moment never changes.
      if (!_loading && widget.at == null) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final board = await fetchStopArrivals(
        placeId: widget.placeId,
        at: widget.at,
      );
      if (!mounted) return;
      setState(() {
        _board = board;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _openRoute(RouteArrivalGroup group) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteScreen(
          routeId: group.routeId,
          routeNumber: group.routeNumber,
          destination: group.destination,
          at: widget.at,
        ),
      ),
    );
  }

  Future<void> _openRide(BusArrival arrival) async {
    final target = arrival.targetStopSequence;
    if (target == null) {
      _openRoute(
        RouteArrivalGroup(
          routeId: arrival.routeId,
          routeNumber: arrival.routeNumber,
          destination: arrival.destination,
          arrivals: [arrival],
        ),
      );
      return;
    }

    try {
      final detail = await fetchRouteDetail(
        routeId: arrival.routeId,
        at: widget.at,
        toStopSequence: target,
      );
      if (!mounted) return;
      final runs = detail.runs.where((r) => r.vehicleId == arrival.vehicleId);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RideScreen(
            detail: detail,
            run: runs.isNotEmpty ? runs.first : arrival,
            destinationSequence: target,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _planFromHere() {
    final board = _board;
    if (board == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JourneyScreen(
          initialFrom: PlaceSuggestion(
            stopName: board.placeName,
            lat: board.lat,
            lon: board.lon,
            placeId: board.placeId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(favoritesProvider).hasStop(widget.placeId);
    final board = _board;
    final groups = board == null
        ? const <RouteArrivalGroup>[]
        : groupArrivals(board);

    // Which recorded moment this screen is showing, if any. Either it was
    // opened from the board's replay with a moment, or the server itself
    // answered in replay mode - both mean "not live".
    DateTime? replayMoment = widget.at;
    if (replayMoment == null && board != null && board.isReplay) {
      replayMoment = board.at;
    }

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(
        title: Text(
          widget.stopName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: saved ? 'Remove saved stop' : 'Save stop',
            onPressed: () {
              ref
                  .read(favoritesProvider.notifier)
                  .toggleStop(
                    SavedStop(placeId: widget.placeId, name: widget.stopName),
                  );
            },
            icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
          ),
          IconButton(
            tooltip: 'Plan from here',
            onPressed: board == null ? null : _planFromHere,
            icon: const Icon(Icons.alt_route),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            // The same "recorded, not live" line the board shows, so a stop
            // opened from a replayed board does not quietly look live.
            if (replayMoment != null) ...[
              InfoBanner(
                icon: Icons.history,
                color: WimbColors.statusHistorical,
                text:
                    'Recorded buses · ${DateFormat('d MMM, h:mm a').format(replayMoment.toLocal())} · not live',
              ),
              const SizedBox(height: 12),
            ],
            if (_loading && board == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && board == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              )
            else if (board != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.place, color: WimbColors.dtcRed),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              board.placeName,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              board.isReplay
                                  ? '${groups.length} ${groups.length == 1 ? 'route' : 'routes'} · recorded buses'
                                  : '${groups.length} ${groups.length == 1 ? 'route' : 'routes'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // In a replay, say in the label itself that these are recorded
              // buses; the live screen keeps its route-list wording.
              SectionLabel(
                replayMoment == null
                    ? 'Routes at this stop'
                    : 'Buses arriving at this stop (recorded)',
              ),
              if (groups.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('No routes are listed for this stop.'),
                  ),
                )
              else
                for (final group in groups)
                  RouteBoardRow(
                    group: group,
                    onRouteTap: () => _openRoute(group),
                    onArrivalTap: _openRide,
                  ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _planFromHere,
                icon: const Icon(Icons.alt_route, size: 18),
                label: const Text('Plan from this stop'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: WimbColors.cardCream,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
