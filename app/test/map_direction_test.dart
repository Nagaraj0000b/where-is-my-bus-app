// What the direction work should do, in small pieces.
//
// The feed sends no bearing, so these tests pin down the two things that
// replace it: the compass maths, and the arrow markers that use it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:wimb_app/api_client.dart';
import 'package:wimb_app/ride_screen.dart';
import 'package:wimb_app/route_utils.dart';
import 'package:wimb_app/theme.dart';
import 'package:wimb_app/transit_map.dart';

/// A straight line of shape points every 10 m, so the 30 m bearing window
/// always stays inside one segment and the answer is exact.
List<RouteShapePointInfo> straightShape({
  required double fromLat,
  required double fromLon,
  double dLat = 0,
  double dLon = 0,
  int points = 30,
}) {
  return [
    for (var i = 0; i < points; i++)
      RouteShapePointInfo(
        lat: fromLat + dLat * i,
        lon: fromLon + dLon * i,
        distM: 10.0 * i,
      ),
  ];
}

RouteDetailInfo detailFixture(List<RouteShapePointInfo> shape) {
  final stops = shape.isEmpty
      ? <RouteStopInfo>[]
      : [
          RouteStopInfo(
            stopSequence: 1,
            stopName: 'Start',
            lat: shape.first.lat,
            lon: shape.first.lon,
            metresAlongRoute: 0,
            hasTiming: true,
          ),
          RouteStopInfo(
            stopSequence: 2,
            stopName: 'Middle',
            lat: shape[shape.length ~/ 2].lat,
            lon: shape[shape.length ~/ 2].lon,
            metresAlongRoute: shape[shape.length ~/ 2].distM,
            hasTiming: true,
          ),
          RouteStopInfo(
            stopSequence: 3,
            stopName: 'Your stop',
            lat: shape.last.lat,
            lon: shape.last.lon,
            metresAlongRoute: shape.last.distM,
            hasTiming: true,
          ),
        ];
  return RouteDetailInfo(
    route: RouteInfo(
      routeId: '764UP',
      routeNumber: '764',
      routeShortName: '764',
      routeDesc: 'Nehru Place to Shivaji Stadium',
      destination: 'Shivaji Stadium',
    ),
    shape: shape,
    stops: stops,
    runs: const [],
    frequency: null,
    targetStopSequence: 3,
    mode: 'replay',
    at: DateTime(2026, 8, 16, 13, 30),
    feedLive: false,
    feedReason: 'recorder off',
    firstDeparture: null,
    lastDeparture: null,
    caveats: const [],
  );
}

BusArrival runFixture() {
  final now = DateTime.now();
  return BusArrival(
    routeId: '764UP',
    routeNumber: '764',
    routeShortName: '764',
    destination: 'Shivaji Stadium',
    vehicleId: 'DL1PC1234',
    source: 'replay',
    stale: false,
    currentStopSequence: 1,
    targetStopSequence: 3,
    stopsAway: 2,
    progressM: 50,
    progressFraction: 0.2,
    routeLengthM: 290,
    recordedAt: now,
    lastSeen: now,
    etaSeconds: 300,
    etaText: '5 min',
    etaAt: now.add(const Duration(minutes: 5)),
    rangeLowSeconds: 240,
    rangeHighSeconds: 420,
    rangeText: '4-7 min',
    confidenceLevel: 'high',
    confidenceBecause: '',
    snappedLat: 28.63,
    snappedLon: 77.21,
    offsetM: 5,
    unavailableReason: null,
  );
}

void main() {
  group('bearingBetween', () {
    test('north, east, south and west read as a compass', () {
      expect(bearingBetween(28.63, 77.21, 28.64, 77.21), closeTo(0, 0.5));
      expect(bearingBetween(28.63, 77.21, 28.63, 77.22), closeTo(90, 0.5));
      expect(bearingBetween(28.63, 77.21, 28.62, 77.21), closeTo(180, 0.5));
      expect(bearingBetween(28.63, 77.21, 28.63, 77.20), closeTo(270, 0.5));
    });

    test('the same point twice does not crash', () {
      expect(bearingBetween(28.63, 77.21, 28.63, 77.21), 0);
    });
  });

  group('RouteDetailInfo.bearingAtDistance', () {
    test('east-bound shape points give an east bearing', () {
      final detail = detailFixture(
        straightShape(fromLat: 28.63, fromLon: 77.21, dLon: 0.0001),
      );
      for (final distance in [0.0, 50.0, 120.0, 250.0]) {
        expect(detail.bearingAtDistance(distance), closeTo(90, 1));
      }
    });

    test('north-bound shape points give a north bearing', () {
      final detail = detailFixture(
        straightShape(fromLat: 28.63, fromLon: 77.21, dLat: 0.0001),
      );
      expect(detail.bearingAtDistance(100), closeTo(0, 1));
    });

    test('no shape means no bearing', () {
      final detail = detailFixture(const []);
      expect(detail.bearingAtDistance(0), isNull);
    });
  });

  group('the map', () {
    testWidgets('draws a bus and the rider as direction arrows', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWimbTheme(),
          home: Scaffold(
            body: TransitMap(
              height: 320,
              center: const LatLng(28.63, 77.21),
              initialZoom: 15,
              enableTiles: false,
              userLocation: const LatLng(28.6302, 77.2104),
              userHeadingDeg: 45,
              polyline: const [LatLng(28.63, 77.21), LatLng(28.631, 77.211)],
              buses: const [
                MapBus(
                  point: LatLng(28.6308, 77.2108),
                  routeNumber: '764',
                  source: 'official',
                  headingDeg: 90,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // The bus tag and the rider tag are both there...
      expect(find.text('764'), findsOneWidget);
      expect(find.text('YOU'), findsOneWidget);
      // ...and both are arrows, not dots.
      expect(find.byIcon(Icons.navigation), findsNWidgets(2));
      // The map has its Google-Maps-style controls.
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget);
      expect(find.byIcon(Icons.my_location), findsOneWidget);
    });

    testWidgets('a bus with no heading keeps the plain route label', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWimbTheme(),
          home: Scaffold(
            body: TransitMap(
              height: 320,
              center: const LatLng(28.63, 77.21),
              initialZoom: 15,
              enableTiles: false,
              buses: const [
                MapBus(
                  point: LatLng(28.6308, 77.2108),
                  routeNumber: '764',
                  source: 'official',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('764'), findsOneWidget);
      expect(find.byIcon(Icons.navigation), findsNothing);
    });

    testWidgets('the bus arrow is turned by its bearing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWimbTheme(),
          home: Scaffold(
            body: TransitMap(
              height: 320,
              center: const LatLng(28.63, 77.21),
              initialZoom: 15,
              enableTiles: false,
              buses: const [
                MapBus(
                  point: LatLng(28.6308, 77.2108),
                  routeNumber: '764',
                  source: 'official',
                  headingDeg: 90,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final arrow = find.byIcon(Icons.navigation);
      expect(arrow, findsOneWidget);
      final transform = tester.widget<Transform>(
        find.ancestor(of: arrow, matching: find.byType(Transform)).first,
      );
      final matrix = transform.transform.storage;
      // Bearing 90 means east, which is "turn the upward arrow a quarter
      // turn clockwise". Flutter's rotation matrix for +90 degrees is
      // [cos, sin] = [0, 1], so this pins the sign of the rotation.
      expect(matrix[0], closeTo(0, 1e-6));
      expect(matrix[1], closeTo(1, 1e-6));
      expect(matrix[4], closeTo(-1, 1e-6));
      expect(matrix[5], closeTo(0, 1e-6));
    });

    testWidgets('the expand button is offered and calls back', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWimbTheme(),
          home: Scaffold(
            body: TransitMap(
              height: 320,
              center: const LatLng(28.63, 77.21),
              enableTiles: false,
              onExpand: () => pressed++,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      expect(pressed, 1);
    });
  });

  group('the ride screen', () {
    testWidgets('ride map opens full screen and comes back', (tester) async {
      final detail = detailFixture(
        straightShape(fromLat: 28.63, fromLon: 77.21, dLon: 0.0001),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildWimbTheme(),
          home: RideScreen(
            detail: detail,
            run: runFixture(),
            destinationSequence: 3,
            enableMapTiles: false,
          ),
        ),
      );
      // A few frames: the map has to lay out before its markers exist.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Inline ride map: the bus is an arrow (the legend uses the same
      // glyph) and the map can expand.
      expect(find.byIcon(Icons.navigation), findsWidgets);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      expect(find.text('764'), findsWidgets);

      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Full screen: no app bar, a collapse button, and the ride card.
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(find.text('Change stop'), findsOneWidget);
      expect(find.text("I'm getting off"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);

      // The phone's back gesture collapses the map first; it does not leave
      // the ride (PopScope).
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);

      // Dispose the screen so its 10 s poll timer is cancelled before the
      // test ends.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
