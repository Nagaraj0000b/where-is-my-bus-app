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
import 'theme.dart';

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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _controller,
              // hintText, NOT labelText. A floating label on a filled box
              // rises out of the field and sits above it in accent red,
              // which is what made this look broken in the screenshot. A
              // hint simply disappears as you type, which is what a search
              // bar should do.
              decoration: InputDecoration(
                hintText: 'Route number, e.g. 764',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                prefixIcon: const Icon(Icons.search, color: WimbColors.inkMuted, size: 20),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(13),
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
      return _placeholder(
        icon: Icons.directions_bus_filled,
        title: 'Find a route',
        detail: 'Type a route number to see where it goes, every stop along '
            'the way, and how long between any two of them.',
      );
    }
    if (_results.isEmpty) {
      return _placeholder(
        icon: Icons.search_off,
        title: 'No route matches that number',
        detail: 'Delhi route numbers often carry a letter, like 764B or '
            '764STL. Try just the digits.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, i) {
        final route = _results[i];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => RouteStopsScreen(route: route)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(13, 11, 8, 11),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The board sits on its OWN line rather than beside
                        // the description. Side by side it was squeezed into
                        // about a third of the width and every route came
                        // out truncated - "TILAK NA...", "0118EXT(N..." -
                        // which defeats the point of showing the number.
                        // Align keeps it hugging its own text rather than
                        // stretching across the card.
                        Align(
                          alignment: Alignment.centerLeft,
                          child: RouteBoard(routeName: route.routeShortName),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          route.routeDesc.isEmpty
                              ? 'Route ${route.routeShortName}'
                              : route.routeDesc,
                          // Delhi's route descriptions run long. Two lines
                          // is enough to tell two routes apart; five made
                          // only five results fit on the whole screen.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20, color: WimbColors.inkMuted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder({
    required IconData icon,
    required String title,
    required String detail,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 34),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: WimbColors.hairline),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
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
        title: Text(widget.route.routeShortName.toUpperCase()),
        actions: [
          if (_fromSeq != null)
            IconButton(
              onPressed: _clear,
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
            ),
        ],
      ),
      // ONE scroll for the whole page.
      //
      // This used to be a Column with the board, the prompt and the
      // estimate pinned at the top and only the stop list scrolling
      // underneath them. On a long route that left very little of the
      // screen actually moving, and once an estimate appeared it ate a
      // third of the display and would not go away. As slivers, everything
      // scrolls together - the estimate scrolls off as you move down the
      // stops, and comes back when you scroll up.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The route's own destination board, on the cream
                // background rather than on a slab of red - a full-width
                // red bar under every app bar was what made these screens
                // feel like a web page.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: RouteBoard(
                      routeName: widget.route.routeShortName,
                      destination: widget.route.routeDesc,
                    ),
                  ),
                ),

                // The tap-two-stops prompt, as a soft pill rather than a
                // full-bleed coloured strip.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    decoration: BoxDecoration(
                      color: WimbColors.delhiGreenLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _fromSeq == null ? Icons.touch_app : Icons.timer_outlined,
                          size: 16,
                          color: WimbColors.delhiGreen,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            _instruction,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: WimbColors.delhiGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_fromSeq != null && _toSeq != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                    child: _EtaCard(
                      query: _EtaQuery(
                        routeId: widget.route.routeId,
                        from: _fromSeq!,
                        to: _toSeq!,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          stops.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            // A route the search just returned failing to load its stops
            // is a real request failure (server unreachable, or it fell
            // out of the feed snapshot between search and tap) - unlike
            // an honest "no route found", trying again can genuinely
            // help, so it's always offered here.
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorCard(
                  message: err.toString(),
                  onRetry: () => ref.invalidate(routeStopsProvider(widget.route.routeId)),
                ),
              ),
            ),
            data: (stopList) => SliverList.builder(
              itemCount: stopList.length,
              itemBuilder: (context, i) => _StopRow(
                stop: stopList[i],
                isFirst: i == 0,
                isLast: i == stopList.length - 1,
                isFrom: stopList[i].stopSequence == _fromSeq,
                isTo: stopList[i].stopSequence == _toSeq,
                // Between the two picked stops - the stretch the
                // estimate actually covers, shown so the answer and the
                // list agree with each other visually.
                isBetween: _fromSeq != null &&
                    _toSeq != null &&
                    stopList[i].stopSequence > _fromSeq! &&
                    stopList[i].stopSequence < _toSeq!,
                onTap: () => _handleTap(stopList[i]),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }
}

/// One stop, drawn as a station on a route line.
///
/// The vertical line with a dot on it is the standard way transit maps
/// show a sequence of stops, and it makes the order obvious in a way a
/// plain list of names does not - particularly once two stops are picked
/// and the stretch between them is highlighted.
class _StopRow extends StatelessWidget {
  final RouteStop stop;
  final bool isFirst;
  final bool isLast;
  final bool isFrom;
  final bool isTo;
  final bool isBetween;
  final VoidCallback onTap;

  const _StopRow({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.isFrom,
    required this.isTo,
    required this.isBetween,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlighted = isFrom || isTo;
    // The line is drawn thicker and in full colour along the stretch the
    // estimate covers, and faint everywhere else.
    final onEstimatedStretch = isFrom || isTo || isBetween;
    final lineColor = onEstimatedStretch ? WimbColors.dtcRed : WimbColors.hairline;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? WimbColors.delhiGreenLight.withValues(alpha: 0.6) : null,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The route line and this stop's dot on it.
              SizedBox(
                width: 26,
                child: Column(
                  children: [
                    // No line above the first stop or below the last -
                    // the route starts and ends, it does not run off the
                    // top and bottom of the screen.
                    Expanded(
                      child: Container(
                        width: onEstimatedStretch ? 3 : 2,
                        color: isFirst ? Colors.transparent : lineColor,
                      ),
                    ),
                    _dot(),
                    Expanded(
                      child: Container(
                        width: onEstimatedStretch ? 3 : 2,
                        color: isLast ? Colors.transparent : lineColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stopName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: highlighted ? FontWeight.w700 : FontWeight.w400,
                          // Dimmed when no bus was ever recorded arriving
                          // here, so the gap is visible before it becomes
                          // a refusal.
                          color: stop.hasTiming
                              ? WimbColors.ink
                              : WimbColors.inkMuted.withValues(alpha: 0.75),
                        ),
                      ),
                      if (isFrom || isTo)
                        Text(
                          isFrom ? 'Bus is here' : "You're waiting here",
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: WimbColors.delhiGreen,
                          ),
                        )
                      else if (!stop.hasTiming)
                        Text(
                          'no recorded timing',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontStyle: FontStyle.italic,
                            color: WimbColors.inkMuted.withValues(alpha: 0.7),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Text(
                  '${(stop.metresAlongRoute / 1000).toStringAsFixed(1)} km',
                  style: const TextStyle(
                    fontFeatures: WimbFonts.tabular,
                    fontSize: 12,
                    color: WimbColors.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The dot on the line: a bus icon where the bus is, a person where the
  /// rider is, and a plain numbered circle everywhere else.
  Widget _dot() {
    if (isFrom || isTo) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isFrom ? WimbColors.delhiGreen : WimbColors.dtcRed,
          border: Border.all(color: WimbColors.cream, width: 2.5),
        ),
        child: Icon(
          isFrom ? Icons.directions_bus : Icons.person_pin_circle,
          size: 13,
          color: Colors.white,
        ),
      );
    }
    return Container(
      width: 17,
      height: 17,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: WimbColors.cream,
        border: Border.all(
          color: isBetween ? WimbColors.dtcRed : WimbColors.hairline,
          width: 2,
        ),
      ),
      child: Text(
        '${stop.stopSequence}',
        style: const TextStyle(fontSize: 8, color: WimbColors.inkMuted, height: 1),
      ),
    );
  }
}

/// The ETA answer for one (from, to) pair - a range and a confidence label,
/// never a bare number, same honesty rule as journey_screen.dart.
class _EtaCard extends ConsumerWidget {
  final _EtaQuery query;
  const _EtaCard({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_etaResultProvider(query));

    return result.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 26),
          child: Center(child: CircularProgressIndicator()),
        ),
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
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionLabel('Journey time'),
                          // The range, big. Deliberately the range and not
                          // the single estimate - showing one number here
                          // would be exactly the dishonesty this project
                          // exists to correct.
                          Text(
                            eta.range.text,
                            style: const TextStyle(
                              fontFamily: WimbFonts.condensed,
                              fontFamilyFallback: WimbFonts.fallback,
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              height: 1.05,
                              color: WimbColors.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${eta.stopsAway} stop${eta.stopsAway == 1 ? '' : 's'} along the route',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.directions_bus_filled, size: 30, color: WimbColors.hairline),
                  ],
                ),
                const SizedBox(height: 13),
                TrustDots(level: eta.confidence.level),
                const SizedBox(height: 5),
                Text(eta.confidence.because, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 10),
                ...eta.caveats.map((c) => CaveatLine(c)),
              ],
            ),
          ),
        );
      },
    );
  }
}
