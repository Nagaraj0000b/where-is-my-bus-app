// Web fallback for the on-device SQLite pack.
//
// Flutter web cannot open a bundled SQLite file. The app still works: search
// and route details fall through to the API, and the offline card explains
// that the pack is a mobile feature. This file keeps the web build free of
// `dart:io` and `sqflite`.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

class DirectBusOption {
  final String routeId;
  final String routeShortName;
  final String routeDesc;
  final int fromSequence;
  final int toSequence;
  final int stopsBetween;

  const DirectBusOption({
    required this.routeId,
    required this.routeShortName,
    required this.routeDesc,
    required this.fromSequence,
    required this.toSequence,
    required this.stopsBetween,
  });
}

class DirectDestinationSuggestion {
  final String stopName;
  final double lat;
  final double lon;
  final int directRoutesCount;
  final List<String> routeNames;

  const DirectDestinationSuggestion({
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.directRoutesCount,
    required this.routeNames,
  });

  PlaceSuggestion toPlaceSuggestion() =>
      PlaceSuggestion(stopName: stopName, lat: lat, lon: lon);
}

class OfflineTransitPack {
  static const String assetDbPath = 'assets/data/wimb_offline.db';

  Future<void> initialize({String? overrideDbPath}) async {}

  Future<List<PlaceSuggestion>> searchPlaces(
    String query, {
    int limit = 10,
  }) async => const [];

  Future<List<RouteSuggestion>> searchRoutes(
    String query, {
    int limit = 15,
  }) async => const [];

  Future<List<RouteStop>> fetchRouteStops(String routeId) async => const [];

  Future<List<DirectDestinationSuggestion>> findDirectDestinations(
    String fromStopName, {
    String query = '',
    int limit = 60,
  }) async => const [];

  Future<List<DirectBusOption>> findDirectBuses(
    String fromStopName,
    String toStopName,
  ) async => const [];

  Future<List<RouteSuggestion>> findRoutesAtStop(String stopName) async =>
      const [];

  Future<void> close() async {}
}

/// Web fallback provider. The on-device pack is a mobile feature.
final offlineTransitPackProvider = Provider<OfflineTransitPack>((ref) {
  final pack = OfflineTransitPack();
  ref.onDispose(() => pack.close());
  return pack;
});
