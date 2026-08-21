// "When should I travel?" - the same journey costed for every service
// hour, so someone can see whether leaving now or later is actually
// faster. See api/src/server.ts on /journey/by-hour for why this needs
// OBSERVED frequency and can't come from a published timetable - no other
// Delhi bus app answers this question.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'error_card.dart';
import 'place_search_field.dart';

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
  final _fromController = TextEditingController();
  final _toController = TextEditingController();
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;
  String _dayType = 'weekday';

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _compare() {
    if (_fromPlace == null || _fromController.text != _fromPlace!.stopName) {
      _showMessage('Pick a "From" place from the suggestions.');
      return;
    }
    if (_toPlace == null || _toController.text != _toPlace!.stopName) {
      _showMessage('Pick a "To" place from the suggestions.');
      return;
    }

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

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(byHourQueryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('When should I travel?')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PlaceSearchField(
            label: 'From',
            controller: _fromController,
            onPicked: (place) => setState(() => _fromPlace = place),
          ),
          const SizedBox(height: 8),
          PlaceSearchField(
            label: 'To',
            controller: _toController,
            onPicked: (place) => setState(() => _toPlace = place),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'weekday', label: Text('Weekday')),
              ButtonSegment(value: 'weekend', label: Text('Weekend')),
            ],
            selected: {_dayType},
            onSelectionChanged: (selection) =>
                setState(() => _dayType = selection.first),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _compare, child: const Text('Compare hours')),
          const SizedBox(height: 24),
          if (query != null) _ResultsArea(query: query),
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${query.fromName} → ${query.toName}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(byHour.advice, style: const TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 16),
            Text('By the hour', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final hour in byHour.hours)
              _HourRow(
                hour: hour,
                isBest: byHour.best != null && hour.hourOfDay == byHour.best!.hourOfDay,
                isWorst: byHour.worst != null && hour.hourOfDay == byHour.worst!.hourOfDay,
              ),
            const SizedBox(height: 12),
            ...byHour.caveats.map(
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

/// One line in the hour-by-hour list. Bars are relative to the slowest
/// costed hour, so "this hour is better" is visible at a glance rather
/// than something someone has to read every number to work out.
class _HourRow extends StatelessWidget {
  final HourlyJourney hour;
  final bool isBest;
  final bool isWorst;

  const _HourRow({required this.hour, required this.isBest, required this.isWorst});

  Color? _confidenceColor(BuildContext context) {
    switch (hour.confidenceLevel) {
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
  Widget build(BuildContext context) {
    final noData = hour.totalMinutes == null;
    final label = '${hour.hourOfDay.toString().padLeft(2, '0')}:00';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isBest || isWorst ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (!noData) ...[
            Icon(Icons.circle, size: 8, color: _confidenceColor(context)),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: noData
                ? Text(
                    'no data for this hour',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontStyle: FontStyle.italic),
                  )
                : Text(
                    '${hour.totalMinutes!.round()} min'
                    '${isBest ? '  •  best' : ''}${isWorst ? '  •  worst' : ''}',
                    style: TextStyle(
                      fontWeight: isBest || isWorst ? FontWeight.bold : FontWeight.normal,
                      color: isBest
                          ? Colors.green.shade700
                          : isWorst
                              ? Colors.red.shade700
                              : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
