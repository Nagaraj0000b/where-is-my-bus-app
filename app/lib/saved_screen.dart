import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'favorites_store.dart';
import 'route_screen.dart';
import 'stop_screen.dart';
import 'theme.dart';

/// The rider's saved routes and stops. This is the daily routine, not a
/// settings page; account and data status live in You.
class SavedScreen extends ConsumerWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    final controller = ref.read(favoritesProvider.notifier);
    final empty = favorites.routes.isEmpty && favorites.stops.isEmpty;

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(title: const Text('Saved')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Your daily stops and routes.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Tap the bookmark on a route or stop to keep it here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          if (empty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.bookmark_border,
                      color: WimbColors.inkMuted,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Nothing saved yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Open a route or a stop and tap Save. It will appear here, '
                      'one tap from the board.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          if (favorites.routes.isNotEmpty) ...[
            const SectionLabel('Routes'),
            for (final route in favorites.routes)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  leading: RouteBoard(
                    routeName: route.routeNumber,
                    compact: true,
                  ),
                  title: Text(
                    route.destination,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    route.routeId,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: WimbColors.inkFaint,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: () => controller.removeRoute(route.routeId),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RouteScreen(
                        routeId: route.routeId,
                        routeNumber: route.routeNumber,
                        destination: route.destination,
                      ),
                    ),
                  ),
                ),
              ),
          ],
          if (favorites.stops.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel('Stops'),
            for (final stop in favorites.stops)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  leading: const Icon(
                    Icons.place_outlined,
                    color: WimbColors.dtcRed,
                  ),
                  title: Text(
                    stop.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('Bus stop'),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: () => controller.removeStop(stop.placeId),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => StopScreen(
                        placeId: stop.placeId,
                        stopName: stop.name,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
