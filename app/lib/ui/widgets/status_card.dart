import 'package:flutter/material.dart';

import '../../bridge/core.dart';
import '../format.dart';
import '../strings.dart';
import '../theme.dart';

/// Which variant the Home status card shows. The first match wins, top to bottom (docs/UI.md "Status card").
enum StatusCardKind { notSetUp, blocked, pausing, paused, delayed, uploading, scanning, waitingWifi, stoppedToday, upToDate }

StatusCardKind statusCardKind(Status s, {required bool setupDone}) {
  if (!setupDone) return StatusCardKind.notSetUp;
  if (s.attention.any((a) => a.kind == AttentionKind.allFilesLost)) return StatusCardKind.blocked;
  if (s.run == RunState.pausing) return StatusCardKind.pausing;
  if (s.control == ControlState.paused) return s.run == RunState.uploading ? StatusCardKind.pausing : StatusCardKind.paused;
  if (s.control == ControlState.delayed) return StatusCardKind.delayed;
  if (s.run == RunState.uploading) return StatusCardKind.uploading;
  if (s.run == RunState.scanning) return StatusCardKind.scanning;
  if (s.run == RunState.waitingNetwork) return StatusCardKind.waitingWifi;
  if (s.run == RunState.stoppedTimeLimit) return StatusCardKind.stoppedToday;
  return StatusCardKind.upToDate;
}

/// What the card's buttons do. Home fills these in.
class StatusCardActions {
  const StatusCardActions({this.onPause, this.onResume, this.onDelay, this.onFix, this.onContinueSetup, this.onUseMobile});
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final void Function(int minutes)? onDelay;
  final VoidCallback? onFix;
  final VoidCallback? onContinueSetup;
  final VoidCallback? onUseMobile;
}

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.status, required this.setupDone, required this.delayOptions, this.actions = const StatusCardActions()});

  final Status status;
  final bool setupDone;
  final List<int> delayOptions;
  final StatusCardActions actions;

  @override
  Widget build(BuildContext context) {
    final kind = statusCardKind(status, setupDone: setupDone);
    final scheme = Theme.of(context).colorScheme;
    final v = _variant(kind, scheme);
    final theme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: v.spoken,
      child: Card(
        key: ValueKey('status-${kind.name}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ExcludeSemantics(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(v.icon, color: v.color),
                  const SizedBox(width: 8),
                  Expanded(child: Text(v.title, style: theme.titleLarge?.copyWith(color: v.color))),
                ]),
                if (v.line != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(v.line!, style: theme.bodyMedium)),
                if (v.progress != null) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: v.progress, minHeight: 6)),
                if (v.fileName != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(v.fileName!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.bodySmall)),
              ]),
            ),
            if (v.buttons.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: v.buttons)),
          ]),
        ),
      ),
    );
  }

  _Variant _variant(StatusCardKind kind, ColorScheme scheme) {
    final s = status;
    switch (kind) {
      case StatusCardKind.notSetUp:
        return _Variant(Icons.info_outline, S.setupNotFinished, scheme.attention, line: S.finishSetupLine, spoken: '${S.setupNotFinished}. ${S.finishSetupLine}',
            buttons: [FilledButton(onPressed: actions.onContinueSetup, child: const Text(S.continueSetup))]);
      case StatusCardKind.blocked:
        final reason = s.attention.firstWhere((a) => a.kind == AttentionKind.allFilesLost).text;
        return _Variant(Icons.error_outline, S.backupStopped, scheme.attention, line: reason, spoken: '${S.backupStopped}. $reason',
            buttons: [FilledButton(onPressed: actions.onFix, child: const Text(S.fix))]);
      case StatusCardKind.uploading:
        final total = s.runFilesTotal;
        final done = s.runFilesDone;
        final left = s.queuedBytes;
        final line = '$done of $total files · ${sizeText(left)} left';
        final big = (s.currentFileBytesTotal ?? 0) >= 50000000 && s.currentFileBytesDone != null;
        final progress = big ? s.currentFileBytesDone! / s.currentFileBytesTotal! : (total > 0 ? done / total : null);
        final name = big ? '${s.currentFileName ?? ''} · ${sizeText(s.currentFileBytesDone!)} of ${sizeText(s.currentFileBytesTotal!)}' : s.currentFileName;
        return _Variant(Icons.cloud_upload_outlined, S.backingUp, scheme.working, line: line, progress: progress?.clamp(0.0, 1.0), fileName: name,
            spoken: '${S.backingUp}, $done of $total files, ${_spokenSize(left)} left',
            buttons: [OutlinedButton(onPressed: actions.onPause, child: const Text(S.pause))]);
      case StatusCardKind.pausing:
        final line = 'Finishing ${s.currentFileName ?? 'this file'} first.';
        return _Variant(Icons.pause_circle_outline, S.pausing, scheme.holding, line: line, spoken: '${S.pausing} $line');
      case StatusCardKind.paused:
        final line = '${plural(s.queuedCount, 'file')} waiting.';
        return _Variant(Icons.pause_circle_outline, S.paused, scheme.holding, line: line, spoken: '${S.paused}. $line', buttons: [
          for (final m in delayOptions) OutlinedButton(onPressed: () => actions.onDelay?.call(m), child: Text(delayLabel(m))),
          FilledButton(onPressed: actions.onResume, child: const Text(S.resume)),
        ]);
      case StatusCardKind.delayed:
        final until = s.delayedUntil;
        final title = until == null ? S.paused : 'Paused until ${clockText(until)}';
        return _Variant(Icons.schedule, title, scheme.holding, line: S.resumesByItself, spoken: '$title. ${S.resumesByItself}',
            buttons: [FilledButton(onPressed: actions.onResume, child: const Text(S.resumeNow))]);
      case StatusCardKind.scanning:
        return _Variant(Icons.search, S.checkingFolders, scheme.working, line: s.currentFileName ?? 'Looking for new files...', spoken: S.checkingFolders);
      case StatusCardKind.waitingWifi:
        final line = '${plural(s.queuedCount, 'file')} ready. Starts when you are on Wi-Fi.';
        return _Variant(Icons.wifi_off, S.waitingForWifi, scheme.holding, line: line, spoken: '${S.waitingForWifi}. $line',
            buttons: [OutlinedButton(onPressed: actions.onUseMobile, child: const Text(S.useMobileOnce))]);
      case StatusCardKind.stoppedToday:
        return _Variant(Icons.bedtime_outlined, S.doneForToday, scheme.holding, line: S.doneForTodayLine, spoken: '${S.doneForToday}. ${S.doneForTodayLine}');
      case StatusCardKind.upToDate:
        return _Variant(Icons.check_circle_outline, S.allBackedUp, scheme.done, line: S.nextCheckTonight, spoken: '${S.allBackedUp}. ${S.nextCheckTonight}');
    }
  }

  String _spokenSize(int bytes) {
    final t = sizeText(bytes);
    return t.replaceAll(' GB', ' gigabytes').replaceAll(' MB', ' megabytes').replaceAll(' KB', ' kilobytes').replaceAll(' B', ' bytes');
  }
}

class _Variant {
  _Variant(this.icon, this.title, this.color, {this.line, this.progress, this.fileName, required this.spoken, this.buttons = const []});
  final IconData icon;
  final String title;
  final Color color;
  final String? line;
  final double? progress;
  final String? fileName;
  final String spoken;
  final List<Widget> buttons;
}
