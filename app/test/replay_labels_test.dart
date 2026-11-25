// Widget tests for the honest "this is recorded, not live" labels.
//
// The replay labels are the part of UX round 2 that must never silently
// break: a screen that forgets to say "not live" looks like a live screen.
// The ride screen is cheap to test with no network at all - it is built
// from an already-fetched detail - so it is pinned here.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wimb_app/api_client.dart';
import 'package:wimb_app/ride_screen.dart';

/// A minimal but complete replay route detail: two stops, one bus at the
/// first stop. No shape, so the map (and its real-map plugin) is skipped.
RouteDetailInfo _replayDetail() {
  final json = jsonDecode(r'''
  {
    "route": {"routeId": "2229", "routeShortName": "764DOWN", "routeNumber": "764", "routeDesc": "A to B", "destination": "Shivaji Park"},
    "shape": null,
    "stops": [
      {"stopSequence": 0, "stopName": "Shivaji Stadium", "lat": 28.63, "lon": 77.21, "metresAlongRoute": 0, "hasTiming": true},
      {"stopSequence": 1, "stopName": "Shivaji Park", "lat": 28.64, "lon": 77.22, "metresAlongRoute": 1000, "hasTiming": true}
    ],
    "runs": [{
      "routeId": "2229",
      "routeNumber": "764",
      "routeShortName": "764DOWN",
      "destination": "Shivaji Park",
      "vehicleId": "DL51EV9648",
      "source": "replay",
      "stale": false,
      "currentStopSequence": 0,
      "targetStopSequence": 1,
      "stopsAway": 1,
      "progressM": 0,
      "progressFraction": 0,
      "routeLengthM": 1000,
      "recordedAt": "2026-08-12T12:58:52.000Z",
      "lastSeen": "2026-08-12T12:58:52.000Z",
      "range": {"lowSeconds": 120, "highSeconds": 300, "text": "2 min to 5 min", "couldBeArrivingNow": false},
      "eta": {"seconds": 217, "text": "4 min", "at": "2026-08-12T13:03:37.000Z"}
    }],
    "frequency": null,
    "targetStopSequence": 1,
    "mode": "replay",
    "at": "2026-08-12T13:00:00.000Z",
    "feed": {"live": false, "reason": "Official feed is not running."},
    "caveats": []
  }
  ''') as Map<String, dynamic>;
  return RouteDetailInfo.fromJson(json);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ride screen says it is replaying recorded buses', (
    tester,
  ) async {
    final detail = _replayDetail();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RideScreen(
            detail: detail,
            run: detail.runs.first,
            destinationSequence: 1,
          ),
        ),
      ),
    );
    await tester.pump();

    // The line under "Towards ...": recorded, with the moment, and not live.
    expect(find.textContaining('Recorded buses'), findsOneWidget);
    expect(find.textContaining('not live'), findsOneWidget);
    expect(find.text('Towards Shivaji Park'), findsOneWidget);

    // Take the screen down so its 10 s refresh timer is cancelled.
    await tester.pumpWidget(const ProviderScope(child: SizedBox()));
    await tester.pump();
  });
}
