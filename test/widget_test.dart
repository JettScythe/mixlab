import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixlab/main.dart';
import 'package:mixlab/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sets a desktop-sized surface so the NavigationRail branch is exercised.
void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<AppState> _boot(WidgetTester tester) async {
  final state = AppState();
  await tester.pumpWidget(MixLabApp(state: state));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('boots to the calculator with seeded data', (tester) async {
    _useDesktopSurface(tester);
    final state = await _boot(tester);

    expect(state.isReady, isTrue);
    expect(state.loadError, isNull);
    expect(state.ingredients, isNotEmpty);
    expect(find.text('Mix by weight'), findsOneWidget);
  });

  testWidgets('every tab renders without throwing', (tester) async {
    _useDesktopSurface(tester);
    await _boot(tester);

    for (final tab in ['Recipes', 'Inventory', 'History', 'Settings', 'Mix']) {
      await tester.tap(find.text(tab).first);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Exception while rendering the $tab tab',
      );
    }
  });

  testWidgets('calculator produces a weight for the default mix', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    await _boot(tester);

    // Seeded defaults: 30 mL, 3 mg, 70% VG, no flavors.
    expect(find.textContaining(RegExp(r'\d+\.\d{2} g total')), findsOneWidget);
    expect(find.textContaining('Final ratio'), findsOneWidget);
    expect(find.textContaining('Nicotine:'), findsOneWidget);
  });

  testWidgets('loading a recipe fills the calculator', (tester) async {
    _useDesktopSurface(tester);
    final state = await _boot(tester);

    // The list sorts by name, so work out which card lands first rather
    // than assuming seed order.
    final names = state.recipes.map((r) => r.name).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final firstName = names.first;

    await tester.tap(find.text('Recipes').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Load into calculator').first);
    await tester.pumpAndSettle();

    // The chip appears on the Mix tab, and the source card is still alive
    // in the IndexedStack, so expect more than one match.
    expect(find.text(firstName), findsWidgets);
  });

  testWidgets('narrow layout uses bottom navigation', (tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _boot(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('recovery screen appears instead of hanging', (tester) async {
    SharedPreferences.setMockInitialValues({
      'schema_version': 8,
      'ingredients_v1': '{{{ not json',
    });
    _useDesktopSurface(tester);
    await _boot(tester);

    expect(find.text('Could not load your data'), findsOneWidget);
    expect(find.text('Try loading again'), findsOneWidget);
  });
}
