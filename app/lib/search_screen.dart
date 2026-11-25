import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'route_screen.dart';
import 'route_utils.dart';
import 'stop_screen.dart';
import 'theme.dart';

/// One search for routes and stops. The board's search icon opens this,
/// so a rider never has to know whether "2433" is a route or a stop.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  List<RouteSuggestion> _routes = const [];
  List<PlaceSuggestion> _stops = const [];
  bool _loading = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() => _query = value.trim());
    if (value.trim().isEmpty) {
      setState(() {
        _routes = const [];
        _stops = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final query = _query;
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        searchRoutes(query),
        searchPlaces(query),
      ]);
      if (!mounted || query != _query) return;
      setState(() {
        _routes = results[0] as List<RouteSuggestion>;
        _stops = results[1] as List<PlaceSuggestion>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || query != _query) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _openRoute(RouteSuggestion route) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteScreen(
          routeId: route.routeId,
          routeNumber: routeNumberFromId(route.routeId),
          destination: destinationOfRouteDesc(route.routeDesc),
        ),
      ),
    );
  }

  void _openStop(PlaceSuggestion stop) {
    final placeId = stop.placeId;
    if (placeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This stop has no detail in the feed.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StopScreen(placeId: placeId, stopName: stop.stopName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = _query.isNotEmpty;
    final hasResults = _routes.isNotEmpty || _stops.isNotEmpty;

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(
        toolbarHeight: 76,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Route, stop or place',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: hasQuery
                  ? IconButton(
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    )
                  : null,
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!hasQuery) ...[
            const SizedBox(height: 20),
            Text('Search', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 6),
            Text(
              'Try a route number, a stop name, or a place.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final example in const [
                  '2433',
                  'Shivaji Park',
                  'Nehru Place',
                ])
                  ActionChip(
                    label: Text(example),
                    onPressed: () {
                      _controller.text = example;
                      _onChanged(example);
                    },
                  ),
              ],
            ),
          ],
          if (hasQuery && !_loading && !hasResults && _error == null) ...[
            const SizedBox(height: 28),
            Icon(Icons.search_off, size: 30, color: WimbColors.inkFaint),
            const SizedBox(height: 10),
            Text(
              'No results for “$_query”',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Try the route number without UP/DOWN, or a shorter stop name.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_routes.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel('Routes'),
            for (final route in _routes)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  leading: RouteBoard(
                    routeName: routeNumberFromId(route.routeId),
                    compact: true,
                  ),
                  title: Text(
                    destinationOfRouteDesc(route.routeDesc),
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
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _openRoute(route),
                ),
              ),
          ],
          if (_stops.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel('Stops'),
            for (final stop in _stops)
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
                    stop.stopName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('Bus stop'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _openStop(stop),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
