import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../bridge/core.dart';
import 'widgets/widgets.dart';

extension CoreCalls on WidgetRef {
  CoreHostApi get core => read(coreProvider);

  /// Runs a call to the core. On failure shows the plain-words message and returns null.
  Future<T?> attempt<T>(BuildContext context, Future<T> Function(CoreHostApi core) call) async {
    try {
      return await guarded(() => call(core));
    } on AppError catch (e) {
      if (context.mounted) showError(context, e);
      return null;
    }
  }

  void reload() => read(refreshProvider.notifier).bump();
}

extension SafeLeave on BuildContext {
  /// Goes back; if this screen was opened directly (from a notification, say) there is nothing behind it, so go Home.
  void leave([String fallback = '/home']) {
    if (canPop()) {
      pop();
    } else {
      go(fallback);
    }
  }
}
