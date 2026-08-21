// Smoke test for the app shell. Kept deliberately small - no network
// calls happen on first frame (nothing is typed into a search box), so
// this can run without a live API and just proves the app boots into the
// right screen with the right navigation, not any specific search result.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wimb_app/main.dart';

// ProviderScope is required at the root for any of Riverpod's `ref.watch`
// calls to work, same as in main.dart - pumping WimbApp on its own throws
// "Bad state: No ProviderScope found" the moment JourneyScreen builds.
Widget _app() => const ProviderScope(child: WimbApp());

void main() {
  testWidgets('boots into the journey planner with all tabs visible',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('Where are you, and where are you going?'), findsOneWidget);
    expect(find.text('Journey'), findsOneWidget);
    expect(find.text('When?'), findsOneWidget);
    expect(find.text('Routes'), findsOneWidget);
  });

  testWidgets('switching to the When tab shows the day-type toggle',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.text('When?'));
    await tester.pumpAndSettle();

    expect(find.text('Compare hours'), findsOneWidget);
    expect(find.text('Weekday'), findsOneWidget);
    expect(find.text('Weekend'), findsOneWidget);
  });

  testWidgets('switching to the Routes tab shows the route search prompt',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Routes'));
    await tester.pumpAndSettle();

    expect(find.text('Route number, e.g. 764'), findsOneWidget);
  });
}
