// "When should I travel?" - the same journey costed for every service
// hour, so someone can see whether leaving now or later is actually
// faster. See api/src/server.ts on /journey/by-hour for why this needs
// OBSERVED frequency and can't come from a published timetable - no other
// Delhi bus app answers this question.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'theme.dart';

/// The two points and the day type being compared. Day type is part of the
/// query (not a separate toggle after the fact) because weekday and
/// weekend traffic genuinely differ - see the weekend caveat this endpoint
/// always returns.
class ByHourQuery {
  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final String dayType; // 'weekday' | 'weekend'
  final String fromName;
  final String toName;

  const ByHourQuery({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.dayType,
    required this.fromName,
    required this.toName,
  });

  @override
  bool operator ==(Object other) =>
      other is ByHourQuery &&
      other.fromLat == fromLat &&
      other.fromLon == fromLon &&
      other.toLat == toLat &&
      other.toLon == toLon &&
      other.dayType == dayType;

  @override
  int get hashCode => Object.hash(fromLat, fromLon, toLat, toLon, dayType);
}

final byHourQueryProvider = StateProvider<ByHourQuery?>((ref) => null);

final byHourResultProvider = FutureProvider.autoDispose
    .family<ByHourResult, ByHourQuery>((ref, query) {
  return fetchJourneyByHour(
    fromLat: query.fromLat,
    fromLon: query.fromLon,
    toLat: query.toLat,
    toLon: query.toLon,
    dayType: query.dayType,
  );
});

class ByHourScreen extends ConsumerStatefulWidget {
  const ByHourScreen({super.key});

  @override
  ConsumerState<ByHourScreen> createState() => _ByHourScreenState();
}

class _ByHourScreenState extends ConsumerState<ByHourScreen> {
  // No text controllers - places arrive only from the search page, so
  // there is no typed text that could drift out of step with the
  // coordinates behind it. Same reasoning as journey_screen.dart.
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;
  String _dayType = 'weekday';

  void _compare() {
    // The button is disabled until both are chosen, so this is just belt
    // and braces.
    if (_fromPlace == null || _toPlace == null) return;

    final query = ByHourQuery(
      fromLat: _fromPlace!.lat,
      fromLon: _fromPlace!.lon,
      toLat: _toPlace!.lat,
      toLon: _toPlace!.lon,
      dayType: _dayType,
      fromName: _fromPlace!.stopName,
      toName: _toPlace!.stopName,
    );
    ref.read(byHourQueryProvider.notifier).state = query;
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(byHourQueryProvider);

    final canCompare = _fromPlace != null && _toPlace != null;

    return Scaffold(
      appBar: AppBar(title: const Text('When should I travel?')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: [
          Card(
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
                const Divider(height: 1, indent: 48),
                PlacePickerRow(
                  label: 'TO',
                  place: _toPlace,
                  icon: Icons.place,
                  iconColor: WimbColors.dtcRed,
                  onPicked: (place) => setState(() => _toPlace = place),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // A pill pair, sized to the thumb.
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'weekday', label: Text('Weekday')),
              ButtonSegment(value: 'weekend', label: Text('Weekend')),
            ],
            selected: {_dayType},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => setState(() => _dayType = selection.first),
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? WimbColors.dtcRed
                    : WimbColors.cardCream,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.white
                    : WimbColors.inkMuted,
              ),
              side: const WidgetStatePropertyAll(BorderSide.none),
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 15)),
            ),
          ),

          const SizedBox(height: 16),
          FilledButton(
            onPressed: canCompare ? _compare : null,
            child: const Text('Compare hours'),
          ),
          const SizedBox(height: 24),
          if (query == null) _emptyState(context) else _ResultsArea(query: query),
        ],
      ),
    );
  }

  /// Explains what this screen is for before anything has been compared -
  /// and why no other bus app can answer it.
  Widget _emptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 22),
      child: Column(
        children: [
          Icon(Icons.schedule, size: 44, color: WimbColors.hairline),
          const SizedBox(height: 14),
          Text(
            'Is it faster to leave later?',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'The same trip is costed for every hour buses run, using how '
            'often they were actually observed - not a published timetable, '
            'which could never tell you this.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ResultsArea extends ConsumerWidget {
  final ByHourQuery query;
  const _ResultsArea({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(byHourResultProvider(query));

    return result.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      // See journey_screen.dart's identical split: this branch means the
      // request itself failed (unlike an honest "no route found" below),
      // so retrying the same query is worth offering.
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(byHourResultProvider(query)),
      ),
      data: (byHour) {
        if (!byHour.available) {
          return ErrorCard(message: byHour.unavailableReason ?? 'No route found.');
        }
        // The bars are drawn relative to the slowest costed hour, so the
        // longest bar fills the row and every other hour is read against
        // it. Worked out once here rather than inside every row.
        final slowest = byHour.hours
            .map((h) => h.totalMinutes ?? 0)
            .fold<double>(0, (a, b) => a > b ? a : b);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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

            // The headline answer, before the detail.
            Card(
              color: WimbColors.delhiGreenLight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, color: WimbColors.delhiGreen, size: 21),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        byHour.advice,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: WimbColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
            const SectionLabel('Hour by hour'),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                child: Column(
                  children: [
                    for (final hour in byHour.hours)
                      _HourRow(
                        hour: hour,
                        slowestMinutes: slowest,
                        isBest: byHour.best != null && hour.hourOfDay == byHour.best!.hourOfDay,
                        isWorst: byHour.worst != null && hour.hourOfDay == byHour.worst!.hourOfDay,
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),
            ...byHour.caveats.map((c) => CaveatLine(c)),
          ],
        );
      },
    );
  }
}

/// One hour, drawn as a bar.
///
/// A bar rather than a column of numbers because the question this screen
/// answers is comparative - "is 08:00 better than 16:00" - and comparing
/// eighteen numbers by reading them is work the picture can do instead.
/// The number stays alongside for anyone who wants the exact figure.
class _HourRow extends StatelessWidget {
  final HourlyJourney hour;

  /// The longest journey of the day, which the bars are scaled against.
  final double slowestMinutes;
  final bool isBest;
  final bool isWorst;

  const _HourRow({
    required this.hour,
    required this.slowestMinutes,
    required this.isBest,
    required this.isWorst,
  });

  /// Best is green, worst is the alarm colour, everything between is a
  /// neutral red-brown. Only the two extremes are coloured, because
  /// colouring all eighteen would leave nothing standing out.
  Color get _barColor {
    if (isBest) return WimbColors.delhiGreen;
    if (isWorst) return WimbColors.trustLow;
    return WimbColors.dtcRed.withValues(alpha: 0.45);
  }

  @override
  Widget build(BuildContext context) {
    final noData = hour.totalMinutes == null;
    final label = '${hour.hourOfDay.toString().padLeft(2, '0')}:00';
    final emphasised = isBest || isWorst;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            // Wide enough for "05:00" without wrapping. It was 44 and the
            // label broke onto a second line as "05:0 / 0", which looked
            // broken - the width has to fit the text, not the other way
            // round, so maxLines below makes that impossible to miss again.
            width: 52,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                // Tabular figures so every hour is the same width and the
                // bars all start on one clean vertical line - what a
                // monospace font would have been used for.
                fontFeatures: WimbFonts.tabular,
                fontSize: 13,
                fontWeight: emphasised ? FontWeight.w700 : FontWeight.w400,
                color: emphasised ? WimbColors.ink : WimbColors.inkMuted,
              ),
            ),
          ),
          Expanded(
            child: noData
                ? Text(
                    'no data for this hour',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: WimbColors.inkMuted.withValues(alpha: 0.65),
                        ),
                  )
                : _bar(context),
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final minutes = hour.totalMinutes!;
    // Guard against a divide-by-zero if every hour somehow costed 0.
    final fraction = slowestMinutes > 0 ? (minutes / slowestMinutes).clamp(0.05, 1.0) : 1.0;

    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              // The track behind the bar, so short bars still read as
              // "short compared to the day" rather than floating in space.
              Container(
                height: 20,
                decoration: BoxDecoration(
                  color: WimbColors.hairline.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  height: 20,
                  decoration: BoxDecoration(
                    color: _barColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 9),
        SizedBox(
          width: 46,
          child: Text(
            '${minutes.round()}m',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFeatures: WimbFonts.tabular,
              fontSize: 13,
              fontWeight: isBest || isWorst ? FontWeight.w700 : FontWeight.w400,
              color: isBest
                  ? WimbColors.delhiGreen
                  : isWorst
                      ? WimbColors.trustLow
                      : WimbColors.ink,
            ),
          ),
        ),
        // The confidence dot stays, but small - the bar is what carries
        // the comparison, and five full trust dots on every row would
        // drown it.
        const SizedBox(width: 7),
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: trustColor(hour.confidenceLevel ?? ''),
          ),
        ),
      ],
    );
  }
}
