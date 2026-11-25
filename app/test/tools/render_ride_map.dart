// Screenshot harness for the ride map (not shipped, not part of the normal
// suite - the file name does not end in _test.dart on purpose).
//
//   cd app
//   flutter test test/tools/render_ride_map.dart
//
// Writes PNGs into scratch/ so the arrows, the route line and the full-screen
// layout can be eyeballed without a phone or a live backend.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:wimb_app/api_client.dart';
import 'package:wimb_app/ride_screen.dart';
import 'package:wimb_app/theme.dart';
import 'package:wimb_app/transit_map.dart';

/// Loads the app's real fonts, so the screenshot is not a page of boxes.
Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final data = await rootBundle.load('assets/fonts/$file');
      loader.addFont(Future<ByteData>.value(data));
    }
    await loader.load();
  }

  await load('Barlow', [
    'Barlow-Regular.ttf',
    'Barlow-Medium.ttf',
    'Barlow-SemiBold.ttf',
    'Barlow-Bold.ttf',
  ]);
  await load('BarlowCondensed', [
    'BarlowCondensed-SemiBold.ttf',
    'BarlowCondensed-Bold.ttf',
  ]);

  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

/// A short stretch of a Delhi route, curving like a real road, so the arrow
/// has something to point along.
List<RouteShapePointInfo> _shape() {
  final points = [
    [28.6300, 77.2100],
    [28.6303, 77.2106],
    [28.6309, 77.2110],
    [28.6316, 77.2111],
    [28.6324, 77.2117],
    [28.6329, 77.2126],
    [28.6330, 77.2136],
    [28.6326, 77.2145],
  ];
  const spacing = 95.0;
  return [
    for (var i = 0; i < points.length; i++)
      RouteShapePointInfo(
        lat: points[i][0],
        lon: points[i][1],
        distM: spacing * i,
      ),
  ];
}

RouteDetailInfo _detail() {
  final shape = _shape();
  return RouteDetailInfo(
    route: RouteInfo(
      routeId: '764UP',
      routeNumber: '764',
      routeShortName: '764',
      routeDesc: 'Nehru Place to Shivaji Stadium',
      destination: 'Shivaji Stadium',
    ),
    shape: shape,
    stops: [
      RouteStopInfo(
        stopSequence: 1,
        stopName: 'Nehru Place',
        lat: shape[0].lat,
        lon: shape[0].lon,
        metresAlongRoute: shape[0].distM,
        hasTiming: true,
      ),
      RouteStopInfo(
        stopSequence: 2,
        stopName: 'Kalkaji Mandir',
        lat: shape[3].lat,
        lon: shape[3].lon,
        metresAlongRoute: shape[3].distM,
        hasTiming: true,
      ),
      RouteStopInfo(
        stopSequence: 3,
        stopName: 'Shivaji Stadium',
        lat: shape[7].lat,
        lon: shape[7].lon,
        metresAlongRoute: shape[7].distM,
        hasTiming: true,
      ),
    ],
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

BusArrival _run() {
  final now = DateTime.now();
  return BusArrival(
    routeId: '764UP',
    routeNumber: '764',
    routeShortName: '764',
    destination: 'Shivaji Stadium',
    vehicleId: 'DL1PC1234',
    source: 'replay',
    stale: false,
    currentStopSequence: 2,
    targetStopSequence: 3,
    stopsAway: 1,
    progressM: 210,
    progressFraction: 0.4,
    routeLengthM: 665,
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
    snappedLat: 28.6309,
    snappedLon: 77.2110,
    offsetM: 5,
    unavailableReason: null,
  );
}

Future<void> _capture(WidgetTester tester, Finder finder, String path) async {
  // toImage and file writes are real async work; a widget test's fake clock
  // would never let the await finish unless it runs outside the test zone.
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('wrote $path');
}

void main() {
  testWidgets('render the ride map inline and full screen', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(390 * 2.5, 844 * 2.5);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWimbTheme(),
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: key,
          child: RideScreen(
            detail: _detail(),
            run: _run(),
            destinationSequence: 3,
            enableMapTiles: false,
            // A Delhi demo position, so the rider's own marker appears too.
            userLocation: const LatLng(28.6304, 77.2104),
            simulatedLocation: true,
            locationLabel: 'Near Nehru Place',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, find.byKey(key), '../scratch/ride_map_inline.png');

    // Expand to the navigation-style full screen.
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, find.byKey(key), '../scratch/ride_map_full.png');

    // Put the screen away so its poll timer is cancelled.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('render both direction arrows close up', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(390 * 2.5, 420 * 2.5);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWimbTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: WimbColors.cream,
          body: RepaintBoundary(
            key: key,
            child: TransitMap(
              height: 420,
              borderRadius: 0,
              center: const LatLng(28.6316, 77.2114),
              initialZoom: 16.2,
              enableTiles: false,
              userLocation: const LatLng(28.6304, 77.2104),
              userHeadingDeg: 20,
              locationLabel: 'Near Nehru Place',
              polyline: [
                for (final point in _shape()) LatLng(point.lat, point.lon),
              ],
              buses: const [
                MapBus(
                  point: LatLng(28.6324, 77.2117),
                  routeNumber: '764',
                  source: 'official',
                  headingDeg: 55,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await _capture(tester, find.byKey(key), '../scratch/ride_map_arrows.png');
  });
}
