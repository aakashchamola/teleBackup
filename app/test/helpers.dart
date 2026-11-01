import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:telebackup/app.dart';
import 'package:telebackup/bridge/core.dart';
import 'package:telebackup/bridge/fake_core.dart';
import 'package:telebackup/features/setup/setup_flow.dart';

class _Harness extends ConsumerWidget {
  const _Harness({this.themeMode = ThemeMode.light});
  final ThemeMode themeMode;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(eventsWiringProvider);
    ref.watch(routeEventsProvider);
    return MaterialApp.router(
      routerConfig: ref.watch(routerProvider),
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue, brightness: Brightness.dark),
      themeMode: themeMode,
    );
  }
}

/// Starts the real app (router and screens) on top of a [FakeCore] and waits for it to settle.
Future<(FakeCore, GoRouter)> pumpApp(
  WidgetTester tester, {
  FakeCore? core,
  String location = '/home',
  Size logicalSize = const Size(400, 850),
  double textScale = 1.0,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final fake = core ?? FakeCore();
  tester.view.physicalSize = logicalSize * 2;
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: [
      coreProvider.overrideWithValue(fake),
      coreEventsProvider.overrideWithValue(fake.events),
      notificationRequestProvider.overrideWithValue(() async => true),
    ],
    child: _Harness(themeMode: themeMode),
  ));
  await tester.pumpAndSettle();
  final router = ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider);
  if (location != '/home') {
    router.go(location);
    await tester.pumpAndSettle();
  }
  return (fake, router);
}

/// Scrolls until [finder] is on screen, then taps it.
Future<void> tapText(WidgetTester tester, String text) async {
  final f = find.text(text);
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 250, scrollable: find.byType(Scrollable).first, maxScrolls: 80);
  }
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}
