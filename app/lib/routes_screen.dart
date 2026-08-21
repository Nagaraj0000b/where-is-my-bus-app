// Browse routes by number and see their stop sequence.
//
// CLAUDE.md priority #5 ("route and schedule information"). This is the
// honest complement to the journey planner: journey_screen.dart answers
// "how do I get from A to B", this answers "where does bus 764 actually
// go" - useful on its own, and it's also how someone would find their own
// stop's position number for /eta, once that's wired into the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'error_card.dart';

/// Fetches the stop list for whatever route is currently open. `.family`
/// keys the cache by routeId; `.autoDispose` drops it once the detail
/// screen is closed, same reasoning as journey_screen.dart's provider.
final routeStopsProvider = FutureProvider.autoDispose
    .family<List<RouteStop>, String>((ref, routeId) => fetchRouteStops(routeId));

class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<RouteSuggestion> _results = [];
  bool _searching = false;
  // Distinguishes "haven't searched yet" from "searched, found nothing" -
  // the two need different empty-state messages.
  bool _hasSearched = false;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _searching = true);
      final results = await searchRoutes(text);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _hasSearched = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Route number, e.g. 764',
                border: const OutlineInputBorder(),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              onChanged: _onChanged,
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_hasSearched) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Type a route number to see where it goes and every stop '
            'along the way.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('No route matches that number.'));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final route = _results[i];
        return ListTile(
          title: Text(
            route.routeShortName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: route.routeDesc.isEmpty ? null : Text(route.routeDesc),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RouteStopsScreen(route: route)),
          ),
        );
      },
    );
  }
}

/// Which two stops on a route an ETA is being asked about - "from" is where
/// the bus is assumed to be right now, "to" is where the rider is waiting.
/// Both are stop_sequence positions, not stop_ids (see [fetchEta]).
class _EtaQuery {
  final String routeId;
  final int from;
  final int to;

  const _EtaQuery({required this.routeId, required this.from, required this.to});

  @override
  bool operator ==(Object other) =>
      other is _EtaQuery &&
      other.routeId == routeId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(routeId, from, to);
}

final _etaResultProvider =
    FutureProvider.autoDispose.family<EtaResult, _EtaQuery>((ref, query) {
  return fetchEta(routeId: query.routeId, from: query.from, to: query.to);
});

/// The ordered stop list for one route, once someone taps it from search.
/// Also where CLAUDE.md priority #1 ("buses arriving at this stop, with
/// ETA") actually happens: tap the stop the bus is at, then the stop
/// you're waiting at, and /eta answers with a range, never a bare number.
class RouteStopsScreen extends ConsumerStatefulWidget {
  final RouteSuggestion route;
  const RouteStopsScreen({super.key, required this.route});

  @override
  ConsumerState<RouteStopsScreen> createState() => _RouteStopsScreenState();
}

class _RouteStopsScreenState extends ConsumerState<RouteStopsScreen> {
  // Both null: nothing picked yet. Only _fromSeq set: waiting for the
  // second tap. Both set: an ETA is being shown for this pair.
  int? _fromSeq;
  int? _toSeq;

  void _handleTap(RouteStop stop) {
    setState(() {
      if (_fromSeq == null) {
        _fromSeq = stop.stopSequence;
      } else if (_toSeq == null) {
        if (stop.stopSequence == _fromSeq) {
          // Tapped the same stop again - treat it as "never mind".
          _fromSeq = null;
        } else if (stop.stopSequence < _fromSeq!) {
          // A bus only moves forward along its route, so if the second
          // tap is earlier than the first, the rider picked them
          // backwards - swap rather than send /eta a pair it will refuse.
          _toSeq = _fromSeq;
          _fromSeq = stop.stopSequence;
        } else {
          _toSeq = stop.stopSequence;
        }
      } else {
        // Both already picked - a fresh tap starts a new estimate.
        _fromSeq = stop.stopSequence;
        _toSeq = null;
      }
    });
  }

  void _clear() => setState(() {
        _fromSeq = null;
        _toSeq = null;
      });

  String get _instruction {
    if (_fromSeq == null) return 'Tap the stop the bus is at right now.';
    if (_toSeq == null) return "Now tap the stop where you're waiting.";
    return 'Tap any stop to start a new estimate.';
  }

  @override
  Widget build(BuildContext context) {
    final stops = ref.watch(routeStopsProvider(widget.route.routeId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.route.routeShortName),
        actions: [
          if (_fromSeq != null)
            IconButton(
              onPressed: _clear,
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.route.routeDesc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                widget.route.routeDesc,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(_instruction, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (_fromSeq != null && _toSeq != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _EtaCard(
                query: _EtaQuery(
                  routeId: widget.route.routeId,
                  from: _fromSeq!,
                  to: _toSeq!,
                ),
              ),
            ),
          Expanded(
            child: stops.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              // A route the search just returned failing to load its stops
              // is a real request failure (server unreachable, or it fell
              // out of the feed snapshot between search and tap) - unlike
              // an honest "no route found", trying again can genuinely
              // help, so it's always offered here.
              error: (err, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorCard(
                  message: err.toString(),
                  onRetry: () => ref.invalidate(routeStopsProvider(widget.route.routeId)),
                ),
              ),
              data: (stopList) => ListView.separated(
                itemCount: stopList.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final stop = stopList[i];
                  final isFrom = stop.stopSequence == _fromSeq;
                  final isTo = stop.stopSequence == _toSeq;
                  return ListTile(
                    onTap: () => _handleTap(stop),
                    tileColor: isFrom
                        ? Colors.green.shade50
                        : isTo
                            ? Colors.blue.shade50
                            : null,
                    leading: CircleAvatar(
                      radius: 12,
                      backgroundColor: isFrom
                          ? Colors.green
                          : isTo
                              ? Colors.blue
                              : null,
                      child: isFrom
                          ? const Icon(Icons.directions_bus, size: 13, color: Colors.white)
                          : isTo
                              ? const Icon(Icons.person_pin_circle, size: 13, color: Colors.white)
                              : Text(
                                  '${stop.stopSequence}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                    ),
                    title: Text(stop.stopName),
                    subtitle: isFrom
                        ? const Text('Bus is here')
                        : isTo
                            ? const Text("You're here")
                            : null,
                    trailing: Text(
                      '${(stop.metresAlongRoute / 1000).toStringAsFixed(1)} km',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ETA answer for one (from, to) pair - a range and a confidence label,
/// never a bare number, same honesty rule as journey_screen.dart.
class _EtaCard extends ConsumerWidget {
  final _EtaQuery query;
  const _EtaCard({required this.query});

  // Same three-colour scale as by_hour_screen.dart's _HourRow - kept as a
  // small local copy rather than a shared helper, since each screen colours
  // a different shaped widget with it and the switch is only six lines.
  Color? _confidenceColor(String level) {
    switch (level) {
      case 'high':
        return Colors.green;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.red;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_etaResultProvider(query));

    return result.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(_etaResultProvider(query)),
      ),
      data: (eta) {
        if (!eta.available) {
          // Honest refusal (e.g. these two legs have never been observed
          // together), not a request failure - no retry button, same
          // pattern as the "no route found" branches elsewhere in the app.
          return ErrorCard(
            message: eta.unavailableReason ?? 'No estimate available for this pair of stops.',
          );
        }
        return Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: _confidenceColor(eta.confidence.level)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        eta.range.text,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${eta.stopsAway} stop${eta.stopsAway == 1 ? '' : 's'} away',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(eta.confidence.because, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                ...eta.caveats.map(
                  (c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('• $c', style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
