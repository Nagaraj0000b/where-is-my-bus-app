// A small map for the stop board and the ride screen.
//
// It is deliberately not the whole product. The board is the main thing; the
// map shows where the stop is, where the buses currently are, and - the way
// a navigation app does - which way each of them is pointing.
//
// It works without tiles: stops, buses and the route line still draw on a
// cream canvas, so an offline phone is not left with a blank rectangle.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'theme.dart';

/// One bus to draw.
class MapBus {
  final LatLng point;
  final String routeNumber;
  final String source; // official | passenger | replay

  /// Which way the bus is pointing, in compass degrees (0 = north,
  /// clockwise). null means "direction unknown", and the bus is drawn as a
  /// plain route-number label instead of an arrow.
  final double? headingDeg;

  final VoidCallback? onTap;

  const MapBus({
    required this.point,
    required this.routeNumber,
    required this.source,
    this.headingDeg,
    this.onTap,
  });
}

class TransitMap extends StatefulWidget {
  final LatLng center;
  final LatLng? userLocation;

  /// Which way the rider's own position is pointing, in compass degrees.
  /// null draws the familiar round "you are here" dot.
  final double? userHeadingDeg;

  final List<NearbyStop> nearbyStops;
  final NearbyStop? selectedStop;
  final List<MapBus> buses;
  final List<LatLng> polyline;

  /// Height of the card the map sits in. null means "fill the space the
  /// parent gives me" - used by the full-screen ride map.
  final double? height;

  final bool enableTiles;
  final ValueChanged<NearbyStop>? onStopTap;

  /// A short place name for the location chip, e.g. "Near Shivaji Stadium".
  final String? locationLabel;

  /// True when the position is a demo rather than the phone's real GPS.
  final bool simulatedLocation;

  /// Opens the demo-location chooser when the chip is tapped.
  final VoidCallback? onLocationTap;

  /// Keep the map centred on [center] as it changes. The ride screen turns
  /// this on, because a ride map should follow the bus.
  final bool follow;

  /// Zoom and re-centre buttons. On by default: a map you cannot zoom is a
  /// picture, not a map.
  final bool showControls;

  /// Shows the expand button. The callback decides what expanding means.
  final VoidCallback? onExpand;

  /// True while the map already fills the screen, so the button can offer
  /// "shrink" instead of "expand".
  final bool expanded;

  /// Corner rounding; 0 gives a full-bleed map.
  final double borderRadius;

  /// The "map tiles need a connection" line. The full-screen ride map turns
  /// it off, because its bottom card sits where the line goes.
  final bool showTileWarning;

  /// Put the OpenStreetMap credit at the top right instead of the bottom
  /// left. The full-screen ride card covers the bottom left, and the tiles
  /// licence asks for the credit to stay visible.
  final bool attributionOnTop;

  final double initialZoom;

  const TransitMap({
    super.key,
    required this.center,
    this.userLocation,
    this.userHeadingDeg,
    this.nearbyStops = const [],
    this.selectedStop,
    this.buses = const [],
    this.polyline = const [],
    this.height = 220,
    this.enableTiles = true,
    this.onStopTap,
    this.locationLabel,
    this.simulatedLocation = false,
    this.onLocationTap,
    this.follow = false,
    this.showControls = true,
    this.onExpand,
    this.expanded = false,
    this.borderRadius = WimbRadius.card,
    this.showTileWarning = true,
    this.attributionOnTop = false,
    this.initialZoom = 14.8,
  });

  @override
  State<TransitMap> createState() => _TransitMapState();
}

class _LocationChip extends StatelessWidget {
  final String label;
  final bool simulated;
  final VoidCallback? onTap;

  const _LocationChip({
    required this.label,
    required this.simulated,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 250),
        padding: const EdgeInsets.fromLTRB(8, 5, 7, 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(WimbRadius.pill),
          border: Border.all(color: WimbColors.hairline),
          boxShadow: const [
            BoxShadow(
              color: WimbColors.shadow,
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.my_location,
              size: 12,
              color: WimbColors.delhiGreen,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: WimbColors.ink,
                ),
              ),
            ),
            if (simulated) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: WimbColors.statusEstimated.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(WimbRadius.pill),
                ),
                child: const Text(
                  'DEMO',
                  style: TextStyle(
                    fontSize: 7.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: WimbColors.statusEstimated,
                  ),
                ),
              ),
            ],
            if (onTap != null) ...[
              const SizedBox(width: 3),
              const Icon(
                Icons.expand_more,
                size: 13,
                color: WimbColors.inkFaint,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransitMapState extends State<TransitMap> {
  final MapController _controller = MapController();
  late LatLng _lastCenter;
  late bool _following;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _lastCenter = widget.center;
    _following = widget.follow;
  }

  @override
  void didUpdateWidget(covariant TransitMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only move when the centre really changed. Re-centring on every poll
    // would fight someone who is panning the map to look around - and while
    // following, moving on every change is exactly what a ride map should do.
    final moved =
        widget.center.latitude != _lastCenter.latitude ||
        widget.center.longitude != _lastCenter.longitude;
    if (moved) {
      _lastCenter = widget.center;
      if (_following) _recentreAfterFrame();
    }
    if (widget.follow != oldWidget.follow) {
      _following = widget.follow;
      if (_following) _recentreAfterFrame();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Move the camera after the frame is painted: moving it during a build
  /// would not take effect.
  void _recentreAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      _controller.move(widget.center, _controller.camera.zoom);
    });
  }

  /// The rider tapped "centre on the bus": follow it again.
  void _recentreOnBus() {
    setState(() => _following = true);
    if (!_mapReady) return;
    _controller.move(widget.center, _controller.camera.zoom);
  }

  /// Zoom one step around the middle of the map. While following, keep the
  /// bus in the middle as the zoom changes.
  void _zoomBy(double change) {
    if (!_mapReady) return;
    final camera = _controller.camera;
    final zoom = (camera.zoom + change).clamp(4.0, 19.0);
    _controller.move(_following ? widget.center : camera.center, zoom);
  }

  /// The map gets a drag or pinch. If we were following the bus, stop: the
  /// rider is looking somewhere else on purpose, and pulling the camera back
  /// would be the annoying thing a bad map does.
  void _mapMoved(MapCamera camera, bool hasGesture) {
    if (hasGesture && _following) {
      setState(() => _following = false);
    }
  }

  /// The colour that says where a bus's position came from. The old label
  /// used a dot for this; the arrow now carries it as its colour.
  Color _sourceColor(String source) {
    if (source == 'passenger') return WimbColors.delhiGreen;
    if (source == 'replay') return WimbColors.statusEstimated;
    return WimbColors.dtcRed;
  }

  List<Marker> _markers() {
    final markers = <Marker>[];

    if (widget.userLocation != null) {
      markers.add(_userMarker());
    }

    for (final stop in widget.nearbyStops) {
      final selected = stop.placeId == widget.selectedStop?.placeId;
      markers.add(
        Marker(
          point: LatLng(stop.lat, stop.lon),
          width: selected ? 30 : 18,
          height: selected ? 30 : 18,
          child: GestureDetector(
            onTap: widget.onStopTap == null
                ? null
                : () => widget.onStopTap!(stop),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? WimbColors.delhiGreenLight : Colors.white,
                border: Border.all(
                  color: selected ? WimbColors.delhiGreen : WimbColors.dtcRed,
                  width: selected ? 3 : 2,
                ),
              ),
            ),
          ),
        ),
      );
    }

    for (final bus in widget.buses) {
      markers.add(_busMarker(bus));
    }

    return markers;
  }

  /// The rider's own position.
  ///
  /// With a heading this is a green arrow that turns as the phone turns, the
  /// way a navigation app shows you. Without one, it is the round dot: an
  /// arrow pointing a made-up direction would be worse than no arrow.
  Marker _userMarker() {
    final color = widget.simulatedLocation
        ? WimbColors.statusEstimated
        : WimbColors.delhiGreen;
    final label = widget.simulatedLocation ? 'DEMO' : 'YOU';
    final heading = widget.userHeadingDeg;

    return Marker(
      point: widget.userLocation!,
      width: 72,
      height: 76,
      rotate: true,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: _NameTag(label: label, color: color),
            ),
          ),
          if (heading == null)
            _PlainLocationDot(color: color)
          else
            _HeadingPuck(headingDeg: heading, color: color),
        ],
      ),
    );
  }

  /// One bus. With a heading it is an arrow; without one it stays the plain
  /// route-number label the stop board has always drawn.
  Marker _busMarker(MapBus bus) {
    final color = _sourceColor(bus.source);
    final heading = bus.headingDeg;

    if (heading == null) {
      return Marker(
        point: bus.point,
        width: 78,
        height: 34,
        child: GestureDetector(
          onTap: bus.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: WimbColors.board,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: color, width: 1.5),
              boxShadow: const [
                BoxShadow(color: WimbColors.shadow, blurRadius: 8),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  bus.routeNumber,
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: WimbFonts.condensed,
                    fontFamilyFallback: WimbFonts.fallback,
                    fontSize: 14,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: WimbColors.boardText,
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Marker(
      point: bus.point,
      width: 72,
      height: 76,
      // Only the arrow turns; the route tag stays upright so the number is
      // always readable. (rotate: true keeps the marker upright if the map
      // itself is ever rotated - map rotation is off today.)
      rotate: true,
      child: GestureDetector(
        onTap: bus.onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: _RouteTag(routeNumber: bus.routeNumber, color: color),
              ),
            ),
            _HeadingPuck(headingDeg: heading, color: color),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // On a real phone the full-screen map starts under the status bar, and
    // the ride bar sits in a SafeArea. The tile credit has to start below
    // that bar, so it needs the phone's own top inset added to its offset.
    final safeTop = MediaQuery.paddingOf(context).top;

    final map = Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: widget.initialZoom,
            // A cream base instead of the default grey, so an offline map
            // (or a screenshot) still looks like this app.
            backgroundColor: WimbColors.cream,
            keepAlive: true,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              _mapReady = true;
              if (_following) _recentreAfterFrame();
            },
            onPositionChanged: _mapMoved,
          ),
          children: [
            if (widget.enableTiles)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.wimb.delhi',
              ),
            if (widget.polyline.length > 1)
              PolylineLayer(
                polylines: [
                  // A white edge under the red line, the way a navigation
                  // map draws a road: the route stays readable over any tile.
                  Polyline(
                    points: widget.polyline,
                    strokeWidth: 7,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  Polyline(
                    points: widget.polyline,
                    strokeWidth: 4.5,
                    color: WimbColors.dtcRed,
                  ),
                ],
              ),
            MarkerLayer(markers: _markers()),
          ],
        ),
        if (widget.locationLabel != null)
          Positioned(
            left: 8,
            top: 8,
            child: _LocationChip(
              label: widget.locationLabel!,
              simulated: widget.simulatedLocation,
              onTap: widget.onLocationTap,
            ),
          ),
        if (!widget.enableTiles && widget.showTileWarning)
          // The same corner the OSM credit uses when tiles are on (in the
          // full-screen ride the credit moves up under the top bar instead).
          const Positioned(
            left: 8,
            bottom: 6,
            child: Text(
              'Map tiles need a connection',
              style: TextStyle(fontSize: 10, color: WimbColors.inkMuted),
            ),
          ),
        if (widget.enableTiles)
          Positioned(
            left: widget.attributionOnTop ? null : 8,
            right: widget.attributionOnTop ? 8 : null,
            top: widget.attributionOnTop ? safeTop + 56 : null,
            bottom: widget.attributionOnTop ? null : 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '© OpenStreetMap',
                style: TextStyle(fontSize: 9, color: WimbColors.inkMuted),
              ),
            ),
          ),
        if (widget.showControls)
          // Down the right-hand edge, vertically centred, so the buttons
          // never sit under the ride screen's bottom card or the board's
          // stop card. The map is the only thing they can overlap.
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onExpand != null)
                    _MapButton(
                      icon: widget.expanded
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      tooltip: widget.expanded
                          ? 'Back to ride details'
                          : 'Full-screen map',
                      onPressed: widget.onExpand!,
                    ),
                  _MapButton(
                    icon: Icons.my_location,
                    tooltip: _following
                        ? 'Following the bus'
                        : 'Centre the map',
                    active: _following,
                    onPressed: _recentreOnBus,
                  ),
                  _MapButton(
                    icon: Icons.add,
                    tooltip: 'Zoom in',
                    onPressed: () => _zoomBy(1),
                  ),
                  _MapButton(
                    icon: Icons.remove,
                    tooltip: 'Zoom out',
                    onPressed: () => _zoomBy(-1),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.height == null
          ? map
          : SizedBox(height: widget.height, child: map),
    );
  }
}

/// A small round map button: white, soft-edged, so the controls read as part
/// of the map instead of floating Material buttons on top of it.
class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;

  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: Colors.black26,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                icon,
                size: 17,
                color: active ? WimbColors.delhiGreen : WimbColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round white disc with a coloured arrow inside, turned to the direction
/// of travel - the map-app way of saying "this thing is moving that way".
class _HeadingPuck extends StatelessWidget {
  final double headingDeg;
  final Color color;

  const _HeadingPuck({required this.headingDeg, required this.color});

  @override
  Widget build(BuildContext context) {
    // One size for every arrow: the bus and the rider read the same way, and
    // the route tag above is the thing that tells them apart.
    const size = 40.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: color, width: 2),
        boxShadow: const [
          BoxShadow(
            color: WimbColors.shadow,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Transform.rotate(
          // Screen angles and compass bearings both count clockwise from up,
          // so the number can be used as-is (degrees -> radians).
          angle: headingDeg * math.pi / 180,
          child: Icon(Icons.navigation, size: size * 0.62, color: color),
        ),
      ),
    );
  }
}

/// The old round position marker, kept for when no heading is known.
class _PlainLocationDot extends StatelessWidget {
  final Color color;

  const _PlainLocationDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.20),
      ),
      child: Center(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: WimbColors.shadow, blurRadius: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// The route number sitting above a bus arrow.
class _RouteTag extends StatelessWidget {
  final String routeNumber;
  final Color color;

  const _RouteTag({required this.routeNumber, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: WimbColors.board,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
        boxShadow: const [BoxShadow(color: WimbColors.shadow, blurRadius: 6)],
      ),
      child: Text(
        routeNumber,
        maxLines: 1,
        style: const TextStyle(
          fontFamily: WimbFonts.condensed,
          fontFamilyFallback: WimbFonts.fallback,
          fontSize: 11,
          height: 1.05,
          fontWeight: FontWeight.w700,
          color: WimbColors.boardText,
        ),
      ),
    );
  }
}

/// A short coloured label above the rider's own arrow, matching the old
/// "YOU" / "DEMO" chip.
class _NameTag extends StatelessWidget {
  final String label;
  final Color color;

  const _NameTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
        boxShadow: const [BoxShadow(color: WimbColors.shadow, blurRadius: 6)],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
          color: Colors.white,
        ),
      ),
    );
  }
}
