// Talks to the backend and turns its JSON answers into plain Dart objects.
//
// The backend (api/src/journey.ts) never hands back a bare number - every
// time estimate comes with a range and a source, not a single number. This
// file keeps that shape all the way through, so the screen cannot
// accidentally show just "15.6 min" and drop the source.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'offline_transit_pack.dart'
    if (dart.library.html) 'offline_transit_pack_web.dart';
import 'route_utils.dart';

// A phone cannot reach "localhost" and mean the laptop - to the phone,
// localhost is the phone itself.
//
// The API address is not hardcoded here. It comes from the repository's
// .env file at build time:
//
//   cd app
//   flutter build apk --release --dart-define-from-file=../.env
//
// API_BASE in that file is the tunnel or LAN address for the phone. With no
// .env, the default below is the local Fastify server, which a phone can
// reach over USB with:
//
//   adb reverse tcp:3000 tcp:3000
const _fixedApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://127.0.0.1:3000',
);

String apiBaseUrl = _fixedApiBase;
bool _hasResolvedUrl = false;

/// Probes the configured API address and locks onto it once it responds.
///
/// A failed probe is deliberately NOT remembered: the API or the tunnel may
/// come up after the first request. The next call tries again instead of
/// being permanently stuck on a guess.
Future<String> getApiBaseUrl() async {
  if (_hasResolvedUrl) return apiBaseUrl;

  const local = 'http://127.0.0.1:3000';
  final candidates = <String>[
    _fixedApiBase,
    // Keep the USB fallback unless the configured address already is it.
    if (_fixedApiBase != local) local,
  ];

  for (final base in candidates) {
    try {
      final res = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(milliseconds: 1200));
      if (res.statusCode == 200) {
        apiBaseUrl = base;
        _hasResolvedUrl = true;
        return base;
      }
    } catch (_) {}
  }

  return apiBaseUrl;
}

/// Turns a JSON number into a double, whether the server sent 10 or 10.5 -
/// or, awkwardly, "10". Dart's json.decode gives back an int for whole
/// numbers, and casting that straight to double throws, so every number
/// field goes through this instead of a raw `as double`.
///
/// The string case is not hypothetical: Postgres NUMERIC columns come back
/// from node-postgres as strings (it will not silently risk losing
/// precision converting to a JS number), and it is easy for that to leak
/// into a JSON response unless every query remembers to cast back to int
/// or float8 - as /routes/:id/stops did until this was found on a real
/// route. Handling it here too, not only by fixing the query, means the
/// exact same crash cannot come back from some future endpoint that
/// forgets the same cast.
double _asDouble(dynamic value) {
  if (value is String) return double.parse(value);
  return (value as num).toDouble();
}

/// Like [_asDouble], but a missing value is allowed and becomes [fallback].
///
/// The paper protocol can send a null inside `solved` when the four-sphere
/// system was singular: JSON has no way to write NaN, and node writes null
/// instead. A screen must show that honestly rather than crash on a cast.
/// Delhi's stop names contain loose parentheses, e.g.
/// "Shivaji Stadium Terminal ( Connaught Place )". Tidy the spacing so the
/// board does not look like a database dump.
String _cleanName(String value) {
  return value
      .replaceAll(RegExp(r'\s*\(\s*'), ' (')
      .replaceAll(RegExp(r'\s*\)'), ')')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// One leg of a journey: riding a single bus from one place to another.
class JourneyLeg {
  final String routeId;
  final String routeName; // the real bus number, e.g. "944UP" - not routeId
  final String routeDesc; // the bus's destination board text, e.g. "X to Y"
  final String boardPlace;
  final String alightPlace;
  final int stops;
  final double rideMinutes;
  final double waitMinutes;
  final double? busEveryMinutes;

  JourneyLeg({
    required this.routeId,
    required this.routeName,
    required this.routeDesc,
    required this.boardPlace,
    required this.alightPlace,
    required this.stops,
    required this.rideMinutes,
    required this.waitMinutes,
    required this.busEveryMinutes,
  });

  factory JourneyLeg.fromJson(Map<String, dynamic> json) {
    return JourneyLeg(
      routeId: json['routeId'] as String,
      routeName: json['routeName'] as String,
      routeDesc: json['routeDesc'] as String,
      boardPlace: json['boardPlace'] as String,
      alightPlace: json['alightPlace'] as String,
      stops: json['stops'] as int,
      rideMinutes: _asDouble(json['rideMinutes']),
      waitMinutes: _asDouble(json['waitMinutes']),
      busEveryMinutes: json['busEveryMinutes'] == null
          ? null
          : _asDouble(json['busEveryMinutes']),
    );
  }
}

/// How complete the observed data behind one option is, carried all the
/// way from the database into the widget tree.
class Confidence {
  final String level; // 'high' | 'medium' | 'low'
  final String because;

  Confidence({required this.level, required this.because});

  factory Confidence.fromJson(Map<String, dynamic> json) {
    return Confidence(
      level: json['level'] as String,
      because: json['because'] as String,
    );
  }
}

/// One way to make the journey - direct, or with one change of bus.
class JourneyOption {
  final int changes;
  final String summary;
  final double totalMinutes;
  final double earliestMinutes;
  final double latestMinutes;
  final double walkMinutes;
  final double waitMinutes;
  final double rideMinutes;
  final Confidence confidence;
  final List<JourneyLeg> legs;

  JourneyOption({
    required this.changes,
    required this.summary,
    required this.totalMinutes,
    required this.earliestMinutes,
    required this.latestMinutes,
    required this.walkMinutes,
    required this.waitMinutes,
    required this.rideMinutes,
    required this.confidence,
    required this.legs,
  });

  factory JourneyOption.fromJson(Map<String, dynamic> json) {
    final range = json['rangeMinutes'] as Map<String, dynamic>;
    final breakdown = json['breakdown'] as Map<String, dynamic>;
    return JourneyOption(
      changes: json['changes'] as int,
      summary: json['summary'] as String,
      totalMinutes: _asDouble(json['totalMinutes']),
      earliestMinutes: _asDouble(range['earliest']),
      latestMinutes: _asDouble(range['latest']),
      walkMinutes: _asDouble(breakdown['walkMinutes']),
      waitMinutes: _asDouble(breakdown['waitMinutes']),
      rideMinutes: _asDouble(breakdown['rideMinutes']),
      confidence: Confidence.fromJson(
        json['confidence'] as Map<String, dynamic>,
      ),
      legs: (json['legs'] as List)
          .map((leg) => JourneyLeg.fromJson(leg as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// The full answer to "how do I get from A to B" - either a list of ranked
/// options, or an honest explanation of why none were found.
class JourneyResult {
  final bool available;
  final List<JourneyOption> options;
  final List<String> caveats;
  final String? unavailableReason;

  JourneyResult({
    required this.available,
    required this.options,
    required this.caveats,
    this.unavailableReason,
  });

  factory JourneyResult.fromJson(Map<String, dynamic> json) {
    final available = json['available'] as bool;
    if (!available) {
      return JourneyResult(
        available: false,
        options: [],
        caveats: [],
        unavailableReason: json['reason'] as String?,
      );
    }
    return JourneyResult(
      available: true,
      options: (json['options'] as List)
          .map((o) => JourneyOption.fromJson(o as Map<String, dynamic>))
          .toList(),
      caveats: (json['caveats'] as List).map((c) => c as String).toList(),
    );
  }
}

/// Thrown when the server can't be reached at all - as opposed to the
/// server answering honestly with "no route found", which is not an error.
class ApiUnreachableException implements Exception {
  final String message;
  ApiUnreachableException(this.message);
  @override
  String toString() => message;
}

/// One place a person could type into a "From"/"To" box - a name to show,
/// and the coordinates behind it that actually get sent to /journey.
class PlaceSuggestion {
  final String stopName;
  final double lat;
  final double lon;
  final int? placeId;

  const PlaceSuggestion({
    required this.stopName,
    required this.lat,
    required this.lon,
    this.placeId,
  });

  factory PlaceSuggestion.fromJson(Map<String, dynamic> json) {
    return PlaceSuggestion(
      stopName: _cleanName(json['stop_name'] as String),
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      placeId: json['place_id'] as int?,
    );
  }

  @override
  String toString() => stopName;
}

final _offlineTransitPack = OfflineTransitPack();

/// Looks up stops/places by typed name, for the "From"/"To" autocomplete
/// boxes. Returns an empty list rather than throwing on a network hiccup -
/// a failed suggestion lookup should just show no suggestions, not crash
/// the text field someone is actively typing into.
///
/// Falls back to the on-device SQLite Offline Transit Pack if the network
/// or backend API is unreachable.
Future<List<PlaceSuggestion>> searchPlaces(String query) async {
  if (query.trim().length < 2) return [];

  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/stops/search')
      .replace(queryParameters: {'q': query, 'limit': '10'});

  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      return await _offlineTransitPack.searchPlaces(query);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['stops'] as List)
        .map((s) => PlaceSuggestion.fromJson(s as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return await _offlineTransitPack.searchPlaces(query);
  }
}

/// One service hour's cheapest journey, or "no usable data for this hour"
/// (`totalMinutes == null`) - Delhi buses run roughly 05:00-23:00, and
/// outside that window there isn't enough recorded traffic to plan
/// honestly (see api/src/journey.ts SERVICE_HOURS_START/END).
class HourlyJourney {
  final int hourOfDay;
  final double? totalMinutes;
  final String? routeSummary;
  final String? confidenceLevel; // 'high' | 'medium' | 'low', null if no data

  HourlyJourney({
    required this.hourOfDay,
    required this.totalMinutes,
    required this.routeSummary,
    required this.confidenceLevel,
  });

  factory HourlyJourney.fromJson(Map<String, dynamic> json) {
    return HourlyJourney(
      hourOfDay: json['hourOfDay'] as int,
      totalMinutes: json['bestTotalMinutes'] == null
          ? null
          : _asDouble(json['bestTotalMinutes']),
      routeSummary: json['bestRouteSummary'] as String?,
      confidenceLevel: json['confidence'] as String?,
    );
  }
}

/// One named hour ("best" or "worst") from a by-hour comparison.
class HourHighlight {
  final int hourOfDay;
  final double totalMinutes;

  HourHighlight({required this.hourOfDay, required this.totalMinutes});

  factory HourHighlight.fromJson(Map<String, dynamic> json) {
    return HourHighlight(
      hourOfDay: json['hourOfDay'] as int,
      totalMinutes: _asDouble(json['totalMinutes']),
    );
  }
}

/// The answer to "when should I travel?" - the same journey costed for
/// every service hour, so a traveller can see whether leaving now or
/// later is actually faster, rather than guessing.
class ByHourResult {
  final bool available;
  final String? unavailableReason;
  final String dayType;
  final HourHighlight? best;
  final HourHighlight? worst;
  final String advice;
  final List<HourlyJourney> hours;
  final List<String> caveats;

  ByHourResult({
    required this.available,
    this.unavailableReason,
    required this.dayType,
    this.best,
    this.worst,
    required this.advice,
    required this.hours,
    required this.caveats,
  });

  factory ByHourResult.fromJson(Map<String, dynamic> json) {
    final available = json['available'] as bool;
    if (!available) {
      return ByHourResult(
        available: false,
        unavailableReason: json['reason'] as String?,
        dayType: 'weekday',
        advice: '',
        hours: [],
        caveats: [],
      );
    }
    return ByHourResult(
      available: true,
      dayType: json['dayType'] as String,
      best: HourHighlight.fromJson(json['best'] as Map<String, dynamic>),
      worst: HourHighlight.fromJson(json['worst'] as Map<String, dynamic>),
      advice: json['advice'] as String,
      hours: (json['hours'] as List)
          .map((h) => HourlyJourney.fromJson(h as Map<String, dynamic>))
          .toList(),
      caveats: (json['caveats'] as List).map((c) => c as String).toList(),
    );
  }
}

/// Asks the backend to cost one journey across every service hour of a
/// weekday or weekend, so a traveller can pick a good time to leave.
Future<ByHourResult> fetchJourneyByHour({
  required double fromLat,
  required double fromLon,
  required double toLat,
  required double toLon,
  required String dayType,
}) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/journey/by-hour').replace(
    queryParameters: {
      'fromLat': fromLat.toString(),
      'fromLon': fromLon.toString(),
      'toLat': toLat.toString(),
      'toLon': toLon.toString(),
      'dayType': dayType,
    },
  );

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 15));
  } catch (_) {
    throw ApiUnreachableException(
      "Can't reach the API. Is the server running? "
      "($apiBaseUrl)",
    );
  }

  if (response.statusCode != 200 && response.statusCode != 422) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return ByHourResult.fromJson(body);
}

/// One route number found by searching, e.g. "764UP" - a real bus route,
/// not a physical place. Delhi lists direction as a suffix on the short
/// name (see api/src/server.ts on /routes/search), so "764" and "764"
/// again with a different routeId are two legitimate, different results:
/// the same number, opposite directions.
class RouteSuggestion {
  final String routeId;
  final String routeShortName;
  final String routeDesc;

  RouteSuggestion({
    required this.routeId,
    required this.routeShortName,
    required this.routeDesc,
  });

  factory RouteSuggestion.fromJson(Map<String, dynamic> json) {
    return RouteSuggestion(
      routeId: json['route_id'] as String,
      routeShortName: json['route_short_name'] as String,
      routeDesc: (json['route_desc'] as String?) ?? '',
    );
  }
}

/// Looks up routes by typed number, for the route-browsing screen. Returns
/// an empty list rather than throwing on a network hiccup - same reasoning
/// as [searchPlaces].
///
/// Falls back to the on-device SQLite Offline Transit Pack if the network
/// or backend API is unreachable.
Future<List<RouteSuggestion>> searchRoutes(String query) async {
  if (query.trim().isEmpty) return [];

  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/routes/search')
      .replace(queryParameters: {'q': query, 'limit': '15'});

  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      return await _offlineTransitPack.searchRoutes(query);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['routes'] as List)
        .map((r) => RouteSuggestion.fromJson(r as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return await _offlineTransitPack.searchRoutes(query);
  }
}

/// One stop along a route, in the order a bus on that route visits it.
class RouteStop {
  final int stopSequence;
  final String stopName;
  final double metresAlongRoute;

  /// Whether the hop INTO this stop was ever actually recorded.
  ///
  /// False means no bus was ever observed crossing from the previous stop
  /// to this one, so any estimate spanning it would be missing a leg and
  /// /eta will refuse. The screen uses this to say so BEFORE two stops are
  /// picked - see the comment on the query in api/src/server.ts for why
  /// this bites hardest at the first stop of a route.
  final bool hasTiming;
  final double? lat;
  final double? lon;

  RouteStop({
    required this.stopSequence,
    required this.stopName,
    required this.metresAlongRoute,
    required this.hasTiming,
    this.lat,
    this.lon,
  });

  factory RouteStop.fromJson(Map<String, dynamic> json) {
    return RouteStop(
      stopSequence: json['stop_sequence'] as int,
      stopName: _cleanName(json['stop_name'] as String),
      metresAlongRoute: _asDouble(json['metres_along_route']),
      // Defaults to true if an older server does not send the field, so a
      // version mismatch degrades to the previous behaviour (find out on
      // refusal) rather than marking every stop as having no data.
      hasTiming: json['has_timing'] as bool? ?? true,
      lat: json['lat'] != null ? _asDouble(json['lat']) : null,
      lon: json['lon'] != null ? _asDouble(json['lon']) : null,
    );
  }
}

/// Thrown when a route number was valid at search time but the stop list
/// can't be found - e.g. it dropped out of the static feed snapshot between
/// searching and tapping. Separate from [ApiUnreachableException] so the
/// screen can tell "the server is gone" apart from "this route is gone".
class RouteNotFoundException implements Exception {
  final String message;
  RouteNotFoundException(this.message);
  @override
  String toString() => message;
}

/// Fetches the ordered stop list for one route - turns "the stop I'm
/// standing at" into the position number `/eta` needs.
///
/// Falls back to the on-device SQLite Offline Transit Pack if the network
/// or backend API is unreachable.
Future<List<RouteStop>> fetchRouteStops(String routeId) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/routes/$routeId/stops');

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 4));
  } catch (_) {
    final offlineStops = await _offlineTransitPack.fetchRouteStops(routeId);
    if (offlineStops.isNotEmpty) return offlineStops;
    throw ApiUnreachableException(
      "Can't reach the backend and no offline cache available for this route.",
    );
  }

  if (response.statusCode == 404) {
    final offlineStops = await _offlineTransitPack.fetchRouteStops(routeId);
    if (offlineStops.isNotEmpty) return offlineStops;
    throw RouteNotFoundException('This route is not in the current feed.');
  }
  if (response.statusCode != 200) {
    final offlineStops = await _offlineTransitPack.fetchRouteStops(routeId);
    if (offlineStops.isNotEmpty) return offlineStops;
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['stops'] as List)
      .map((s) => RouteStop.fromJson(s as Map<String, dynamic>))
      .toList();
}

/// What the app is built on, counted from the database rather than
/// hardcoded here - see /stats in api/src/server.ts for why that matters.
class ProjectStats {
  final int routes;
  final int stops;
  final int routeSegments;
  final int stopPassages;
  final int vehiclesSeen;
  final int daysRecorded;
  final int weekdayErrorSeconds;
  final List<String> honesty;

  ProjectStats({
    required this.routes,
    required this.stops,
    required this.routeSegments,
    required this.stopPassages,
    required this.vehiclesSeen,
    required this.daysRecorded,
    required this.weekdayErrorSeconds,
    required this.honesty,
  });

  factory ProjectStats.fromJson(Map<String, dynamic> json) {
    final measured = json['measured'] as Map<String, dynamic>;
    final accuracy = json['accuracy'] as Map<String, dynamic>;
    return ProjectStats(
      routes: measured['routes'] as int,
      stops: measured['stops'] as int,
      routeSegments: measured['routeSegments'] as int,
      stopPassages: measured['stopPassages'] as int,
      vehiclesSeen: measured['vehiclesSeen'] as int,
      daysRecorded: measured['daysRecorded'] as int,
      weekdayErrorSeconds: accuracy['weekdayTwentyHopErrorSeconds'] as int,
      honesty: (json['honesty'] as List).map((h) => h as String).toList(),
    );
  }
}

/// Fetches the "what this is built on" figures for the home screen.
Future<ProjectStats> fetchStats() async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/stats');

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 10));
  } catch (_) {
    throw ApiUnreachableException(
      "Can't reach the API. Is the server running? "
      "($apiBaseUrl)",
    );
  }

  if (response.statusCode != 200) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  return ProjectStats.fromJson(
    jsonDecode(response.body) as Map<String, dynamic>,
  );
}

/// The honest arrival window for one stop - never a bare number. `text` is
/// already worded by the server (e.g. "7 min to 12 min", or "any moment, up
/// to 5 min" when the early end of the range would otherwise land in the
/// past) - see rangeForResponse in api/src/server.ts for why that floor is
/// applied server-side rather than left for every client to get right.
class EtaRange {
  final int earliestSeconds;
  final int latestSeconds;
  final String text;
  final bool couldBeArrivingNow;

  EtaRange({
    required this.earliestSeconds,
    required this.latestSeconds,
    required this.text,
    required this.couldBeArrivingNow,
  });

  factory EtaRange.fromJson(Map<String, dynamic> json) {
    return EtaRange(
      earliestSeconds: json['earliestSeconds'] as int,
      latestSeconds: json['latestSeconds'] as int,
      text: json['text'] as String,
      couldBeArrivingNow: json['couldBeArrivingNow'] as bool,
    );
  }
}

/// The answer to "if a bus on this route is at stop X now, when does it
/// reach stop Y" - the project's headline question, honestly scoped to what
/// the historical archive can support. This is NOT a live "arriving now"
/// answer - the recorder is stopped, so there is no live position to ask
/// about, and the server says so in [caveats] every time.
class EtaResult {
  final bool available;
  final String? unavailableReason;
  final int stopsAway;
  final String estimateText;
  final EtaRange range;
  final Confidence confidence;
  final List<String> caveats;

  EtaResult({
    required this.available,
    this.unavailableReason,
    required this.stopsAway,
    required this.estimateText,
    required this.range,
    required this.confidence,
    required this.caveats,
  });

  factory EtaResult.fromJson(Map<String, dynamic> json) {
    final available = json['available'] as bool;
    if (!available) {
      // Refused, not failed - e.g. the "to" stop is behind the bus, or the
      // legs have never been observed. There is no number to show, only
      // the reason, same pattern as JourneyResult/ByHourResult above.
      return EtaResult(
        available: false,
        unavailableReason: json['reason'] as String?,
        stopsAway: 0,
        estimateText: '',
        range: EtaRange(
          earliestSeconds: 0,
          latestSeconds: 0,
          text: '',
          couldBeArrivingNow: false,
        ),
        confidence: Confidence(level: '', because: ''),
        caveats: [],
      );
    }
    return EtaResult(
      available: true,
      stopsAway: json['stopsAway'] as int,
      estimateText:
          (json['estimate'] as Map<String, dynamic>)['text'] as String,
      range: EtaRange.fromJson(json['range'] as Map<String, dynamic>),
      confidence: Confidence.fromJson(
        json['confidence'] as Map<String, dynamic>,
      ),
      caveats: (json['caveats'] as List).map((c) => c as String).toList(),
    );
  }
}

/// Asks the backend: if a bus on route [routeId] is at stop position [from]
/// right now, when does it reach stop position [to]? Both positions are
/// `stop_sequence` numbers from [fetchRouteStops] - not stop_ids - because
/// that is what /eta expects (see api/src/server.ts).
Future<EtaResult> fetchEta({
  required String routeId,
  required int from,
  required int to,
}) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/eta').replace(
    queryParameters: {
      'route': routeId,
      'from': from.toString(),
      'to': to.toString(),
    },
  );

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 15));
  } catch (_) {
    throw ApiUnreachableException(
      "Can't reach the API. Is the server running? "
      "($apiBaseUrl)",
    );
  }

  // 200 = an estimate was found, 422 = the server honestly refused (e.g.
  // "to" is behind "from"). Both are valid JSON to parse, same as /journey.
  if (response.statusCode != 200 && response.statusCode != 422) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return EtaResult.fromJson(body);
}

/// Asks the backend to plan a journey between two points.
///
/// Coordinates in, ranked travel options out. See api/src/journey.ts for
/// how the ranking and the confidence labels are actually worked out.
Future<JourneyResult> fetchJourney({
  required double fromLat,
  required double fromLon,
  required double toLat,
  required double toLon,
}) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/journey').replace(
    queryParameters: {
      'fromLat': fromLat.toString(),
      'fromLon': fromLon.toString(),
      'toLat': toLat.toString(),
      'toLon': toLon.toString(),
    },
  );

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 15));
  } catch (_) {
    // Covers both "no network" and "the tunnel/server isn't there" -
    // the phone can't tell the difference, so neither can we.
    throw ApiUnreachableException(
      "Can't reach the API. Is the server running? "
      "($apiBaseUrl)",
    );
  }

  // 200 = found options, 422 = server honestly found none. Both are valid
  // JSON answers to parse. Anything else is a real failure.
  if (response.statusCode != 200 && response.statusCode != 422) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return JourneyResult.fromJson(body);
}

/// A crowdsourced vehicle imputed from mobile passenger beacons.
class CrowdsourcedVehicleClient {
  final String routeId;
  final double lat;
  final double lon;
  final double speedKmh;
  final String lastUpdated;
  final int activePassengerCount;
  final String confidence; // 'high' | 'medium'
  final String description;

  const CrowdsourcedVehicleClient({
    required this.routeId,
    required this.lat,
    required this.lon,
    required this.speedKmh,
    required this.lastUpdated,
    required this.activePassengerCount,
    required this.confidence,
    required this.description,
  });

  factory CrowdsourcedVehicleClient.fromJson(Map<String, dynamic> json) {
    return CrowdsourcedVehicleClient(
      routeId: json['routeId'] as String,
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      speedKmh: _asDouble(json['speedKmh']),
      lastUpdated: json['lastUpdated'] as String,
      activePassengerCount: json['activePassengerCount'] as int? ?? 1,
      confidence: json['confidence'] as String? ?? 'medium',
      description: json['description'] as String? ?? 'Passenger reported',
    );
  }
}

/// Fetches active crowdsourced vehicles along a route.
Future<List<CrowdsourcedVehicleClient>> fetchCrowdsourcedVehicles(
  String routeId,
) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/routes/$routeId/crowdsourced');
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return [];
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final list = body['vehicles'] as List? ?? [];
    return list
        .map(
          (v) => CrowdsourcedVehicleClient.fromJson(v as Map<String, dynamic>),
        )
        .toList();
  } catch (_) {
    return [];
  }
}

/// Broadcasts a single passenger mobile beacon to the backend plausibility engine.
Future<bool> sendPassengerBeacon({
  required String routeId,
  required double lat,
  required double lon,
  required double speedKmh,
  String? deviceId,
}) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/crowdsource/ping');
  try {
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'route_id': routeId,
            'lat': lat,
            'lon': lon,
            'speed': speedKmh,
            'device_id': deviceId,
          }),
        )
        .timeout(const Duration(seconds: 4));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// The new arrivals layer
//
// The app opens on a stop board, so these models mirror the shape of
// GET /stops/:placeId/arrivals and GET /feed/status. Every arrival keeps
// its source and range; the screen is not allowed to show a bare number.
// ---------------------------------------------------------------------------

/// One recorded day that can be replayed.
class FeedDay {
  final String day;
  final DateTime firstAt;
  final DateTime lastAt;

  FeedDay({required this.day, required this.firstAt, required this.lastAt});

  factory FeedDay.fromJson(Map<String, dynamic> json) {
    return FeedDay(
      day: json['day'] as String,
      firstAt: DateTime.parse(json['firstAt'] as String),
      lastAt: DateTime.parse(json['lastAt'] as String),
    );
  }
}

/// Whether the official feed is live and which days can be replayed.
class TransitFeedStatus {
  final bool live;
  final String reason;
  final DateTime? newestNonEmptyFrameAt;
  final int? newestNonEmptyAgeSeconds;
  final List<FeedDay> replayDays;
  final List<String> rawPositionDays;

  TransitFeedStatus({
    required this.live,
    required this.reason,
    required this.newestNonEmptyFrameAt,
    required this.newestNonEmptyAgeSeconds,
    required this.replayDays,
    required this.rawPositionDays,
  });

  factory TransitFeedStatus.fromJson(Map<String, dynamic> json) {
    return TransitFeedStatus(
      live: json['live'] as bool? ?? false,
      reason: json['reason'] as String? ?? 'Official feed status is unknown.',
      newestNonEmptyFrameAt: json['newestNonEmptyFrameAt'] == null
          ? null
          : DateTime.parse(json['newestNonEmptyFrameAt'] as String),
      newestNonEmptyAgeSeconds: json['newestNonEmptyAgeSeconds'] as int?,
      replayDays: (json['replayDays'] as List? ?? [])
          .map((day) => FeedDay.fromJson(day as Map<String, dynamic>))
          .toList(),
      rawPositionDays: (json['rawPositionDays'] as List? ?? [])
          .map((day) => (day as Map<String, dynamic>)['day'] as String)
          .toList(),
    );
  }

  static TransitFeedStatus offline(String reason) => TransitFeedStatus(
    live: false,
    reason: reason,
    newestNonEmptyFrameAt: null,
    newestNonEmptyAgeSeconds: null,
    replayDays: const [],
    rawPositionDays: const [],
  );
}

/// A physical stop, deduplicated from Delhi's per-direction stop_ids.
class NearbyStop {
  final int placeId;
  final String name;
  final double lat;
  final double lon;
  final int metresAway;

  NearbyStop({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.metresAway,
  });

  factory NearbyStop.fromJson(Map<String, dynamic> json) {
    return NearbyStop(
      placeId: json['place_id'] as int,
      name: _cleanName(json['stop_name'] as String),
      lat: json['lat'] == null ? 0 : _asDouble(json['lat']),
      lon: json['lon'] == null ? 0 : _asDouble(json['lon']),
      metresAway: (json['metres_away'] as num?)?.toInt() ?? 0,
    );
  }

  PlaceSuggestion toPlace() =>
      PlaceSuggestion(stopName: name, lat: lat, lon: lon, placeId: placeId);
}

/// One bus on the board, with its range, source and matched position.
class BusArrival {
  final String routeId;
  final String routeNumber;
  final String routeShortName;
  final String destination;
  final String vehicleId;
  final String source; // official | passenger | replay
  final bool stale;
  final int currentStopSequence;
  final int? targetStopSequence;
  final int? stopsAway;
  final double progressM;
  final double progressFraction;
  final double routeLengthM;
  final DateTime recordedAt;
  final DateTime lastSeen;
  final int? etaSeconds;
  final String? etaText;
  final DateTime? etaAt;
  final int? rangeLowSeconds;
  final int? rangeHighSeconds;
  final String? rangeText;
  final String? confidenceLevel;
  final String? confidenceBecause;
  final double? snappedLat;
  final double? snappedLon;
  final int? offsetM;
  final String? unavailableReason;

  BusArrival({
    required this.routeId,
    required this.routeNumber,
    required this.routeShortName,
    required this.destination,
    required this.vehicleId,
    required this.source,
    required this.stale,
    required this.currentStopSequence,
    required this.targetStopSequence,
    required this.stopsAway,
    required this.progressM,
    required this.progressFraction,
    required this.routeLengthM,
    required this.recordedAt,
    required this.lastSeen,
    required this.etaSeconds,
    required this.etaText,
    required this.etaAt,
    required this.rangeLowSeconds,
    required this.rangeHighSeconds,
    required this.rangeText,
    required this.confidenceLevel,
    required this.confidenceBecause,
    required this.snappedLat,
    required this.snappedLon,
    required this.offsetM,
    required this.unavailableReason,
  });

  factory BusArrival.fromJson(Map<String, dynamic> json) {
    final eta = json['eta'] as Map<String, dynamic>?;
    final range = json['range'] as Map<String, dynamic>?;
    final confidence = json['confidence'] as Map<String, dynamic>?;
    final match = json['match'] as Map<String, dynamic>?;
    return BusArrival(
      routeId: json['routeId'] as String,
      routeNumber: json['routeNumber'] as String,
      routeShortName: json['routeShortName'] as String,
      destination: _cleanName(json['destination'] as String),
      vehicleId: json['vehicleId'] as String,
      source: json['source'] as String,
      stale: json['stale'] as bool? ?? false,
      currentStopSequence: json['currentStopSequence'] as int,
      targetStopSequence: json['targetStopSequence'] as int?,
      stopsAway: json['stopsAway'] as int?,
      progressM: _asDouble(json['progressM']),
      progressFraction: _asDouble(json['progressFraction']),
      routeLengthM: _asDouble(json['routeLengthM']),
      recordedAt: DateTime.parse(json['recordedAt'] as String),
      lastSeen: DateTime.parse(json['lastSeen'] as String),
      etaSeconds: eta == null ? null : (eta['seconds'] as num).toInt(),
      etaText: eta?['text'] as String?,
      etaAt: eta?['at'] == null ? null : DateTime.parse(eta!['at'] as String),
      rangeLowSeconds: range == null
          ? null
          : (range['lowSeconds'] as num).toInt(),
      rangeHighSeconds: range == null
          ? null
          : (range['highSeconds'] as num).toInt(),
      rangeText: range?['text'] as String?,
      confidenceLevel: confidence?['level'] as String?,
      confidenceBecause: confidence?['because'] as String?,
      snappedLat: match?['snappedLat'] == null
          ? null
          : _asDouble(match!['snappedLat']),
      snappedLon: match?['snappedLon'] == null
          ? null
          : _asDouble(match!['snappedLon']),
      offsetM: match?['offsetM'] == null
          ? null
          : (match!['offsetM'] as num).toInt(),
      unavailableReason:
          (json['unavailable'] as Map<String, dynamic>?)?['reason'] as String?,
    );
  }

  bool get isAtStop => stopsAway == 0;
  bool get isLive => source == 'official' && !stale;
  bool get isPassenger => source == 'passenger';
  bool get isReplay => source == 'replay';
}

/// Observed frequency for a route with no tracked bus.
class BusFrequency {
  final String routeId;
  final String routeNumber;
  final String destination;
  final double headwayMinutes;
  final int daysSeen;

  BusFrequency({
    required this.routeId,
    required this.routeNumber,
    required this.destination,
    required this.headwayMinutes,
    required this.daysSeen,
  });

  factory BusFrequency.fromJson(Map<String, dynamic> json) {
    return BusFrequency(
      routeId: json['routeId'] as String,
      routeNumber: json['routeNumber'] as String,
      destination: _cleanName(json['destination'] as String),
      headwayMinutes: _asDouble(json['headwayMinutes']),
      daysSeen: (json['daysSeen'] as num).toInt(),
    );
  }
}

/// A place the board was filtered to: the destination the rider picked.
///
/// It carries the same four facts the server uses to work out which bus
/// reaches which stop - the place id, its name and its coordinates. The
/// coordinates are kept even though this screen does not draw them, so the
/// place can be handed on to other screens without another lookup.
class PlaceInfo {
  final int placeId;
  final String name;
  final double lat;
  final double lon;

  const PlaceInfo({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lon,
  });

  factory PlaceInfo.fromJson(Map<String, dynamic> json) {
    return PlaceInfo(
      placeId: (json['placeId'] as num?)?.toInt() ?? 0,
      name: _cleanName(json['name'] as String? ?? ''),
      lat: json['lat'] == null ? 0 : _asDouble(json['lat']),
      lon: json['lon'] == null ? 0 : _asDouble(json['lon']),
    );
  }
}

/// The full board for one stop.
class StopArrivals {
  final int placeId;
  final String placeName;
  final double lat;
  final double lon;
  final String mode; // live | replay
  final DateTime at;
  final bool feedLive;
  final String feedReason;
  final List<BusArrival> arrivals;
  final List<BusFrequency> frequency;
  final List<String> caveats;

  /// The destination the board was filtered to, or null when the board is
  /// unfiltered. An older server does not send this field at all, which is
  /// exactly the same as "no destination filter" - so null is truthful
  /// there, not a crash.
  final PlaceInfo? destination;

  /// True when the server looked for a direct bus to [destination] and
  /// found no route that reaches it after this boarding stop. The lists
  /// above are then empty on purpose: there is no row to show.
  final bool noDirect;

  StopArrivals({
    required this.placeId,
    required this.placeName,
    required this.lat,
    required this.lon,
    required this.mode,
    required this.at,
    required this.feedLive,
    required this.feedReason,
    required this.arrivals,
    required this.frequency,
    required this.caveats,
    this.destination,
    this.noDirect = false,
  });

  factory StopArrivals.fromJson(Map<String, dynamic> json) {
    final place = json['place'] as Map<String, dynamic>;
    final feed = json['feed'] as Map<String, dynamic>?;
    final destination = json['destination'] as Map<String, dynamic>?;
    return StopArrivals(
      placeId: place['placeId'] as int,
      placeName: _cleanName(place['name'] as String),
      lat: _asDouble(place['lat']),
      lon: _asDouble(place['lon']),
      mode: json['mode'] as String? ?? 'live',
      at: DateTime.parse(json['at'] as String),
      feedLive: feed?['live'] as bool? ?? false,
      feedReason: feed?['reason'] as String? ?? '',
      arrivals: (json['arrivals'] as List? ?? [])
          .map(
            (arrival) => BusArrival.fromJson(arrival as Map<String, dynamic>),
          )
          .toList(),
      frequency: (json['frequency'] as List? ?? [])
          .map((row) => BusFrequency.fromJson(row as Map<String, dynamic>))
          .toList(),
      caveats: (json['caveats'] as List? ?? []).cast<String>(),
      // Both new fields default safely, so a request against a server that
      // predates the destination filter behaves exactly as it did before.
      destination: destination == null ? null : PlaceInfo.fromJson(destination),
      noDirect: json['noDirect'] as bool? ?? false,
    );
  }

  bool get isReplay => mode == 'replay';
}

/// The official feed status. Throws if the server cannot be reached; the
/// caller decides whether to show an offline board instead.
Future<TransitFeedStatus> fetchTransitFeedStatus() async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/feed/status');
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ApiUnreachableException(
        'Feed status failed (HTTP ${response.statusCode}).',
      );
    }
    return TransitFeedStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  } on ApiUnreachableException {
    rethrow;
  } catch (_) {
    throw ApiUnreachableException("Can't reach the backend for feed status.");
  }
}

/// Stops near a point, one row per physical place.
Future<List<NearbyStop>> fetchNearbyStops({
  required double lat,
  required double lon,
  int radiusMetres = 800,
}) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl/stops/near').replace(
    queryParameters: {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'radius': radiusMetres.toString(),
    },
  );
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return [];
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['stops'] as List? ?? [])
        .map((stop) => NearbyStop.fromJson(stop as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

/// Buses coming to one stop. `at` turns the request into a replay of that
/// recorded moment; null asks for now.
///
/// `toPlaceId` adds the destination filter: the server then answers "when
/// does a bus from this stop reach that place", with `noDirect` set when no
/// single route runs between the two. Leaving it null asks the original
/// question - every bus arriving here - so nothing changes for old callers.
Future<StopArrivals> fetchStopArrivals({
  required int placeId,
  DateTime? at,
  int? toPlaceId,
}) async {
  await getApiBaseUrl();
  final params = <String, String>{'windowMinutes': '45'};
  if (at != null) params['at'] = at.toUtc().toIso8601String();
  if (toPlaceId != null) params['to'] = toPlaceId.toString();

  final uri = Uri.parse('$apiBaseUrl/stops/$placeId/arrivals')
      .replace(queryParameters: params);

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 10));
  } catch (_) {
    throw ApiUnreachableException("Can't reach the backend for arrivals.");
  }

  if (response.statusCode == 404) {
    throw ApiUnreachableException('This stop is not in the current feed.');
  }
  if (response.statusCode != 200) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  return StopArrivals.fromJson(
    jsonDecode(response.body) as Map<String, dynamic>,
  );
}

// ---------------------------------------------------------------------------
// Route detail
// ---------------------------------------------------------------------------

class RouteShapePointInfo {
  final double lat;
  final double lon;
  final double distM;

  RouteShapePointInfo({
    required this.lat,
    required this.lon,
    required this.distM,
  });

  factory RouteShapePointInfo.fromJson(Map<String, dynamic> json) {
    return RouteShapePointInfo(
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      distM: _asDouble(json['distM']),
    );
  }
}

class RouteStopInfo {
  final int stopSequence;
  final String stopName;
  final double? lat;
  final double? lon;
  final double metresAlongRoute;
  final bool hasTiming;

  RouteStopInfo({
    required this.stopSequence,
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.metresAlongRoute,
    required this.hasTiming,
  });

  factory RouteStopInfo.fromJson(Map<String, dynamic> json) {
    return RouteStopInfo(
      stopSequence: json['stopSequence'] as int,
      stopName: _cleanName(json['stopName'] as String),
      lat: json['lat'] == null ? null : _asDouble(json['lat']),
      lon: json['lon'] == null ? null : _asDouble(json['lon']),
      metresAlongRoute: _asDouble(json['metresAlongRoute']),
      hasTiming: json['hasTiming'] as bool? ?? true,
    );
  }

  NearbyStop asNearbyStop() => NearbyStop(
    placeId: stopSequence,
    name: stopName,
    lat: lat ?? 0,
    lon: lon ?? 0,
    metresAway: 0,
  );
}

class RouteInfo {
  final String routeId;
  final String routeNumber;
  final String routeShortName;
  final String routeDesc;
  final String destination;

  RouteInfo({
    required this.routeId,
    required this.routeNumber,
    required this.routeShortName,
    required this.routeDesc,
    required this.destination,
  });

  factory RouteInfo.fromJson(Map<String, dynamic> json) {
    return RouteInfo(
      routeId: json['routeId'] as String,
      routeNumber: json['routeNumber'] as String,
      routeShortName: json['routeShortName'] as String,
      routeDesc: json['routeDesc'] as String? ?? '',
      destination: _cleanName(json['destination'] as String? ?? ''),
    );
  }
}

class RouteDetailInfo {
  final RouteInfo route;
  final List<RouteShapePointInfo> shape;
  final List<RouteStopInfo> stops;
  final List<BusArrival> runs;
  final BusFrequency? frequency;
  final int? targetStopSequence;
  final String mode;
  final DateTime at;
  final bool feedLive;
  final String feedReason;
  final String? firstDeparture;
  final String? lastDeparture;
  final List<String> caveats;

  RouteDetailInfo({
    required this.route,
    required this.shape,
    required this.stops,
    required this.runs,
    required this.frequency,
    required this.targetStopSequence,
    required this.mode,
    required this.at,
    required this.feedLive,
    required this.feedReason,
    required this.firstDeparture,
    required this.lastDeparture,
    required this.caveats,
  });

  factory RouteDetailInfo.fromJson(Map<String, dynamic> json) {
    final shape = json['shape'] as Map<String, dynamic>?;
    final feed = json['feed'] as Map<String, dynamic>?;
    return RouteDetailInfo(
      route: RouteInfo.fromJson(json['route'] as Map<String, dynamic>),
      shape: (shape?['points'] as List? ?? [])
          .map(
            (point) =>
                RouteShapePointInfo.fromJson(point as Map<String, dynamic>),
          )
          .toList(),
      stops: (json['stops'] as List? ?? [])
          .map((stop) => RouteStopInfo.fromJson(stop as Map<String, dynamic>))
          .toList(),
      runs: (json['runs'] as List? ?? [])
          .map((run) => BusArrival.fromJson(run as Map<String, dynamic>))
          .toList(),
      frequency: json['frequency'] == null
          ? null
          : BusFrequency.fromJson(json['frequency'] as Map<String, dynamic>),
      targetStopSequence: json['targetStopSequence'] as int?,
      mode: json['mode'] as String? ?? 'live',
      at: DateTime.parse(json['at'] as String),
      feedLive: feed?['live'] as bool? ?? false,
      feedReason: feed?['reason'] as String? ?? '',
      firstDeparture: json['firstDeparture'] as String?,
      lastDeparture: json['lastDeparture'] as String?,
      caveats: (json['caveats'] as List? ?? []).cast<String>(),
    );
  }

  RouteStopInfo? stopBySequence(int sequence) {
    for (final stop in stops) {
      if (stop.stopSequence == sequence) return stop;
    }
    return null;
  }

  /// Which way the route points at this distance, in compass degrees
  /// (0 = north, 90 = east), or null when there is no shape to read.
  ///
  /// The feed carries no bearing for a bus, so it has to come from the route
  /// geometry. Two points about 30 m apart on either side of the bus are used
  /// instead of one tiny segment: GTFS shape points sit close together and a
  /// single short segment can zig-zag at a junction. A window gives the same
  /// steady answer a sat-nav arrow would show.
  double? bearingAtDistance(double distanceM) {
    if (shape.length < 2) return null;

    final behind = pointAtDistance(distanceM - 30);
    final ahead = pointAtDistance(distanceM + 30);
    if (behind != null && ahead != null) {
      final samePoint = behind.lat == ahead.lat && behind.lon == ahead.lon;
      if (!samePoint) {
        return bearingBetween(behind.lat, behind.lon, ahead.lat, ahead.lon);
      }
    }

    // At the very ends of the route the window can collapse onto one point.
    // Fall back to the segment the bus is actually on.
    for (var i = 1; i < shape.length; i++) {
      final previous = shape[i - 1];
      final current = shape[i];
      if (distanceM <= current.distM && current.distM > previous.distM) {
        return bearingBetween(
          previous.lat,
          previous.lon,
          current.lat,
          current.lon,
        );
      }
    }
    final last = shape.length - 1;
    return bearingBetween(
      shape[last - 1].lat,
      shape[last - 1].lon,
      shape[last].lat,
      shape[last].lon,
    );
  }

  /// The point a given distance along the route.
  ({double lat, double lon})? pointAtDistance(double distanceM) {
    if (shape.isEmpty) return null;
    if (distanceM <= shape.first.distM) {
      return (lat: shape.first.lat, lon: shape.first.lon);
    }
    for (var i = 1; i < shape.length; i++) {
      final previous = shape[i - 1];
      final current = shape[i];
      if (distanceM <= current.distM && current.distM > previous.distM) {
        final fraction =
            (distanceM - previous.distM) / (current.distM - previous.distM);
        return (
          lat: previous.lat + (current.lat - previous.lat) * fraction,
          lon: previous.lon + (current.lon - previous.lon) * fraction,
        );
      }
    }
    return (lat: shape.last.lat, lon: shape.last.lon);
  }
}

/// Everything the route screen needs, in one request.
Future<RouteDetailInfo> fetchRouteDetail({
  required String routeId,
  DateTime? at,
  int? toStopSequence,
}) async {
  await getApiBaseUrl();
  final params = <String, String>{};
  if (at != null) params['at'] = at.toUtc().toIso8601String();
  if (toStopSequence != null) params['to'] = toStopSequence.toString();

  final uri = Uri.parse('$apiBaseUrl/routes/$routeId/detail')
      .replace(queryParameters: params.isEmpty ? null : params);

  http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 10));
  } catch (_) {
    throw ApiUnreachableException("Can't reach the backend for this route.");
  }

  if (response.statusCode == 404) {
    throw ApiUnreachableException('This route is not in the current feed.');
  }
  if (response.statusCode != 200) {
    throw ApiUnreachableException(
      'Server error (HTTP ${response.statusCode}).',
    );
  }

  return RouteDetailInfo.fromJson(
    jsonDecode(response.body) as Map<String, dynamic>,
  );
}
