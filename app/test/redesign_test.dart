import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wimb_app/api_client.dart';
import 'package:wimb_app/arrival_widgets.dart';
import 'package:wimb_app/saved_screen.dart';

BusArrival arrival({
  required String routeId,
  required String routeNumber,
  required int etaSeconds,
  String destination = 'Shivaji Park',
  String source = 'official',
  bool stale = false,
}) {
  final now = DateTime.now();
  return BusArrival(
    routeId: routeId,
    routeNumber: routeNumber,
    routeShortName: routeId,
    destination: destination,
    vehicleId: 'bus-$routeId-$etaSeconds',
    source: source,
    stale: stale,
    currentStopSequence: 3,
    targetStopSequence: 8,
    stopsAway: 5,
    progressM: 1200,
    progressFraction: 0.3,
    routeLengthM: 4000,
    recordedAt: now.subtract(const Duration(seconds: 6)),
    lastSeen: now.subtract(const Duration(seconds: 6)),
    etaSeconds: etaSeconds,
    etaText: '${(etaSeconds / 60).round()} min',
    etaAt: now.add(Duration(seconds: etaSeconds)),
    rangeLowSeconds: etaSeconds - 60,
    rangeHighSeconds: etaSeconds + 120,
    rangeText:
        '${((etaSeconds - 60) / 60).round()}–${((etaSeconds + 120) / 60).round()} min',
    confidenceLevel: 'high',
    confidenceBecause: '',
    snappedLat: 28.63,
    snappedLon: 77.21,
    offsetM: 8,
    unavailableReason: null,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('groups two buses under one route and keeps a frequency-only route', () {
    final board = StopArrivals(
      placeId: 1,
      placeName: 'Shivaji Stadium',
      lat: 28.63,
      lon: 77.21,
      mode: 'live',
      at: DateTime.now(),
      feedLive: true,
      feedReason: '',
      arrivals: [
        arrival(routeId: '2433UP', routeNumber: '2433', etaSeconds: 240),
        arrival(routeId: '2433UP', routeNumber: '2433', etaSeconds: 900),
        arrival(routeId: '2417UP', routeNumber: '2417', etaSeconds: 600),
      ],
      frequency: [
        BusFrequency(
          routeId: '244UP',
          routeNumber: '244',
          destination: 'Nehru Place',
          headwayMinutes: 12,
          daysSeen: 6,
        ),
      ],
      caveats: const [],
    );

    final groups = groupArrivals(board);

    expect(groups.length, 3);
    final first = groups.first;
    expect(first.routeId, '2433UP');
    expect(first.arrivals.length, 2);
    expect(first.arrivals.first.etaSeconds, 240);
    expect(
      groups.any((g) => g.routeId == '244UP' && g.isFrequencyOnly),
      isTrue,
    );
  });

  testWidgets('RouteBoardRow shows two ETAs for one route', (tester) async {
    final board = StopArrivals(
      placeId: 1,
      placeName: 'Shivaji Stadium',
      lat: 28.63,
      lon: 77.21,
      mode: 'live',
      at: DateTime.now(),
      feedLive: true,
      feedReason: '',
      arrivals: [
        arrival(routeId: '2433UP', routeNumber: '2433', etaSeconds: 240),
        arrival(routeId: '2433UP', routeNumber: '2433', etaSeconds: 900),
      ],
      frequency: const [],
      caveats: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RouteBoardRow(group: groupArrivals(board).first)),
      ),
    );

    expect(find.text('2433'), findsOneWidget);
    expect(find.text('Shivaji Park'), findsOneWidget);
    expect(find.textContaining('min'), findsWidgets);
  });

  testWidgets('Saved screen is a real empty state', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SavedScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing saved yet'), findsOneWidget);
  });
}
