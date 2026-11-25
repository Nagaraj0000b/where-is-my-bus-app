// Parsing tests for the new arrivals and route-detail JSON.
//
// These are the contracts the new screens depend on. A field rename on the
// server should fail here before it becomes a blank screen on a phone.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wimb_app/api_client.dart';

void main() {
  test('StopArrivals keeps the range, source and matched point', () {
    final json = jsonDecode(r'''
    {
      "place": {"placeId": 572, "name": "Shivaji Stadium", "lat": 28.63, "lon": 77.21},
      "mode": "replay",
      "at": "2026-08-12T13:00:00.000Z",
      "feed": {"live": false, "reason": "Official feed is not running."},
      "arrivals": [{
        "routeId": "2229",
        "routeShortName": "764DOWN",
        "routeNumber": "764",
        "destination": "Jharoda Kalan",
        "vehicleId": "DL51EV9648",
        "source": "replay",
        "stale": false,
        "currentStopSequence": 11,
        "targetStopSequence": 12,
        "stopsAway": 1,
        "progressM": 5293,
        "progressFraction": 0.15,
        "routeLengthM": 44000,
        "recordedAt": "2026-08-12T12:53:52.000Z",
        "lastSeen": "2026-08-12T12:53:52.000Z",
        "eta": {"seconds": 217, "text": "4 min", "at": "2026-08-12T13:03:37.000Z"},
        "range": {"lowSeconds": 120, "highSeconds": 300, "text": "2 min to 5 min", "lowAt": "2026-08-12T13:02:00.000Z", "highAt": "2026-08-12T13:05:00.000Z", "couldBeArrivingNow": false},
        "confidence": {"level": "high", "because": "Nearly every leg was measured."},
        "match": {"accepted": true, "offsetM": null, "rawLat": null, "rawLon": null, "snappedLat": 28.56, "snappedLon": 77.20},
        "crowd": null
      }],
      "frequency": [{"routeId": "2229", "routeNumber": "764", "destination": "Jharoda Kalan", "headwayMinutes": 9.7, "daysSeen": 5}],
      "caveats": ["Replay: recorded, not live."]
    }
    ''') as Map<String, dynamic>;

    final board = StopArrivals.fromJson(json);
    expect(board.mode, 'replay');
    expect(board.isReplay, isTrue);
    expect(board.arrivals, hasLength(1));
    expect(board.frequency, hasLength(1));

    final arrival = board.arrivals.first;
    expect(arrival.routeNumber, '764');
    expect(arrival.rangeText, '2 min to 5 min');
    expect(arrival.etaSeconds, 217);
    expect(arrival.confidenceLevel, 'high');
    expect(arrival.snappedLat, 28.56);
    expect(arrival.isAtStop, isFalse);
    expect(arrival.isReplay, isTrue);
    expect(arrival.destination, 'Jharoda Kalan');
  });

  test('RouteDetailInfo places a bus by progress along the shape', () {
    final json = jsonDecode(r'''
    {
      "route": {"routeId": "2229", "routeShortName": "764DOWN", "routeNumber": "764", "routeDesc": "A to B", "destination": "B"},
      "shape": {"routeId": "2229", "shapeId": "shp", "lengthM": 1000, "points": [
        {"lat": 28.0, "lon": 77.0, "distM": 0},
        {"lat": 28.1, "lon": 77.1, "distM": 500},
        {"lat": 28.2, "lon": 77.2, "distM": 1000}
      ]},
      "stops": [
        {"stopSequence": 0, "stopName": "A", "lat": 28.0, "lon": 77.0, "metresAlongRoute": 0, "hasTiming": true},
        {"stopSequence": 1, "stopName": "B", "lat": 28.2, "lon": 77.2, "metresAlongRoute": 1000, "hasTiming": true}
      ],
      "runs": [],
      "frequency": null,
      "targetStopSequence": 1,
      "mode": "replay",
      "at": "2026-08-12T13:00:00.000Z",
      "feed": {"live": false, "reason": "offline"},
      "caveats": []
    }
    ''') as Map<String, dynamic>;

    final detail = RouteDetailInfo.fromJson(json);
    expect(detail.route.routeNumber, '764');
    expect(detail.shape, hasLength(3));
    expect(detail.stops, hasLength(2));
    expect(detail.stopBySequence(1)?.stopName, 'B');

    final middle = detail.pointAtDistance(250);
    expect(middle, isNotNull);
    expect(middle!.lat, closeTo(28.05, 0.001));
    expect(middle.lon, closeTo(77.05, 0.001));
  });
}
