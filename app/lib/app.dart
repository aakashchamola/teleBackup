import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'bridge/core.dart';
import 'features/history/history_screens.dart';
import 'features/home/home_screen.dart';
import 'features/rules/rules_screens.dart';
import 'features/settings/settings_screens.dart';
import 'features/setup/setup_flow.dart';
import 'ui/strings.dart';
import 'ui/theme.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

HistoryFilter? _filterFrom(String? name) => HistoryFilter.values.where((f) => f.name == name).firstOrNull;

/// The screens and how to reach them (docs/UI.md section 3). Everything but the four tabs and setup opens above the tab bar.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/home',
    redirect: (context, state) async {
      final loc = state.matchedLocation;
      if (loc == '/setup' || loc == '/telegram/login') return null;
      try {
        final s = await ref.read(coreProvider).getSettings();
        if (!s.setupDone) return '/setup';
      } catch (_) {
        // if the core does not answer, let the screen show its own error
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/home'),
      GoRoute(path: '/setup', builder: (_, _) => const SetupFlow()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Shell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/rules', builder: (_, _) => const RulesScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/history',
              builder: (_, state) => HistoryScreen(
                key: ValueKey(state.uri.toString()),
                initialFilter: _filterFrom(state.uri.queryParameters['filter']),
                ruleId: int.tryParse(state.uri.queryParameters['rule'] ?? ''),
              ),
            ),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen())]),
        ],
      ),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/rules/new', builder: (_, _) => const RuleEditScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/rules/:id', builder: (_, s) => RuleDetailScreen(ruleId: int.parse(s.pathParameters['id']!))),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/rules/:id/edit', builder: (_, s) => RuleEditScreen(ruleId: int.parse(s.pathParameters['id']!))),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/folder', builder: (_, _) => const FolderScreen()),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: '/topic',
        builder: (_, s) => TopicScreen(suggestedName: (s.extra as Map?)?['name'] as String? ?? ''),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: '/review/:ruleId',
        builder: (_, s) => ReviewScreen(ruleId: int.parse(s.pathParameters['ruleId']!), previewOnly: s.uri.queryParameters['preview'] == '1'),
      ),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/file/:id', builder: (_, s) => FileScreen(fileId: int.parse(s.pathParameters['id']!))),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/telegram', builder: (_, _) => const TelegramScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/telegram/login', builder: (_, _) => const LoginScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/permissions', builder: (_, _) => const PermissionsScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/diagnostics', builder: (_, _) => const DiagnosticsScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/dev', builder: (_, _) => const DevScreen()),
    ],
  );
});

/// The bottom navigation. Back from another tab goes to Home; back from Home leaves the app.
class _Shell extends StatelessWidget {
  const _Shell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: shell.currentIndex == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) shell.goBranch(0);
        },
        child: Scaffold(
          body: shell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: S.tabHome),
              NavigationDestination(icon: Icon(Icons.rule_folder_outlined), selectedIcon: Icon(Icons.rule_folder), label: S.tabRules),
              NavigationDestination(icon: Icon(Icons.history), label: S.tabHistory),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: S.tabSettings),
            ],
          ),
        ),
      );
}

/// A tapped notification says where to go (docs/UI.md section 8).
final routeEventsProvider = Provider<void>((ref) {
  void open(String route) {
    final r = ref.read(routerProvider);
    if (route == 'home') {
      r.go('/home');
    } else if (route == 'login') {
      r.push('/telegram/login');
    } else if (route == 'perm:files') {
      r.push('/permissions');
    } else if (route == 'telegram') {
      r.push('/telegram');
    } else if (route.startsWith('rule:')) {
      r.push('/rules/${route.substring(5)}');
    } else if (route.startsWith('review:')) {
      r.push('/review/${route.substring(7)}');
    }
  }

  final sub = ref.watch(coreEventsProvider).route.stream.listen(open);
  ref.onDispose(sub.cancel);
});

class TeleBackupApp extends ConsumerStatefulWidget {
  const TeleBackupApp({super.key});
  @override
  ConsumerState<TeleBackupApp> createState() => _TeleBackupAppState();
}

class _TeleBackupAppState extends ConsumerState<TeleBackupApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.read(refreshProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(eventsWiringProvider);
    ref.watch(routeEventsProvider);
    final router = ref.watch(routerProvider);
    return withDynamicColor(
      (light, dark) => MaterialApp.router(
        title: S.appName,
        theme: light,
        darkTheme: dark,
        themeMode: ThemeMode.system,
        routerConfig: router,
      ),
    );
  }
}
