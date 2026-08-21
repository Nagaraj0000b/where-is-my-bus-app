import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'by_hour_screen.dart';
import 'journey_screen.dart';
import 'routes_screen.dart';

// The hello-world smoke test proved the phone, the SDK, and the build
// chain all work together. This now runs the real screens: the journey
// planner (see journey_screen.dart for why that one is first), route
// browsing (routes_screen.dart), and "when should I travel"
// (by_hour_screen.dart) - reachable from a bottom nav bar.
//
// ProviderScope is Riverpod's requirement - it's what actually stores the
// state behind every provider used anywhere in the app, so it has to sit
// above everything else.
void main() {
  runApp(const ProviderScope(child: WimbApp()));
}

class WimbApp extends StatelessWidget {
  const WimbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Where Is My Bus',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const HomeShell(),
    );
  }
}

/// Bottom-nav shell holding the app's top-level screens. `IndexedStack`
/// (not just swapping the child) keeps each screen's own state - a
/// half-typed search, a picked place - alive when switching tabs and back,
/// rather than rebuilding it from scratch every time.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _screens = [JourneyScreen(), ByHourScreen(), RoutesScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.directions), label: 'Journey'),
          NavigationDestination(icon: Icon(Icons.schedule), label: 'When?'),
          NavigationDestination(icon: Icon(Icons.route), label: 'Routes'),
        ],
      ),
    );
  }
}
