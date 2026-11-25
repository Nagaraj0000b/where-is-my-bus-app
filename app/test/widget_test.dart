// Smoke tests for the app shell.
//
// Deliberately small, and deliberately offline. No test here touches the
// API: the sign-in gate resolves to "nobody is signed in" without a
// network call, and the tests only check the shell and the simple login
// screen. Bus data is proved by api/check-*.ts, not here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wimb_app/main.dart';
import 'package:wimb_app/route_map_widget.dart';
import 'package:wimb_app/sign_in_screen.dart';

/// Secure storage is a plugin, and its real Android side does not exist in
/// a test. Answer it with "no saved token", which is the true state of a
/// fresh install anyway.
void mockEmptySecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'read':
            return null;
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
          default:
            return null;
        }
      });
}

Widget app() => const ProviderScope(child: WimbApp());

Future<void> bootToSignIn(WidgetTester tester) async {
  await tester.pumpWidget(app());

  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(SignInScreen).evaluate().isNotEmpty &&
        find.text('Continue without an account').evaluate().isNotEmpty) {
      return;
    }
  }

  fail('The sign-in screen never appeared - the auth gate did not resolve.');
}

Future<void> skipToTabs(WidgetTester tester) async {
  await bootToSignIn(tester);
  await tester.tap(find.text('Continue without an account'));

  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Board').evaluate().isNotEmpty &&
        find.text('Saved').evaluate().isNotEmpty) {
      return;
    }
  }

  fail('The app did not reach the four tabs after skipping sign-in.');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockEmptySecureStorage();
  });

  testWidgets('opens on the simple sign-in screen', (
    WidgetTester tester,
  ) async {
    await bootToSignIn(tester);

    expect(find.text('WHERE IS MY BUS'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Continue without an account'), findsOneWidget);

    // The old marketing copy is gone. A login screen is labels and actions.
    expect(find.textContaining('Honest bus times'), findsNothing);
    expect(find.textContaining('Every arrival comes as a range'), findsNothing);
  });

  testWidgets('create-account asks for a name', (WidgetTester tester) async {
    await bootToSignIn(tester);

    await tester.tap(find.text("I'm new here - create an account"));
    await tester.pump();

    expect(find.text('Your name'), findsOneWidget);
    expect(find.text('Create account'), findsWidgets);
  });

  testWidgets('a short password is refused without asking the server', (
    WidgetTester tester,
  ) async {
    await bootToSignIn(tester);

    await tester.tap(find.text("I'm new here - create an account"));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Asha');
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'asha@example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();

    expect(
      find.text('Password must be at least 8 characters.'),
      findsOneWidget,
    );
  });

  testWidgets('skipping sign-in reaches the four tabs', (
    WidgetTester tester,
  ) async {
    await skipToTabs(tester);

    expect(find.text('Board'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });

  testWidgets('Saved is a real screen, not a dead tab', (
    WidgetTester tester,
  ) async {
    await skipToTabs(tester);

    await tester.tap(find.text('Saved'));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Nothing saved yet'), findsOneWidget);
  });

  testWidgets('RouteMapWidget renders smoothly with stops and polylines', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RouteMapWidget(
            polylinePoints: [
              LatLng(28.6323, 77.2165),
              LatLng(28.5487, 77.2570),
            ],
            origin: LatLng(28.6323, 77.2165),
            destination: LatLng(28.5487, 77.2570),
            enableTiles: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RouteMapWidget), findsOneWidget);
  });
}
