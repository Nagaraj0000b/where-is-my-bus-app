// The small pieces the board is made of.
//
// A route is one card. The card carries the next two buses, the stops away,
// and a factual status line. No confidence words, no dots.

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'theme.dart';

/// All the arrivals for one route, sorted by ETA.
class RouteArrivalGroup {
  final String routeId;
  final String routeNumber;
  final String destination;
  final List<BusArrival> arrivals;
  final BusFrequency? frequency;

  const RouteArrivalGroup({
    required this.routeId,
    required this.routeNumber,
    required this.destination,
    required this.arrivals,
    this.frequency,
  });

  bool get isFrequencyOnly => arrivals.isEmpty && frequency != null;

  int get sortSeconds =>
      arrivals.isEmpty ? 24 * 3600 : (arrivals.first.etaSeconds ?? 24 * 3600);
}

/// Groups the API's flat arrival list into one row per route, and appends
/// routes that only have an observed frequency.
List<RouteArrivalGroup> groupArrivals(StopArrivals board) {
  final byRoute = <String, List<BusArrival>>{};
  for (final arrival in board.arrivals) {
    byRoute.putIfAbsent(arrival.routeId, () => []).add(arrival);
  }

  final frequencyByRoute = <String, BusFrequency>{
    for (final frequency in board.frequency) frequency.routeId: frequency,
  };

  final groups = <RouteArrivalGroup>[];
  for (final entry in byRoute.entries) {
    final runs = entry.value
      ..sort(
        (a, b) => (a.etaSeconds ?? 1 << 30).compareTo(b.etaSeconds ?? 1 << 30),
      );
    final first = runs.first;
    groups.add(
      RouteArrivalGroup(
        routeId: first.routeId,
        routeNumber: first.routeNumber,
        destination: first.destination,
        arrivals: runs,
        frequency: frequencyByRoute[first.routeId],
      ),
    );
  }

  for (final frequency in board.frequency) {
    if (byRoute.containsKey(frequency.routeId)) continue;
    groups.add(
      RouteArrivalGroup(
        routeId: frequency.routeId,
        routeNumber: frequency.routeNumber,
        destination: frequency.destination,
        arrivals: const [],
        frequency: frequency,
      ),
    );
  }

  groups.sort((a, b) => a.sortSeconds.compareTo(b.sortSeconds));
  return groups;
}

/// The arrival window, always a range when one exists.
class ArrivalEtaRange extends StatelessWidget {
  final BusArrival arrival;
  final bool large;

  const ArrivalEtaRange({super.key, required this.arrival, this.large = false});

  @override
  Widget build(BuildContext context) {
    final text = arrival.isAtStop
        ? 'At stop'
        : (arrival.rangeText ?? arrival.etaText ?? 'No estimate');

    return Text(
      text,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: large ? 30 : 22,
        height: 1,
        fontWeight: FontWeight.w700,
        color: arrival.isAtStop ? WimbColors.inkMuted : WimbColors.ink,
        fontFeatures: WimbFonts.tabular,
      ),
    );
  }
}

/// A single arrival's source + age, in the new factual vocabulary.
/// One route on the board: the next two buses, or the observed frequency.
class RouteBoardRow extends StatelessWidget {
  final RouteArrivalGroup group;
  final VoidCallback? onRouteTap;
  final ValueChanged<BusArrival>? onArrivalTap;

  const RouteBoardRow({
    super.key,
    required this.group,
    this.onRouteTap,
    this.onArrivalTap,
  });

  @override
  Widget build(BuildContext context) {
    final first = group.arrivals.isNotEmpty ? group.arrivals.first : null;
    final second = group.arrivals.length > 1 ? group.arrivals[1] : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: InkWell(
        onTap: onRouteTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              RouteBoard(routeName: group.routeNumber, compact: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      group.destination,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (first == null)
                      Text(
                        'About every ${group.frequency!.headwayMinutes.round()} min',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: WimbColors.inkMuted,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 3,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (first.stopsAway != null && first.stopsAway! > 0)
                            Text(
                              '${first.stopsAway} ${first.stopsAway == 1 ? 'stop' : 'stops'} away',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: WimbColors.inkMuted,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (first != null)
                    InkWell(
                      onTap: onArrivalTap == null
                          ? null
                          : () => onArrivalTap!(first),
                      borderRadius: BorderRadius.circular(WimbRadius.field),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 2,
                          horizontal: 2,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 86),
                          child: ArrivalEtaRange(arrival: first),
                        ),
                      ),
                    )
                  else
                    const Text(
                      '—',
                      style: TextStyle(
                        fontFamily: WimbFonts.condensed,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: WimbColors.inkFaint,
                      ),
                    ),
                  if (second != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      second.rangeText ?? second.etaText ?? '—',
                      style: const TextStyle(
                        fontFamily: WimbFonts.condensed,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.inkMuted,
                        fontFeatures: WimbFonts.tabular,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bus on a route, used inside the line screen.
class ArrivalRow extends StatelessWidget {
  final BusArrival arrival;
  final VoidCallback? onTap;
  final VoidCallback? onRouteTap;

  const ArrivalRow({
    super.key,
    required this.arrival,
    this.onTap,
    this.onRouteTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          child: Row(
            children: [
              if (onRouteTap != null)
                InkWell(
                  onTap: onRouteTap,
                  borderRadius: BorderRadius.circular(WimbRadius.field),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: RouteBoard(
                      routeName: arrival.routeNumber,
                      compact: true,
                    ),
                  ),
                )
              else
                RouteBoard(routeName: arrival.routeNumber, compact: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      arrival.destination,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.ink,
                      ),
                    ),
                    if (arrival.stopsAway != null && arrival.stopsAway! > 0) ...[
                      const SizedBox(height: 5),
                      Text(
                        '${arrival.stopsAway} ${arrival.stopsAway == 1 ? 'stop' : 'stops'} away',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: WimbColors.inkMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 86),
                child: ArrivalEtaRange(arrival: arrival),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A route with no tracked bus: observed frequency.
class FrequencyRow extends StatelessWidget {
  final BusFrequency frequency;
  final VoidCallback? onTap;

  const FrequencyRow({super.key, required this.frequency, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          child: Row(
            children: [
              RouteBoard(routeName: frequency.routeNumber, compact: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      frequency.destination,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'About every ${frequency.headwayMinutes.round()} min',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: WimbColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: WimbColors.inkFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
