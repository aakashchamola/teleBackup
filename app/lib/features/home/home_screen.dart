import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../bridge/core.dart';
import '../../ui/format.dart';
import '../../ui/run.dart';
import '../../ui/strings.dart';
import '../../ui/widgets/widgets.dart';

/// What a warning's button does, and what it says (docs/UI.md "Warnings").
({String label, VoidCallback run})? warningAction(BuildContext context, WidgetRef ref, Attention a) {
  switch (a.kind) {
    case AttentionKind.loginExpired:
    case AttentionKind.bigFilesWaitAccount:
      return (label: S.logIn, run: () => context.push('/telegram/login'));
    case AttentionKind.allFilesLost:
      return (label: S.fix, run: () => ref.attempt(context, (c) => c.openAllFilesSettings()));
    case AttentionKind.notificationsOff:
      return (label: S.fix, run: () => ref.attempt(context, (c) => c.openNotificationSettings()));
    case AttentionKind.batteryOptimized:
      return (label: S.fix, run: () => ref.attempt(context, (c) => c.requestBatteryExemption()));
    case AttentionKind.botProblem:
      return (label: S.fix, run: () => context.push('/telegram'));
    case AttentionKind.topicMissing:
      return (label: S.fix, run: () => context.push('/rules/${a.ruleId}'));
    case AttentionKind.reviewWaiting:
      return (label: S.review, run: () => context.push('/review/${a.ruleId}'));
    case AttentionKind.skippedRecently:
      return (label: S.see, run: () => context.go('/history?filter=skipped'));
    case AttentionKind.setupNotDone:
      return (label: S.continueSetup, run: () => context.go('/setup'));
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(statusProvider);
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.appName), bottom: LoadingBar(loading: status.isLoading)),
      body: status.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(S.somethingWentWrong),
          TextButton(onPressed: () => ref.reload(), child: const Text(S.tryAgain)),
        ]))),
        data: (s) => _Body(status: s, setupDone: settings.value?.setupDone ?? true, delays: settings.value?.delayOptionsMinutes ?? const [120, 300]),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.status, required this.setupDone, required this.delays});
  final Status status;
  final bool setupDone;
  final List<int> delays;

  Future<void> _useMobileOnce(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(context,
        title: S.mobileTitle, body: S.mobileBody(status.queuedCount, sizeText(status.queuedBytes)), yes: S.useMobileData);
    if (ok && context.mounted) await ref.attempt(context, (c) => c.uploadNow(true));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).textTheme;
    final warnings = status.attention.where((a) => a.kind != AttentionKind.setupNotDone || !setupDone).toList();
    // the status card already says "blocked" and "setup not finished"
    final listed = warnings.where((a) => a.kind != AttentionKind.allFilesLost && a.kind != AttentionKind.setupNotDone).toList();
    return RefreshIndicator(
      onRefresh: () async => ref.reload(),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        StatusCard(
          status: status,
          setupDone: setupDone,
          delayOptions: delays.take(2).toList(),
          actions: StatusCardActions(
            onPause: () => ref.attempt(context, (c) => c.pause()),
            onResume: () => ref.attempt(context, (c) => c.resume()),
            onDelay: (m) => ref.attempt(context, (c) => c.delay(m)),
            onFix: () => ref.attempt(context, (c) => c.openAllFilesSettings()),
            onContinueSetup: () => context.go('/setup'),
            onUseMobile: () => _useMobileOnce(context, ref),
          ),
        ),
        const SizedBox(height: 12),
        for (final a in listed)
          Builder(builder: (context) {
            final act = warningAction(context, ref, a);
            return WarningRow(text: a.text, actionLabel: act?.label, onAction: act?.run);
          }),
        const SizedBox(height: 12),
        Text(S.today, style: scheme.titleMedium),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: StatTile(label: S.uploaded, value: '${status.todayUploaded}')),
          Expanded(child: StatTile(label: S.freed, value: sizeText(status.todayFreedBytes))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: StatTile(label: S.inQueue, value: '${status.queuedCount}')),
          Expanded(child: StatTile(label: S.skipped, value: '${status.todaySkipped}')),
        ]),
        const SizedBox(height: 16),
        Text(S.freedSoFar(sizeText(status.freedBytesTotal)), style: scheme.titleMedium),
        const SizedBox(height: 12),
        Text(S.lastScan(timeText(status.lastScanAt))),
        Text(S.lastUpload(timeText(status.lastUploadAt))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => ref.attempt(context, (c) => c.scanNow(null)), child: const Text(S.scanNow))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: () => ref.attempt(context, (c) => c.uploadNow(false)), child: const Text(S.uploadNow))),
        ]),
      ]),
    );
  }
}
