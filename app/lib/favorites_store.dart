import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

class SavedRoute {
  final String routeId;
  final String routeNumber;
  final String destination;
  final String? accent;

  const SavedRoute({
    required this.routeId,
    required this.routeNumber,
    required this.destination,
    this.accent,
  });

  Map<String, dynamic> toJson() => {
    'routeId': routeId,
    'routeNumber': routeNumber,
    'destination': destination,
    'accent': accent,
  };

  factory SavedRoute.fromJson(Map<String, dynamic> json) => SavedRoute(
    routeId: json['routeId'] as String,
    routeNumber: json['routeNumber'] as String,
    destination: (json['destination'] as String?) ?? '',
    accent: json['accent'] as String?,
  );
}

class SavedStop {
  final int placeId;
  final String name;

  const SavedStop({required this.placeId, required this.name});

  Map<String, dynamic> toJson() => {'placeId': placeId, 'name': name};

  factory SavedStop.fromJson(Map<String, dynamic> json) =>
      SavedStop(placeId: json['placeId'] as int, name: json['name'] as String);
}

class FavoritesState {
  final List<SavedRoute> routes;
  final List<SavedStop> stops;

  const FavoritesState({this.routes = const [], this.stops = const []});

  bool hasRoute(String routeId) => routes.any((r) => r.routeId == routeId);
  bool hasStop(int placeId) => stops.any((s) => s.placeId == placeId);
}

class FavoritesController extends StateNotifier<FavoritesState> {
  FavoritesController() : super(const FavoritesState()) {
    _load();
  }

  static const _routesKey = 'wimb_saved_routes_v1';
  static const _stopsKey = 'wimb_saved_stops_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final routes = _decodeList(prefs.getString(_routesKey))
        .map(SavedRoute.fromJson)
        .toList(growable: false);
    final stops = _decodeList(prefs.getString(_stopsKey))
        .map(SavedStop.fromJson)
        .toList(growable: false);
    state = FavoritesState(routes: routes, stops: stops);
  }

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _routesKey,
      jsonEncode(state.routes.map((r) => r.toJson()).toList()),
    );
    await prefs.setString(
      _stopsKey,
      jsonEncode(state.stops.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> toggleRoute(SavedRoute route) async {
    final exists = state.hasRoute(route.routeId);
    state = FavoritesState(
      routes: exists
          ? state.routes.where((r) => r.routeId != route.routeId).toList()
          : [...state.routes, route],
      stops: state.stops,
    );
    await _persist();
  }

  Future<void> toggleStop(SavedStop stop) async {
    final exists = state.hasStop(stop.placeId);
    state = FavoritesState(
      routes: state.routes,
      stops: exists
          ? state.stops.where((s) => s.placeId != stop.placeId).toList()
          : [...state.stops, stop],
    );
    await _persist();
  }

  Future<void> removeRoute(String routeId) async {
    state = FavoritesState(
      routes: state.routes.where((r) => r.routeId != routeId).toList(),
      stops: state.stops,
    );
    await _persist();
  }

  Future<void> removeStop(int placeId) async {
    state = FavoritesState(
      routes: state.routes,
      stops: state.stops.where((s) => s.placeId != placeId).toList(),
    );
    await _persist();
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesController, FavoritesState>((ref) {
      return FavoritesController();
    });
