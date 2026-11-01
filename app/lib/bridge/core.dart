import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/strings.dart';
import 'core_api.g.dart';

export 'core_api.g.dart';

/// An error from the core, in plain words that are safe to show (docs/BRIDGE.md "Error codes").
class AppError implements Exception {
  AppError(this.code, this.message, [this.details]);
  final String code;
  final String message;
  final String? details;

  bool get isValidation => code == 'VALIDATION';
  bool get isNoNetwork => code == 'NO_NETWORK';

  /// Turns whatever came back into an [AppError]. Stack traces never reach the screen.
  factory AppError.from(Object e) {
    if (e is AppError) return e;
    if (e is PlatformException) return AppError(e.code, e.message ?? S.somethingWentWrong, e.details?.toString());
    return AppError('INTERNAL', S.somethingWentWrong);
  }

  @override
  String toString() => 'AppError($code, $message)';
}

/// Runs a call to the core and converts any failure to an [AppError].
Future<T> guarded<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    throw AppError.from(e);
  }
}

/// What the core pushes to the screens while the app is open.
class CoreEvents {
  final status = StreamController<Status>.broadcast();
  final telegram = StreamController<TelegramState>.broadcast();
  final rulesChanged = StreamController<void>.broadcast();
  final historyChanged = StreamController<void>.broadcast();
  final route = StreamController<String>.broadcast();

  void dispose() {
    status.close();
    telegram.close();
    rulesChanged.close();
    historyChanged.close();
    route.close();
  }
}

/// Receives the core's calls (Pigeon FlutterApi) and hands them to [CoreEvents].
class EventsAdapter implements CoreEventsApi {
  EventsAdapter(this.events);
  final CoreEvents events;

  @override
  void onStatus(Status status) => events.status.add(status);
  @override
  void onTelegramState(TelegramState state) => events.telegram.add(state);
  @override
  void onRulesChanged() => events.rulesChanged.add(null);
  @override
  void onHistoryChanged() => events.historyChanged.add(null);
  @override
  void onOpenRoute(String route) => events.route.add(route);
}

// ---------- providers ----------

/// The core. Overridden with a [FakeCore] in tests.
final coreProvider = Provider<CoreHostApi>((ref) => CoreHostApi());

final coreEventsProvider = Provider<CoreEvents>((ref) => CoreEvents());

class _Counter extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// Bumped when the app comes back to the front or the core says something changed. Data providers watch it.
final refreshProvider = NotifierProvider<_Counter, int>(_Counter.new);

/// Status, live: first read, then the core's pushes, and a fresh read whenever [refreshProvider] changes.
final statusProvider = StreamProvider<Status>((ref) async* {
  ref.watch(refreshProvider);
  final core = ref.watch(coreProvider);
  final events = ref.watch(coreEventsProvider);
  yield await guarded(core.getStatus);
  yield* events.status.stream;
});

final settingsProvider = FutureProvider.autoDispose<AppSettings>((ref) {
  ref.watch(refreshProvider);
  return guarded(ref.watch(coreProvider).getSettings);
});

final rulesProvider = FutureProvider.autoDispose<List<RuleWithStats>>((ref) {
  ref.watch(refreshProvider);
  return guarded(ref.watch(coreProvider).listRules);
});

final telegramStateProvider = FutureProvider.autoDispose<TelegramState>((ref) {
  ref.watch(refreshProvider);
  return guarded(ref.watch(coreProvider).getTelegramState);
});

final permissionsProvider = FutureProvider.autoDispose<Permissions>((ref) {
  ref.watch(refreshProvider);
  return guarded(ref.watch(coreProvider).getPermissions);
});

final topicsProvider = FutureProvider.autoDispose<List<Topic>>((ref) {
  ref.watch(refreshProvider);
  return guarded(ref.watch(coreProvider).listTopics);
});

/// Connects the core's pushes to the data providers. Read once at the app root.
final eventsWiringProvider = Provider<void>((ref) {
  final events = ref.watch(coreEventsProvider);
  final subs = <StreamSubscription<Object?>>[
    events.rulesChanged.stream.listen((_) => ref.read(refreshProvider.notifier).bump()),
    events.historyChanged.stream.listen((_) => ref.read(refreshProvider.notifier).bump()),
    events.telegram.stream.listen((_) => ref.invalidate(telegramStateProvider)),
  ];
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
  });
});
