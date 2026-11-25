import 'dart:math' as math;

/// Which way you are pointing when you go from one point to another.
///
/// Compass degrees, the way a compass or a sat-nav reads them: 0 = north,
/// 90 = east, 180 = south, 270 = west. Always inside 0..360.
///
/// The realtime feed does not send a bearing (Delhi leaves it out, and
/// hardcodes speed to 0), so the app works direction out from two points on
/// the route instead. That is the same thing a map app does when it shows
/// the little arrow on the road.
double bearingBetween(
  double fromLat,
  double fromLon,
  double toLat,
  double toLon,
) {
  // Work in radians, the units Latitude/Longitude maths naturally uses.
  final fromLatRad = fromLat * math.pi / 180;
  final toLatRad = toLat * math.pi / 180;
  final deltaLon = (toLon - fromLon) * math.pi / 180;

  // Standard "initial bearing" formula for a great circle between two
  // points. atan2 gives the angle clockwise from north.
  final y = math.sin(deltaLon) * math.cos(toLatRad);
  final x =
      math.cos(fromLatRad) * math.sin(toLatRad) -
      math.sin(fromLatRad) * math.cos(toLatRad) * math.cos(deltaLon);
  final degrees = math.atan2(y, x) * 180 / math.pi;

  // atan2 returns -180..180; a compass rose is 0..360.
  return (degrees + 360) % 360;
}

/// The opposite direction of a Delhi route id.
///
/// GTFS route ids carry the direction as an UP/DOWN suffix, e.g.
/// `764UP` / `764DOWN`. The API uses the full id, so flipping the suffix is
/// enough to fetch the other platform without a new endpoint.
String? oppositeRouteId(String routeId) {
  final upper = routeId.toUpperCase();
  if (upper.endsWith('UP')) {
    return '${routeId.substring(0, routeId.length - 2)}DOWN';
  }
  if (upper.endsWith('DOWN')) {
    return '${routeId.substring(0, routeId.length - 4)}UP';
  }
  return null;
}

/// The rider-facing number, with the direction suffix removed.
String routeNumberFromId(String routeId) {
  return routeId.replaceAll(RegExp(r'(UP|DOWN)$', caseSensitive: false), '');
}

/// "Nehru Place Terminal to Jharoda Kalan" -> "Jharoda Kalan".
String destinationOfRouteDesc(String routeDesc) {
  final parts = routeDesc.split(RegExp(r'\s+to\s+', caseSensitive: false));
  if (parts.length > 1) return parts.last.trim();
  return routeDesc.trim();
}
