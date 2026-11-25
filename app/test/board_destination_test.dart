// Parsing tests for the board destination filter (?to=<placeId>).
//
// These pin the JSON shape agreed in scratch/ux-round2-contract.md §2:
// `destination` and `noDirect` are additions, and a server that does not
// send them must keep working exactly as before. Screens read these fields,
// so a rename on the server should fail here before it becomes a blank
// board on a phone.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimb_app/api_client.dart';

/// One arrival row with only the fields the model requires. ETA/range/match
/// are optional on the model, so leaving them out keeps the fixture small.
String _arrivalJson({
  required int targetStopSequence,
  required int stopsAway,
}) =>
    '''
    {
      "routeId": "2229",
      "routeNumber": "RL-79",
      "routeShortName": "RL-79DOWN",
      "destination": "Shivaji Park",
      "vehicleId": "DL51EV9648",
      "source": "replay",
      "stale": false,
      "currentStopSequence": 11,
      "targetStopSequence": $targetStopSequence,
      "stopsAway": $stopsAway,
      "progressM": 5293,
      "progressFraction": 0.15,
      "routeLengthM": 44000,
      "recordedAt": "2026-08-12T12:53:52.000Z",
      "lastSeen": "2026-08-12T12:53:52.000Z"
    }''';

void main() {
  test('a destination-filtered board reads destination, noDirect and the new target', () {
    final json = jsonDecode('''
    {
      "place": {"placeId": 572, "name": "Shivaji Stadium", "lat": 28.63, "lon": 77.21},
      "mode": "replay",
      "at": "2026-08-12T13:00:00.000Z",
      "feed": {"live": false, "reason": "Official feed is not running."},
      "destination": {"placeId": 818, "name": "Shivaji Park", "lat": 28.56, "lon": 77.20},
      "noDirect": false,
      "arrivals": [${_arrivalJson(targetStopSequence: 21, stopsAway: 10)}],
      "frequency": [],
      "caveats": []
    }
    ''') as Map<String, dynamic>;

    final board = StopArrivals.fromJson(json);

    expect(board.destination, isNotNull);
    expect(board.destination!.placeId, 818);
    expect(board.destination!.name, 'Shivaji Park');
    expect(board.destination!.lat, closeTo(28.56, 0.001));
    expect(board.destination!.lon, closeTo(77.20, 0.001));
    expect(board.noDirect, isFalse);

    // With `to` set the API retargets each arrival at the destination, so the
    // row's stops-away figure is measured to B, not to the next stop.
    expect(board.arrivals, hasLength(1));
    expect(board.arrivals.first.targetStopSequence, 21);
    expect(board.arrivals.first.stopsAway, 10);
  });

  test('a no-direct board is empty on purpose and carries the caveat', () {
    final json = jsonDecode('''
    {
      "place": {"placeId": 572, "name": "Shivaji Stadium", "lat": 28.63, "lon": 77.21},
      "mode": "replay",
      "at": "2026-08-12T13:00:00.000Z",
      "feed": {"live": false, "reason": "Official feed is not running."},
      "destination": {"placeId": 2, "name": "Aman Vihar", "lat": 28.70, "lon": 77.10},
      "noDirect": true,
      "arrivals": [],
      "frequency": [],
      "caveats": ["No direct bus from this stop to Aman Vihar. The Plan tab can look for a trip with one change."]
    }
    ''') as Map<String, dynamic>;

    final board = StopArrivals.fromJson(json);

    expect(board.noDirect, isTrue);
    expect(board.destination!.name, 'Aman Vihar');
    expect(board.arrivals, isEmpty);
    expect(board.frequency, isEmpty);
    expect(board.caveats.single, contains('No direct bus'));
  });

  test(
    'a server without the new fields still parses as an unfiltered board',
    () {
      // This is the pre-change response. The app must not crash on it: no
      // destination and "no direct" is false, which is what the old board
      // meant anyway.
      final json = jsonDecode('''
    {
      "place": {"placeId": 572, "name": "Shivaji Stadium", "lat": 28.63, "lon": 77.21},
      "mode": "replay",
      "at": "2026-08-12T13:00:00.000Z",
      "feed": {"live": false, "reason": "Official feed is not running."},
      "arrivals": [${_arrivalJson(targetStopSequence: 12, stopsAway: 1)}],
      "frequency": [],
      "caveats": []
    }
    ''') as Map<String, dynamic>;

      final board = StopArrivals.fromJson(json);

      expect(board.destination, isNull);
      expect(board.noDirect, isFalse);
      expect(board.arrivals.first.targetStopSequence, 12);
    },
  );
}
