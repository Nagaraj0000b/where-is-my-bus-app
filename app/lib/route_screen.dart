// One route: its shape, its buses, its stops, and the next actions.
//
// The ribbon is the primary view. The map is optional. The next two buses
// sit above the fold.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'arrival_alarm_service.dart';
import 'arrival_widgets.dart';
import 'error_card.dart';
import 'favorites_store.dart';
import 'ride_screen.dart';
import 'route_ribbon.dart';
import 'route_utils.dart';
import 'theme.dart';
import 'transit_map.dart';

/// "12 Aug, 1:30 pm" - the recorded moment a screen is replaying.
///
/// One format, used by the replay banner here and (with the same pattern)
/// on the stop and ride screens, so a recorded moment is always worded the
/// same way across the app.
String _recordedMomentLabel(DateTime moment) {
  return DateFormat('d MMM, h:mm a').format(moment.toLocal());
}

class RouteScreen extends ConsumerStatefulWidget {
  final String routeId;
  final String routeNumber;
  final String destination;
  final int? targetStopSequence;
  final DateTime? at;
  final bool enableMapTiles;
  final LatLng? userLocation;
  final bool simulatedLocation;
  final String? locationLabel;

  const RouteScreen({
    super.key,
    required this.routeId,
    required this.routeNumber,
    required this.destination,
    this.targetStopSequence,
    this.at,
    this.enableMapTiles = true,
    this.userLocation,
    this.simulatedLocation = false,
    this.locationLabel,
  });

  @override
  ConsumerState<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends ConsumerState<RouteScreen> {
  RouteDetailInfo? _detail;
  String? _error;
  bool _loading = true;
  bool _showMap = false;
  late String _routeId;
  late String _routeNumber;
  int? _target;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _routeId = widget.routeId;
    _routeNumber = widget.routeNumber;
    _target = widget.targetStopSequence;
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_loading) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await fetchRouteDetail(
        routeId: _routeId,
        at: widget.at,
        toStopSequence: _target,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _routeNumber = detail.route.routeNumber;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _pickTarget(int sequence) {
    setState(() => _target = sequence);
    _load();
  }

  void _toggleDirection() {
    final opposite = oppositeRouteId(_routeId);
    if (opposite == null) return;
    setState(() {
      _routeId = opposite;
      _routeNumber = routeNumberFromId(opposite);
      _target = null;
      _detail = null;
    });
    _load();
  }

  void _openRide(RouteDetailInfo detail, BusArrival run) {
    final target = _target;
    if (target == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Tap your stop first.')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RideScreen(
          detail: detail,
          run: run,
          destinationSequence: target,
          enableMapTiles: widget.enableMapTiles,
          userLocation: widget.userLocation,
          simulatedLocation: widget.simulatedLocation,
          locationLabel: widget.locationLabel,
        ),
      ),
    );
  }

  void _setAlarm(RouteDetailInfo detail) {
    final target = _target;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tap your stop first, then set an alert.'),
        ),
      );
      return;
    }
    final stop = detail.stopBySequence(target);
    if (stop == null) return;
    ref
        .read(arrivalAlarmProvider.notifier)
        .setAlarm(
          routeId: detail.route.routeId,
          routeName: detail.route.routeNumber,
          targetStopName: stop.stopName,
          targetStopSequence: stop.stopSequence,
        );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Alert set for ${stop.stopName}.')));
  }

  Future<void> _share(RouteDetailInfo detail) async {
    final text =
        '${detail.route.routeNumber} towards ${detail.route.destination}'
        '${_target == null ? '' : ' · stop ${detail.stopBySequence(_target!)?.stopName ?? ''}'}'
        ' · Where Is My Bus';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Route copied to the clipboard.')),
    );
  }

  void _report(RouteDetailInfo detail) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Report a problem'),
              Text(
                '${detail.route.routeNumber} towards ${detail.route.destination}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final issue in const [
                'Wrong route or direction',
                'Stop missing or in the wrong place',
                'Bus not showing on the map',
                'Timetable or first/last looks wrong',
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.flag_outlined,
                    color: WimbColors.inkMuted,
                  ),
                  title: Text(issue),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Report noted on this phone.'),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final saved = ref.watch(favoritesProvider).hasRoute(_routeId);
    final canFlip = oppositeRouteId(_routeId) != null;

    // Which recorded moment this screen is replaying, if any. Either the
    // route was opened with a moment (from the board's replay), or the
    // server itself answered in replay mode - both mean "not live".
    DateTime? replayMoment = widget.at;
    if (replayMoment == null && detail != null && detail.mode == 'replay') {
      replayMoment = detail.at;
    }

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(
        title: Text(_routeNumber.toUpperCase()),
        actions: [
          if (canFlip)
            IconButton(
              onPressed: _toggleDirection,
              tooltip: 'Switch direction',
              icon: const Icon(Icons.swap_horiz),
            ),
          IconButton(
            onPressed: () => setState(() => _showMap = !_showMap),
            tooltip: _showMap ? 'Hide map' : 'Show map',
            icon: Icon(_showMap ? Icons.map_outlined : Icons.map),
          ),
        ],
      ),
      body: _loading && detail == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && detail == null
          ? ListView(
              padding: const EdgeInsets.all(WimbSpace.screen),
              children: [ErrorCard(message: _error!, onRetry: _load)],
            )
          : detail == null
          ? const SizedBox.shrink()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  WimbSpace.screen,
                  4,
                  WimbSpace.screen,
                  30,
                ),
                children: [
                  // Say up front which kind of moment this is. The
                  // recorder is normally stopped, so a route opened
                  // from Search or Saved can be "live mode" while
                  // there is no live feed at all - saying that here
                  // is the difference between an honest screen and
                  // one that looks broken.
                  if (replayMoment != null) ...[
                    InfoBanner(
                      icon: Icons.history,
                      color: WimbColors.statusHistorical,
                      text:
                          'Recorded buses · ${_recordedMomentLabel(replayMoment)} · not live',
                    ),
                    const SizedBox(height: 12),
                  ] else if (!detail.feedLive) ...[
                    const InfoBanner(
                      icon: Icons.info_outline,
                      color: WimbColors.statusOffline,
                      text:
                          'No live feed - no live bus position is available. '
                          'The Board tab replays recorded buses.',
                    ),
                    const SizedBox(height: 12),
                  ],
                  _Header(detail: detail),
                  const SizedBox(height: 12),
                  _NextBusCard(
                    detail: detail,
                    replay: replayMoment != null,
                    target: _target,
                    onTap: (run) => _openRide(detail, run),
                  ),
                  const SizedBox(height: 12),
                  RouteRibbon(
                    detail: detail,
                    targetStopSequence: _target,
                    onStopTap: _pickTarget,
                  ),
                  if (_showMap) ...[
                    const SizedBox(height: 10),
                    TransitMap(
                      height: 220,
                      center: _mapCentre(detail),
                      userLocation: widget.userLocation,
                      locationLabel: widget.locationLabel,
                      simulatedLocation: widget.simulatedLocation,
                      nearbyStops: detail.stops
                          .map((stop) => stop.asNearbyStop())
                          .toList(),
                      selectedStop: _target == null
                          ? null
                          : detail.stopBySequence(_target!)?.asNearbyStop(),
                      buses: _mapBuses(detail),
                      polyline: detail.shape
                          .map((point) => LatLng(point.lat, point.lon))
                          .toList(),
                      enableTiles: widget.enableMapTiles,
                      onStopTap: (stop) => _pickTarget(stop.placeId),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _ActionBar(
                    saved: saved,
                    hasTarget: _target != null,
                    onRide: detail.runs.isEmpty
                        ? null
                        : () => _openRide(detail, detail.runs.first),
                    onAlert: () => _setAlarm(detail),
                    onSave: () {
                      ref
                          .read(favoritesProvider.notifier)
                          .toggleRoute(
                            SavedRoute(
                              routeId: detail.route.routeId,
                              routeNumber: detail.route.routeNumber,
                              destination: detail.route.destination,
                            ),
                          );
                    },
                    onShare: () => _share(detail),
                    onReport: () => _report(detail),
                  ),
                  // Only while the rider has not picked a stop: a
                  // route opened from the destination-filtered board
                  // already has B set, so the hint would be telling
                  // them to do something they have done.
                  if (_target == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: InfoBanner(
                        icon: Icons.touch_app,
                        text: 'Tap your stop on the ribbon to see the ride and alert actions.',
                      ),
                    ),
                  const SizedBox(height: 18),
                  if (detail.runs.isNotEmpty) ...[
                    const SectionLabel('Buses on this route'),
                    for (final run in detail.runs)
                      ArrivalRow(
                        arrival: run,
                        onTap: () => _openRide(detail, run),
                      ),
                  ] else
                    _NoRunsBlock(detail: detail, replay: replayMoment != null),
                  const SizedBox(height: 16),
                  const SectionLabel('Stops'),
                  for (final stop in detail.stops)
                    _StopRow(
                      stop: stop,
                      isTarget: stop.stopSequence == _target,
                      isFirst:
                          stop.stopSequence == detail.stops.first.stopSequence,
                      isLast:
                          stop.stopSequence == detail.stops.last.stopSequence,
                      onTap: () => _pickTarget(stop.stopSequence),
                    ),
                  if (detail.caveats.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        detail.caveats.first,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  LatLng _mapCentre(RouteDetailInfo detail) {
    if (_target != null) {
      final stop = detail.stopBySequence(_target!);
      if (stop?.lat != null && stop?.lon != null) {
        return LatLng(stop!.lat!, stop.lon!);
      }
    }
    if (detail.shape.isNotEmpty) {
      final middle = detail.shape[detail.shape.length ~/ 2];
      return LatLng(middle.lat, middle.lon);
    }
    final first = detail.stops.first;
    return LatLng(first.lat ?? 28.6323, first.lon ?? 77.2165);
  }

  List<MapBus> _mapBuses(RouteDetailInfo detail) {
    final buses = <MapBus>[];
    for (final run in detail.runs) {
      final point = detail.pointAtDistance(run.progressM);
      if (point == null) continue;
      buses.add(
        MapBus(
          point: LatLng(point.lat, point.lon),
          routeNumber: run.routeNumber,
          source: run.source,
          // The feed has no bearing, so the arrow reads it off the shape.
          headingDeg: detail.bearingAtDistance(run.progressM),
          onTap: () => _openRide(detail, run),
        ),
      );
    }
    return buses;
  }
}

class _Header extends StatelessWidget {
  final RouteDetailInfo detail;

  const _Header({required this.detail});

  @override
  Widget build(BuildContext context) {
    final buses = detail.runs.map((run) => run.vehicleId).toSet().length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RouteBoard(
              routeName: detail.route.routeNumber,
              destination: detail.route.destination,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.route.destination,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    [
                      // The times below come from the published static
                      // timetable, not from observed running. Saying so
                      // stops them being read as live predictions.
                      if (detail.firstDeparture != null ||
                          detail.lastDeparture != null)
                        'Published timetable · First ${detail.firstDeparture ?? '—'} · Last ${detail.lastDeparture ?? '—'}',
                      if (detail.frequency != null)
                        'Every ${detail.frequency!.headwayMinutes.round()} min',
                      if (buses > 0)
                        '$buses ${buses == 1 ? 'bus' : 'buses'} on route',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The one-line "why is this route empty" headline.
///
/// Shared by the top card and the section block below it so the two cannot
/// disagree about which kind of moment the screen is showing.
String _noRunsHeadline(RouteDetailInfo detail, {required bool replay}) {
  if (replay) return 'No recorded bus at this moment.';
  if (!detail.feedLive) return 'No live bus tracked.';
  return 'No bus is tracked right now.';
}

/// What to show when this route has no bus to list.
///
/// Three different truths hide behind "no runs", and they must not be
/// worded the same way: a replay may simply have no bus recorded at that
/// moment, the live feed may be off, or the feed may be live and genuinely
/// have no tracked bus. The observed frequency row, when there is one, is
/// real data and stays below the explanation.
class _NoRunsBlock extends StatelessWidget {
  final RouteDetailInfo detail;

  /// True when the screen is showing a recorded moment.
  final bool replay;

  const _NoRunsBlock({required this.detail, required this.replay});

  @override
  Widget build(BuildContext context) {
    final String title;
    String? body;
    if (replay) {
      title = 'No recorded bus on this route at this moment';
      body =
          'The recorded replay for this time has no bus on this route. '
          'The timetable and stops below are still real data.';
    } else if (!detail.feedLive) {
      // Opened from Search or Saved while the recorder is stopped: "live
      // mode" but no live feed. Say that, instead of a bare "no bus".
      title = 'No live bus tracked';
      body =
          'The recorder is not running, so there is no live bus position '
          'for this route. The timetable and stops below are still real data.';
    } else {
      // The feed is live and simply has no bus on this route right now.
      title = 'No bus tracked';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title),
        if (body != null)
          Text(body, style: Theme.of(context).textTheme.bodySmall),
        if (detail.frequency != null) ...[
          const SizedBox(height: 10),
          FrequencyRow(frequency: detail.frequency!, onTap: null),
        ],
      ],
    );
  }
}

class _NextBusCard extends StatelessWidget {
  final RouteDetailInfo detail;

  /// True when the screen is showing a recorded moment, so the empty copy
  /// below does not claim to be talking about live buses.
  final bool replay;
  final int? target;
  final ValueChanged<BusArrival> onTap;

  const _NextBusCard({
    required this.detail,
    required this.replay,
    required this.target,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final runs = detail.runs.take(2).toList();
    if (runs.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.schedule, color: WimbColors.inkMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  detail.frequency != null
                      ? 'About every ${detail.frequency!.headwayMinutes.round()} min.'
                      : _noRunsHeadline(detail, replay: replay),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Next buses'),
            for (var i = 0; i < runs.length; i++) ...[
              InkWell(
                onTap: () => onTap(runs[i]),
                borderRadius: BorderRadius.circular(WimbRadius.field),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 46,
                        child: Text(
                          i == 0 ? 'NEXT' : 'THEN',
                          style: TextStyle(
                            fontSize: 9.5,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w700,
                            color: i == 0
                                ? WimbColors.dtcRed
                                : WimbColors.inkMuted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          runs[i].stopsAway == null
                              ? 'Position not available'
                              : '${runs[i].stopsAway} ${runs[i].stopsAway == 1 ? 'stop' : 'stops'}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      Text(
                        runs[i].rangeText ?? runs[i].etaText ?? '—',
                        style: const TextStyle(
                          fontFamily: WimbFonts.condensed,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          fontFeatures: WimbFonts.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (i == 0) const Divider(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final bool saved;
  final bool hasTarget;
  final VoidCallback? onRide;
  final VoidCallback onAlert;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onReport;

  const _ActionBar({
    required this.saved,
    required this.hasTarget,
    required this.onRide,
    required this.onAlert,
    required this.onSave,
    required this.onShare,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: onRide,
          icon: const Icon(Icons.directions_bus, size: 17),
          label: const Text('Ride'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onAlert,
          icon: const Icon(Icons.notifications_none, size: 17),
          label: Text(hasTarget ? 'Alert' : 'Set stop'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onSave,
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border, size: 17),
          label: Text(saved ? 'Saved' : 'Save'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.share_outlined, size: 17),
          label: const Text('Share'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onReport,
          icon: const Icon(Icons.flag_outlined, size: 17),
          label: const Text('Report'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
      ],
    );
  }
}

class _StopRow extends StatelessWidget {
  final RouteStopInfo stop;
  final bool isTarget;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _StopRow({
    required this.stop,
    required this.isTarget,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lineColor = isTarget ? WimbColors.dtcRed : WimbColors.hairline;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isTarget ? WimbColors.delhiGreenLight : null,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 26,
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        width: isTarget ? 3 : 2,
                        color: isFirst ? Colors.transparent : lineColor,
                      ),
                    ),
                    Container(
                      width: isTarget ? 14 : 10,
                      height: isTarget ? 14 : 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isTarget ? WimbColors.delhiGreen : Colors.white,
                        border: Border.all(
                          color: isTarget
                              ? WimbColors.delhiGreen
                              : WimbColors.dtcRed,
                          width: 2,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: isTarget ? 3 : 2,
                        color: isLast ? Colors.transparent : lineColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stopName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isTarget
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: stop.hasTiming
                              ? WimbColors.ink
                              : WimbColors.inkMuted,
                        ),
                      ),
                      if (isTarget)
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            'Your stop',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: WimbColors.delhiGreen,
                            ),
                          ),
                        )
                      else if (!stop.hasTiming)
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            'No timing data for the hop into this stop',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: WimbColors.inkMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
