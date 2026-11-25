// Ride mode: one job, do not miss the stop.
//
// The rider has already chosen the bus. This screen shows the next stop, the
// destination, progress, and the alight alert. It can also share the phone's
// foreground position so other riders can see the bus.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'arrival_alarm_service.dart';
import 'contribution_stats.dart';
import 'route_screen.dart';
import 'theme.dart';
import 'transit_map.dart';

class RideScreen extends ConsumerStatefulWidget {
  final RouteDetailInfo detail;
  final BusArrival run;
  final int? destinationSequence;
  final bool enableMapTiles;
  final LatLng? userLocation;
  final bool simulatedLocation;
  final String? locationLabel;

  const RideScreen({
    super.key,
    required this.detail,
    required this.run,
    this.destinationSequence,
    this.enableMapTiles = true,
    this.userLocation,
    this.simulatedLocation = false,
    this.locationLabel,
  });

  @override
  ConsumerState<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends ConsumerState<RideScreen> {
  late RouteDetailInfo _detail;
  late BusArrival _run;
  late int _destinationSequence;

  Timer? _poll;
  Timer? _beaconTimer;

  bool _sharing = false;
  bool _startingShare = false;
  bool _alarmArmed = false;
  int _pingsSent = 0;
  String? _shareError;
  LatLng? _userLocation;

  /// Which way the phone is pointing, in compass degrees. Only set while the
  /// phone is actually moving: a stationary GPS fix reports a meaningless
  /// heading, and an arrow pointing a made-up way is worse than none.
  double? _userHeading;
  StreamSubscription<Position>? _positionStream;

  /// True while the map fills the screen, navigation style, instead of
  /// sitting in the list as a card.
  bool _mapExpanded = false;

  final String _deviceId = 'rider-${DateTime.now().millisecondsSinceEpoch}';
  final DateFormat _clock = DateFormat('h:mm a');

  /// "12 Aug, 1:30 pm" - the recorded moment this ride is replaying. Same
  /// wording pattern as the board and route banners, so "recorded" always
  /// reads the same way.
  final DateFormat _recordedAt = DateFormat('d MMM, h:mm a');

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    _run = widget.run;
    _userLocation = widget.userLocation;
    _destinationSequence = _defaultDestination();
    if (_userLocation == null) _startLocation();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  /// Find the rider once, then keep following them.
  ///
  /// The first fix draws the "you" arrow straight away, and the stream after
  /// it is what makes the arrow turn as the phone (and the bus it is on)
  /// turns, and move between the 10 s bus polls. One permission check for
  /// both, so the phone is never asked twice.
  ///
  /// Every failure is swallowed: the map simply shows the bus without a
  /// rider arrow, which is still a useful map. That also keeps widget tests
  /// and screenshots from needing a location plugin.
  Future<void> _startLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      if (!mounted) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      // The rider may have left the ride while the permission sheet was up;
      // subscribing now would leave a GPS stream running with nothing using
      // it, because dispose() has already run.
      if (!mounted) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
          ),
        );
        _applyPosition(position);
      } catch (_) {
        // No single fix yet; the stream below may still deliver one.
      }
      if (!mounted) return;

      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
      _positionStream = Geolocator.getPositionStream(locationSettings: settings)
          .listen(_applyPosition, onError: (_) {});
    } catch (_) {
      // No location on this device: the map still shows the bus.
    }
  }

  /// Copy a GPS fix into the state the map draws.
  void _applyPosition(Position position) {
    if (!mounted) return;
    // Roughly 1.8 km/h. Below that, phones often report heading 0 (north)
    // because they cannot tell, so a heading is only trusted when moving.
    final moving = position.speed > 0.5;
    setState(() {
      _userLocation = LatLng(position.latitude, position.longitude);
      _userHeading = moving && position.heading >= 0 ? position.heading : null;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _beaconTimer?.cancel();
    _positionStream?.cancel();
    super.dispose();
  }

  int _defaultDestination() {
    final current = _run.currentStopSequence;
    final candidate = widget.destinationSequence;
    if (candidate != null &&
        candidate > current &&
        _detail.stops.any((s) => s.stopSequence == candidate)) {
      return candidate;
    }
    return _detail.stops.isEmpty ? current : _detail.stops.last.stopSequence;
  }

  RouteStopInfo? get _destination {
    for (final stop in _detail.stops) {
      if (stop.stopSequence == _destinationSequence) return stop;
    }
    return null;
  }

  RouteStopInfo? get _nextStop {
    final current = _run.currentStopSequence;
    final after = _detail.stops.where((s) => s.stopSequence > current).toList();
    if (after.isNotEmpty) return after.first;
    return _detail.stops.isEmpty ? null : _detail.stops.last;
  }

  Future<void> _refresh() async {
    try {
      final detail = await fetchRouteDetail(
        routeId: _detail.route.routeId,
        at: _detail.mode == 'replay' ? _detail.at : null,
        toStopSequence: _destinationSequence,
      );
      if (!mounted) return;
      final runs = detail.runs.where((r) => r.vehicleId == _run.vehicleId);
      setState(() {
        _detail = detail;
        if (runs.isNotEmpty) _run = runs.first;
      });
      _evaluateAlarm();
    } catch (_) {
      // Keep the last known position. The status line shows its age.
    }
  }

  void _evaluateAlarm() {
    if (!_alarmArmed) return;
    final dest = _destination;
    if (dest == null) return;
    final stops = dest.stopSequence - _run.currentStopSequence;
    ref
        .read(arrivalAlarmProvider.notifier)
        .evaluateProgress(
          currentStopSequence: _run.currentStopSequence,
          stopsRemaining: stops < 0 ? 0 : stops,
          estimatedSecondsRemaining: _run.etaSeconds,
        );
  }

  Future<void> _pickDestination() async {
    final current = _run.currentStopSequence;
    final stops = _detail.stops.where((s) => s.stopSequence > current).toList();
    if (stops.isEmpty) return;

    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          children: [
            const SectionLabel('Where are you getting off?'),
            for (final stop in stops)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  stop.stopSequence == _destinationSequence
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: stop.stopSequence == _destinationSequence
                      ? WimbColors.dtcRed
                      : WimbColors.inkFaint,
                ),
                title: Text(stop.stopName),
                subtitle: Text('Stop ${stop.stopSequence}'),
                onTap: () => Navigator.of(sheetContext).pop(stop.stopSequence),
              ),
          ],
        ),
      ),
    );

    if (picked == null) return;
    setState(() => _destinationSequence = picked);
    await _refresh();
    _armAlarm();
  }

  void _armAlarm() {
    final dest = _destination;
    if (dest == null) return;
    ref
        .read(arrivalAlarmProvider.notifier)
        .setAlarm(
          routeId: _detail.route.routeId,
          routeName: _detail.route.routeNumber,
          targetStopName: dest.stopName,
          targetStopSequence: dest.stopSequence,
          stopThreshold: 1,
          minuteThreshold: 5,
        );
    setState(() => _alarmArmed = true);
    _evaluateAlarm();
  }

  void _disarmAlarm() {
    ref.read(arrivalAlarmProvider.notifier).dismiss();
    setState(() => _alarmArmed = false);
  }

  Future<void> _toggleSharing() async {
    if (_sharing) {
      _stopSharing();
      return;
    }
    setState(() {
      _startingShare = true;
      _shareError = null;
    });
    try {
      final point = await _beaconPosition();
      final speed = await _speedKmh();
      final ok = await sendPassengerBeacon(
        routeId: _detail.route.routeId,
        lat: point.latitude,
        lon: point.longitude,
        speedKmh: speed,
        deviceId: _deviceId,
      );
      if (!ok) {
        throw Exception(
          'The server rejected this position. Check the phone location.',
        );
      }
      if (!mounted) return;
      setState(() => _sharing = true);
      await ref.read(contributionStatsProvider.notifier).recordUpdate();
      _pingsSent += 1;
      _beaconTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _sendTick(),
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _shareError = error.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      if (mounted) setState(() => _startingShare = false);
    }
  }

  Future<void> _sendTick() async {
    try {
      final point = await _beaconPosition();
      final speed = await _speedKmh();
      final ok = await sendPassengerBeacon(
        routeId: _detail.route.routeId,
        lat: point.latitude,
        lon: point.longitude,
        speedKmh: speed,
        deviceId: _deviceId,
      );
      if (!ok) return;
      if (!mounted) return;
      await ref.read(contributionStatsProvider.notifier).recordUpdate();
      setState(() => _pingsSent += 1);
    } catch (_) {
      _stopSharing();
    }
  }

  void _stopSharing() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (mounted) setState(() => _sharing = false);
  }

  Future<LatLng> _beaconPosition() async {
    if (_detail.mode == 'replay') {
      final point = _detail.pointAtDistance(_run.progressM);
      if (point == null) throw Exception('No recorded position for this bus.');
      return LatLng(point.lat, point.lon);
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Location is turned off.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Location permission was refused.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LatLng(position.latitude, position.longitude);
  }

  Future<double> _speedKmh() async {
    if (_detail.mode == 'replay') return 20;
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    final kmh = position.speed * 3.6;
    if (kmh.isNaN || kmh.isInfinite) return 0;
    return kmh.clamp(0, 80).toDouble();
  }

  Future<void> _finishRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this ride?'),
        content: const Text(
          'The alight alert will stop and location sharing will end.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep riding'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('End ride'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _close();
  }

  Future<void> _close() async {
    _stopSharing();
    _disarmAlarm();
    await ref.read(contributionStatsProvider.notifier).recordRide();
    if (mounted) Navigator.of(context).pop();
  }

  LatLng? get _busPoint {
    final point = _detail.pointAtDistance(_run.progressM);
    if (point != null) return LatLng(point.lat, point.lon);
    if (_run.snappedLat != null && _run.snappedLon != null) {
      return LatLng(_run.snappedLat!, _run.snappedLon!);
    }
    return null;
  }

  /// Where the rider's own marker should be drawn, if anywhere.
  ///
  /// On a ride the phone is on the bus, so a second arrow sitting under the
  /// bus arrow is pure clutter and two labels overlap. The rider marker is
  /// only worth drawing when the phone is clearly NOT on the bus yet - more
  /// than 250 m away - which is also the case where it tells you something.
  LatLng? _riderMarkerFor(LatLng busPoint) {
    final user = _userLocation;
    if (user == null) return null;
    final km = const Distance().as(LengthUnit.Kilometer, user, busPoint);
    return km > 0.25 ? user : null;
  }

  /// How far along the route the ride has got, 0..1.
  double get _progressFraction => _run.routeLengthM <= 0
      ? 0.0
      : (_run.progressM / _run.routeLengthM).clamp(0.0, 1.0);

  /// How old the bus position on screen is, in plain words.
  String get _positionAgeText {
    final seconds = DateTime.now().difference(_run.lastSeen).inSeconds;
    if (seconds < 90) return 'updated ${seconds < 0 ? 0 : seconds} s ago';
    final minutes = (seconds / 60).round();
    if (minutes < 90) return 'updated $minutes min ago';
    return 'updated ${(minutes / 60).round()} h ago';
  }

  /// True when the screen is replaying a recorded moment instead of live.
  bool get _isReplay => _detail.mode == 'replay';

  /// The colour of the tracking state dot: green for live, blue for a recorded
  /// replay, amber when the position has gone stale.
  Color get _trackingColor {
    if (_isReplay) return WimbColors.statusHistorical;
    if (_run.stale) return WimbColors.statusEstimated;
    return WimbColors.statusLive;
  }

  /// The first line of the tracking screen: what exactly is being tracked and
  /// how fresh it is. Never claims live when it is not.
  String get _trackingHeadline {
    if (_isReplay) {
      return 'Recorded buses · ${_recordedAt.format(_detail.at.toLocal())} · not live';
    }
    if (_run.stale) return 'Last known position · $_positionAgeText';
    return 'Live tracking · $_positionAgeText';
  }

  /// Opens the whole route with this ride's destination already highlighted.
  void _openFullRoute() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteScreen(
          routeId: _detail.route.routeId,
          routeNumber: _detail.route.routeNumber,
          destination: _detail.route.destination,
          targetStopSequence: _destinationSequence,
          at: _isReplay ? _detail.at : null,
          enableMapTiles: widget.enableMapTiles,
          userLocation: _userLocation,
          simulatedLocation: widget.simulatedLocation,
          locationLabel: widget.locationLabel,
        ),
      ),
    );
  }

  /// The ride map.
  ///
  /// The bus is an arrow pointing the way the route runs, and the map follows
  /// it - the ride screen's version of a navigation map. Between the 10 s
  /// position polls the bus slides along the route instead of jumping, the
  /// same way a map app moves smoothly rather than ticking.
  Widget _rideMap({required bool expanded}) {
    final route = _detail.route;
    final dest = _destination;

    // These only change when a poll brings new data, so build them once
    // outside the animation instead of on every one of its frames.
    final stops = _detail.stops.map((stop) => stop.asNearbyStop()).toList();
    final polyline = _detail.shape.map((p) => LatLng(p.lat, p.lon)).toList();
    final selectedStop = dest?.asNearbyStop();

    return TweenAnimationBuilder<double>(
      // The starting value is only used the first time. When a new poll
      // changes the end value, Flutter animates from where the bus is now.
      tween: Tween<double>(begin: _run.progressM, end: _run.progressM),
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeInOut,
      builder: (context, progressM, _) {
        final point = _detail.pointAtDistance(progressM);
        if (point == null) return const SizedBox.shrink();

        final busPoint = LatLng(point.lat, point.lon);
        final rider = _riderMarkerFor(busPoint);
        return TransitMap(
          height: expanded ? null : 240,
          borderRadius: expanded ? 0 : WimbRadius.card,
          initialZoom: expanded ? 15.6 : 15.0,
          center: busPoint,
          follow: true,
          userLocation: rider,
          userHeadingDeg: rider == null ? null : _userHeading,
          // Full screen has its own top bar; a location chip there would sit
          // under it. The chip also needs a rider marker to point at.
          locationLabel: expanded || rider == null
              ? null
              : (widget.locationLabel ?? 'You'),
          // The full-screen card covers the bottom-left corner, so the tile
          // credit moves up under the ride bar.
          showTileWarning: !expanded,
          attributionOnTop: expanded,
          simulatedLocation: widget.simulatedLocation,
          nearbyStops: stops,
          selectedStop: selectedStop,
          buses: [
            MapBus(
              point: busPoint,
              routeNumber: route.routeNumber,
              source: _run.source,
              headingDeg: _detail.bearingAtDistance(progressM),
            ),
          ],
          polyline: polyline,
          enableTiles: widget.enableMapTiles,
          onExpand: () => setState(() => _mapExpanded = !_mapExpanded),
          expanded: expanded,
        );
      },
    );
  }

  /// Full-screen version of the ride map: map first, one quiet bar on top and
  /// one card at the bottom, the way a navigation app lays it out.
  Widget _buildFullScreenMap() {
    final route = _detail.route;
    final dest = _destination;
    final next = _nextStop;

    return Stack(
      // The map is the screen: give the stack the whole body, then lay the
      // top bar and the bottom card over it.
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: _rideMap(expanded: true)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _MapOverlayButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Back to ride details',
                    onPressed: () => setState(() => _mapExpanded = false),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MapTopBar(
                      routeNumber: route.routeNumber,
                      destination: route.destination,
                      replay: _detail.mode == 'replay',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 14,
          child: SafeArea(
            top: false,
            child: _ExpandedRideCard(
              destinationName: dest?.stopName ?? 'Choose your stop',
              nextStopName: next?.stopName ?? 'Waiting for the next stop',
              etaLine: _run.etaText == null
                  ? 'No estimate'
                  : '${_run.rangeText ?? _run.etaText} · '
                        '${_run.stopsAway ?? '—'} '
                        '${_run.stopsAway == 1 ? 'stop' : 'stops'}',
              progress: _progressFraction,
              onPickStop: _pickDestination,
              onFinish: _finishRide,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dest = _destination;
    final next = _nextStop;
    final route = _detail.route;
    final busPoint = _busPoint;
    final progress = _progressFraction;
    final showYou = busPoint != null && _riderMarkerFor(busPoint) != null;

    return PopScope(
      canPop: !_mapExpanded,
      onPopInvokedWithResult: (didPop, _) {
        // Back closes the full-screen map first, then leaves the ride.
        if (!didPop && _mapExpanded) setState(() => _mapExpanded = false);
      },
      child: Scaffold(
        backgroundColor: WimbColors.cream,
        appBar: _mapExpanded
            ? null
            : AppBar(
                title: Text('Tracking ${route.routeNumber}'),
                leading: IconButton(
                  onPressed: _finishRide,
                  icon: const Icon(Icons.close),
                  tooltip: 'End ride',
                ),
                actions: [
                  IconButton(
                    tooltip: 'View full route',
                    onPressed: () => _openFullRoute(),
                    icon: const Icon(Icons.route_outlined),
                  ),
                ],
              ),
        body: _mapExpanded
            ? _buildFullScreenMap()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TrackingDot(
                        color: _trackingColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _trackingHeadline,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _trackingColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Towards ${route.destination}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: WimbColors.inkMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (busPoint != null) ...[
                    _rideMap(expanded: false),
                    const SizedBox(height: 8),
                    _MapLegend(
                      routeNumber: route.routeNumber,
                      showUser: showYou,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              RouteBoard(
                                routeName: route.routeNumber,
                                compact: true,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Next stop',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                              Text(
                                next == null
                                    ? '—'
                                    : 'Stop ${next.stopSequence}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: WimbColors.inkMuted,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            next?.stopName ?? 'Waiting for the next stop',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _run.stopsAway == null
                                ? 'Position not available'
                                : '${_run.stopsAway} ${_run.stopsAway == 1 ? 'stop' : 'stops'} to your stop',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: WimbColors.board,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'YOUR STOP',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 1.2,
                                    fontWeight: FontWeight.w700,
                                    color: WimbColors.boardText.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '${(progress * 100).round()}%',
                                style: TextStyle(
                                  fontFamily: WimbFonts.condensed,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: WimbColors.boardText.withValues(
                                    alpha: 0.75,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            dest?.stopName ?? 'Choose your stop',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: WimbFonts.condensed,
                              fontSize: 28,
                              height: 1.05,
                              fontWeight: FontWeight.w700,
                              color: WimbColors.boardText,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _run.etaText == null
                                ? 'No estimate'
                                : '${_run.rangeText ?? _run.etaText} · '
                                      '${_run.stopsAway ?? '—'} '
                                      '${_run.stopsAway == 1 ? 'stop' : 'stops'}',
                            style: TextStyle(
                              fontFamily: WimbFonts.condensed,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: WimbColors.boardText.withValues(
                                alpha: 0.86,
                              ),
                              fontFeatures: WimbFonts.tabular,
                            ),
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 8,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.12,
                              ),
                              valueColor: const AlwaysStoppedAnimation(
                                WimbColors.dtcRed,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickDestination,
                          icon: const Icon(Icons.flag_outlined, size: 18),
                          label: const Text('Change stop'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            backgroundColor: WimbColors.cardCream,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _alarmArmed ? _disarmAlarm : _armAlarm,
                          icon: Icon(
                            _alarmArmed
                                ? Icons.notifications_active
                                : Icons.notifications_none,
                            size: 18,
                          ),
                          label: Text(_alarmArmed ? 'Alert on' : 'Alert me'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            backgroundColor: WimbColors.cardCream,
                            foregroundColor: _alarmArmed
                                ? WimbColors.dtcRed
                                : WimbColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _sharing
                                    ? Icons.people_alt
                                    : Icons.people_alt_outlined,
                                size: 18,
                                color: _sharing
                                    ? WimbColors.statusRider
                                    : WimbColors.inkMuted,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _sharing
                                      ? 'Sharing this bus · $_pingsSent updates'
                                      : 'Help waiting riders see this bus',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _sharing
                                ? 'Your phone is sending its position while this screen is open. Stop any time.'
                                : 'Optional. Uses your location only while this screen is open.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_shareError != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _shareError!,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: WimbColors.dtcRed,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: _startingShare ? null : _toggleSharing,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(44),
                              foregroundColor: _sharing
                                  ? WimbColors.dtcRed
                                  : WimbColors.ink,
                            ),
                            child: Text(
                              _startingShare
                                  ? 'Starting…'
                                  : (_sharing
                                        ? 'Stop sharing'
                                        : 'Share this bus'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _finishRide,
                    child: const Text("I'm getting off"),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _clock.format(DateTime.now()),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _MapLegend extends StatelessWidget {
  final String routeNumber;
  final bool showUser;

  const _MapLegend({required this.routeNumber, required this.showUser});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showUser)
          const _LegendDot(color: WimbColors.delhiGreen, label: 'You'),
        _LegendRoute(routeNumber: routeNumber),
        const _LegendArrow(),
        const _LegendDot(
          color: Colors.white,
          label: 'Stop',
          border: WimbColors.inkFaint,
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final Color? border;

  const _LegendDot({required this.color, required this.label, this.border});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: border ?? Colors.white, width: 1.4),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, color: WimbColors.inkMuted),
        ),
      ],
    );
  }
}

class _LegendRoute extends StatelessWidget {
  final String routeNumber;

  const _LegendRoute({required this.routeNumber});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: WimbColors.board,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            routeNumber,
            style: const TextStyle(
              fontFamily: WimbFonts.condensed,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: WimbColors.boardText,
            ),
          ),
        ),
        const SizedBox(width: 5),
        const Text(
          'Bus',
          style: TextStyle(fontSize: 10.5, color: WimbColors.inkMuted),
        ),
      ],
    );
  }
}

/// A small arrow in the legend: the arrow on the map is the direction the
/// bus is travelling, not a decoration.
class _LegendArrow extends StatelessWidget {
  const _LegendArrow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.navigation, size: 11, color: WimbColors.inkMuted),
        SizedBox(width: 4),
        Text(
          'Arrow = direction',
          style: TextStyle(fontSize: 10.5, color: WimbColors.inkMuted),
        ),
      ],
    );
  }
}

/// A round white button sitting on top of the full-screen map.
class _MapOverlayButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MapOverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
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
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: WimbColors.ink),
          ),
        ),
      ),
    );
  }
}

/// The quiet bar at the top of the full-screen map: which bus, going where,
/// and - honestly - whether this is a recorded moment rather than live.
class _MapTopBar extends StatelessWidget {
  final String routeNumber;
  final String destination;
  final bool replay;

  const _MapTopBar({
    required this.routeNumber,
    required this.destination,
    required this.replay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
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
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: WimbColors.board,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              routeNumber,
              style: const TextStyle(
                fontFamily: WimbFonts.condensed,
                fontFamilyFallback: WimbFonts.fallback,
                fontSize: 13,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: WimbColors.boardText,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Towards $destination',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: WimbColors.ink,
              ),
            ),
          ),
          if (replay) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: WimbColors.statusEstimated.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(WimbRadius.pill),
              ),
              child: const Text(
                'RECORDED',
                style: TextStyle(
                  fontSize: 7.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: WimbColors.statusEstimated,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The bottom card on the full-screen map: your stop, what it will take to
/// get there, and the two things a rider might want to do without leaving
/// the map.
class _ExpandedRideCard extends StatelessWidget {
  final String destinationName;
  final String nextStopName;
  final String etaLine;
  final double progress;
  final VoidCallback onPickStop;
  final VoidCallback onFinish;

  const _ExpandedRideCard({
    required this.destinationName,
    required this.nextStopName,
    required this.etaLine,
    required this.progress,
    required this.onPickStop,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(WimbRadius.card),
        border: Border.all(color: WimbColors.hairline),
        boxShadow: const [
          BoxShadow(
            color: WimbColors.shadow,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (nextStopName == destinationName
                          ? 'YOUR STOP'
                          : 'NEXT STOP · $nextStopName')
                      .toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: WimbColors.inkMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  fontFamily: WimbFonts.condensed,
                  fontFamilyFallback: WimbFonts.fallback,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: WimbColors.inkMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            destinationName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 2),
          Text(etaLine, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: WimbColors.surfaceMuted,
              valueColor: const AlwaysStoppedAnimation(WimbColors.dtcRed),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPickStop,
                  icon: const Icon(Icons.flag_outlined, size: 16),
                  label: const Text('Change stop'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    backgroundColor: WimbColors.cardCream,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onFinish,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                  ),
                  child: const Text("I'm getting off"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// The small coloured dot that opens the tracking status line.
class _TrackingDot extends StatelessWidget {
  final Color color;

  const _TrackingDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 6),
        ],
      ),
    );
  }
}

