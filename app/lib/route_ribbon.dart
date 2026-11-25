// The route as a horizontal line, not a map.
//
// A stop has a distance along the route; a bus has progress along the same
// route. Drawing them on one axis makes "the bus is between these two
// stops" obvious, and it works with no tiles and no live feed. The
// arrangement is borrowed from a clean timeline: fine ticks, sparse labels,
// one marker for the thing you are waiting at.

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'theme.dart';

class RouteRibbon extends StatelessWidget {
  final RouteDetailInfo detail;
  final int? targetStopSequence;
  final ValueChanged<int>? onStopTap;

  const RouteRibbon({
    super.key,
    required this.detail,
    this.targetStopSequence,
    this.onStopTap,
  });

  @override
  Widget build(BuildContext context) {
    final stops = detail.stops;
    if (stops.isEmpty) return const SizedBox.shrink();

    final length = detail.shape.isNotEmpty
        ? detail.shape.last.distM
        : stops.last.metresAlongRoute;
    final target = targetStopSequence == null
        ? null
        : detail.stopBySequence(targetStopSequence!);

    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 18.0;
        final width = constraints.maxWidth;
        double xFor(double distance) {
          if (length <= 0) return padding;
          final fraction = (distance / length).clamp(0.0, 1.0);
          return padding + (width - padding * 2) * fraction;
        }

        final busMarkers = <Widget>[];
        for (final run in detail.runs) {
          final x = xFor(run.progressM);
          busMarkers.add(
            Positioned(
              left: (x - 24).clamp(0.0, width - 48),
              top: 2,
              child: Container(
                width: 48,
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  color: WimbColors.board,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  run.routeNumber,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: WimbFonts.condensed,
                    fontFamilyFallback: WimbFonts.fallback,
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: WimbColors.boardText,
                  ),
                ),
              ),
            ),
          );
          busMarkers.add(
            Positioned(
              left: x - 1,
              top: 20,
              child: Container(width: 2, height: 32, color: WimbColors.dtcRed),
            ),
          );
        }

        final targetX = target == null ? null : xFor(target.metresAlongRoute);
        final first = stops.first;
        final last = stops.last;
        final targetIsFirst = target?.stopSequence == first.stopSequence;
        final targetIsLast = target?.stopSequence == last.stopSequence;

        return SizedBox(
          height: 96,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RibbonPainter(
                    width: width,
                    padding: padding,
                    length: length,
                    stops: stops,
                    targetX: targetX,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                bottom: 6,
                width: 100,
                child: Text(
                  first.stopName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: targetIsFirst
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: targetIsFirst
                        ? WimbColors.delhiGreen
                        : WimbColors.inkMuted,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 6,
                width: 100,
                child: Text(
                  last.stopName,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: targetIsLast
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: targetIsLast
                        ? WimbColors.delhiGreen
                        : WimbColors.inkMuted,
                  ),
                ),
              ),
              if (target != null && !targetIsFirst && !targetIsLast)
                Positioned(
                  left: (targetX! - 48).clamp(0.0, width - 96),
                  bottom: 6,
                  width: 96,
                  child: Text(
                    target.stopName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: WimbColors.delhiGreen,
                    ),
                  ),
                ),
              ...busMarkers,
              if (onStopTap != null)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (details) {
                      final tappedX = details.localPosition.dx;
                      int nearest = stops.first.stopSequence;
                      var nearestDistance = double.infinity;
                      for (final stop in stops) {
                        final distance = (xFor(stop.metresAlongRoute) - tappedX)
                            .abs();
                        if (distance < nearestDistance) {
                          nearestDistance = distance;
                          nearest = stop.stopSequence;
                        }
                      }
                      onStopTap!(nearest);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RibbonPainter extends CustomPainter {
  final double width;
  final double padding;
  final double length;
  final List<RouteStopInfo> stops;
  final double? targetX;

  _RibbonPainter({
    required this.width,
    required this.padding,
    required this.length,
    required this.stops,
    required this.targetX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const y = 52.0;
    final line = Paint()
      ..color = WimbColors.hairline
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(padding, y), Offset(width - padding, y), line);

    final tick = Paint()
      ..color = WimbColors.inkFaint
      ..strokeWidth = 1;
    for (final stop in stops) {
      final x =
          padding +
          (width - padding * 2) *
              (length <= 0
                  ? 0
                  : (stop.metresAlongRoute / length).clamp(0.0, 1.0));
      canvas.drawLine(Offset(x, y - 5), Offset(x, y + 5), tick);
    }

    final tx = targetX;
    if (tx != null) {
      final target = Paint()
        ..color = WimbColors.delhiGreen
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(tx, y - 10), Offset(tx, y + 10), target);
      canvas.drawCircle(
        Offset(tx, y),
        4,
        Paint()..color = WimbColors.delhiGreen,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RibbonPainter oldDelegate) {
    return oldDelegate.targetX != targetX ||
        oldDelegate.width != width ||
        oldDelegate.length != length;
  }
}
