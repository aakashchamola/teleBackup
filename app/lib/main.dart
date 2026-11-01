import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bridge/core.dart';
import 'bridge/fake_core.dart';

/// `flutter run --dart-define=FAKE_CORE=true` runs the screens against an in-memory core (no phone services needed).
const _fakeCore = bool.fromEnvironment('FAKE_CORE');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final events = CoreEvents();
  if (!_fakeCore) CoreEventsApi.setUp(EventsAdapter(events));
  final overrides = [
    coreEventsProvider.overrideWithValue(events),
    if (_fakeCore) coreProvider.overrideWithValue(FakeCore(events: events)),
  ];
  runApp(ProviderScope(overrides: overrides, child: const TeleBackupApp()));
}
