// The app's entry point and its shell.
//
// Three jobs, in order:
//
//   1. Apply the theme (see theme.dart - the Delhi bus identity).
//   2. Decide whether anyone is signed in, before showing anything.
//   3. Hold the four tabs once that is settled.
//
// Step 2 is why there is a splash screen at all. Checking the saved token
// means asking the server, which takes a moment; without the splash the
// app would flash the sign-in screen and then snatch it away from someone
// who was already signed in.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_client.dart';
import 'by_hour_screen.dart';
import 'home_screen.dart';
import 'journey_screen.dart';
import 'routes_screen.dart';
import 'sign_in_screen.dart';
import 'theme.dart';

// ProviderScope is Riverpod's requirement - it is what actually stores the
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
      theme: buildWimbTheme(),
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// Decides which of the three top-level states the app is in: still
/// working out who you are, not signed in, or ready to use.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.watch(authControllerProvider.notifier);

    return auth.when(
      loading: () => const _SplashScreen(),
      // A failure here means the token check itself broke - not that the
      // token was bad. The app still works without an account, so the
      // honest response is to carry on rather than block the whole app
      // behind an error nobody can act on.
      error: (_, _) => const HomeShell(),
      data: (user) {
        // Signed in, or deliberately chose not to be. Either way, in.
        if (user != null || controller.skippedSignIn) return const HomeShell();
        return const SignInScreen();
      },
    );
  }
}

/// Shown for the moment it takes to check the saved token. Branded rather
/// than a bare spinner, so the first thing the app ever shows still looks
/// like this app.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: WimbColors.dtcRed,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WimbWordmark(),
            SizedBox(height: 26),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// The four tabs, once the app is past the sign-in gate.
///
/// `IndexedStack` (rather than swapping the child) keeps each screen's own
/// state - a half-typed search, a picked place - alive when switching tabs
/// and back, instead of rebuilding it from scratch every time.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _openTab(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // Built here rather than in a `static const` list because the home
    // screen needs a callback into this state to switch tabs.
    final screens = [
      HomeScreen(onOpenTab: _openTab),
      const JourneyScreen(),
      const ByHourScreen(),
      const RoutesScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _openTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route_outlined),
            selectedIcon: Icon(Icons.alt_route),
            label: 'Journey',
          ),
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'When?',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_bus_outlined),
            selectedIcon: Icon(Icons.directions_bus_filled),
            label: 'Routes',
          ),
        ],
      ),
    );
  }
}
