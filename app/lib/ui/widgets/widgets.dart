import 'package:flutter/material.dart';

import '../../bridge/core.dart';
import '../format.dart';
import '../strings.dart';
import '../theme.dart';

export 'status_card.dart';

/// Shows a failure from the core as a snackbar. Never a stack trace (docs/UI.md section 10).
void showError(BuildContext context, Object e) {
  final msg = e is AppError ? e.message : S.somethingWentWrong;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// A thin bar under the app bar while something loads, so the screen never goes blank.
class LoadingBar extends StatelessWidget implements PreferredSizeWidget {
  const LoadingBar({super.key, required this.loading});
  final bool loading;
  @override
  Size get preferredSize => const Size.fromHeight(4);
  @override
  Widget build(BuildContext context) => SizedBox(height: 4, child: loading ? const LinearProgressIndicator() : null);
}

class SizeText extends StatelessWidget {
  const SizeText(this.bytes, {super.key, this.style});
  final int bytes;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => Text(sizeText(bytes), style: style);
}

class TimeText extends StatelessWidget {
  const TimeText(this.epochMs, {super.key, this.style});
  final int? epochMs;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => Text(timeText(epochMs), style: style);
}

/// One line with an icon and, if there is something to do, one button (docs/UI.md "WarningRow").
class WarningRow extends StatelessWidget {
  const WarningRow({super.key, required this.text, this.actionLabel, this.onAction, this.icon = Icons.warning_amber_rounded});
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, color: scheme.attention),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
        if (actionLabel != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ]),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label $value',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
        ]),
      );
}

class ModeChip extends StatelessWidget {
  const ModeChip({super.key, required this.mode, required this.retentionDays, this.blockedReason});
  final RuleMode mode;
  final int retentionDays;
  final String? blockedReason;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final del = mode == RuleMode.uploadAndDelete;
    return Wrap(spacing: 6, runSpacing: 4, children: [
      Chip(
        avatar: Icon(del ? Icons.delete_outline : Icons.cloud_done_outlined, size: 18),
        label: Text(del ? S.uploadAndDelete(retentionDays) : S.uploadOnly),
        visualDensity: VisualDensity.compact,
      ),
      if (del && blockedReason != null)
        Chip(
          avatar: Icon(Icons.block, size: 18, color: scheme.attention),
          label: Text(S.deletePaused(_reason(blockedReason!))),
          visualDensity: VisualDensity.compact,
        ),
    ]);
  }

  String _reason(String r) => r == 'PERMISSION_LOST' ? 'no access to files' : r.toLowerCase().replaceAll('_', ' ');
}

class FormChip extends StatelessWidget {
  const FormChip({super.key, required this.uploadAs});
  final UploadAs uploadAs;
  @override
  Widget build(BuildContext context) => Chip(
        label: Text(uploadAs == UploadAs.media ? S.media : S.originalFile),
        visualDensity: VisualDensity.compact,
      );
}

/// One row of History (docs/UI.md "S-HIST").
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.onTap});
  final EventItem event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _look(context, event.kind);
    return ListTile(
      onTap: event.fileId != null ? onTap : null,
      leading: Icon(icon, color: color),
      title: Text(event.message, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text([if (event.bytes != null) sizeText(event.bytes!), clockText(event.at)].join(' · ')),
      dense: true,
    );
  }

  (IconData, Color) _look(BuildContext context, String kind) {
    final s = Theme.of(context).colorScheme;
    switch (kind) {
      case 'UPLOADED':
      case 'VERIFIED':
        return (Icons.arrow_upward, s.working);
      case 'DELETED':
        return (Icons.delete_outline, s.done);
      case 'FAILED':
      case 'SKIPPED':
      case 'VERIFY_FAILED':
      case 'DELETE_DENIED':
      case 'LOGIN_EXPIRED':
      case 'PERMISSION_LOST':
      case 'TOPIC_MISSING':
      case 'BOT_PROBLEM':
        return (Icons.error_outline, s.attention);
      case 'PAUSED':
      case 'DELAYED':
      case 'RESUMED':
        return (Icons.pause_circle_outline, s.holding);
      default:
        return (Icons.circle_outlined, s.outline);
    }
  }
}

/// The steps a file went through, with the time of each (docs/UI.md "S-FILE").
class FileTimeline extends StatelessWidget {
  const FileTimeline({super.key, required this.file});
  final FileItem file;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (file.queuedAt != null) ('Found', timeText(file.queuedAt)),
      if (file.uploadedAt != null) ('Uploaded', timeText(file.uploadedAt)),
      if (file.verifiedAt != null) ('Checked', timeText(file.verifiedAt)),
      if (file.deleteAfter != null && file.deletedAt == null) ('Deletes on', dateText(file.deleteAfter!)),
      if (file.deletedAt != null) ('Deleted', timeText(file.deletedAt)),
    ];
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [SizedBox(width: 110, child: Text(r.$1, style: Theme.of(context).textTheme.labelLarge)), Text(r.$2)]),
        ),
    ]);
  }
}

/// A line with a tick or cross, words, and a fix (docs/UI.md "CheckRow").
class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.ok, required this.title, this.subtitle, this.actionLabel, this.onAction, this.busy = false});
  final bool ok;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$title, ${ok ? 'done' : 'not done'}',
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? scheme.done : scheme.outline),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: (!ok && actionLabel != null) ? FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)) : null,
      ),
    );
  }
}

/// A text field that hides what is typed, with an eye to show it (docs/UI.md "SecretField").
class SecretField extends StatefulWidget {
  const SecretField({super.key, required this.controller, required this.label, this.onChanged, this.errorText, this.helperText, this.keyboardType, this.trailing});
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final String? helperText;
  final TextInputType? keyboardType;
  final Widget? trailing;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _show = false;
  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: !_show,
        enableSuggestions: false,
        autocorrect: false,
        keyboardType: widget.keyboardType,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: widget.errorText,
          helperText: widget.helperText,
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.trailing != null) widget.trailing!,
            IconButton(
              tooltip: _show ? 'Hide' : 'Show',
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _show = !_show),
            ),
          ]),
        ),
      );
}

/// Title, body and one Next button for each setup step; progress is shown at the top.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    super.key,
    required this.step,
    required this.total,
    required this.title,
    required this.children,
    this.onNext,
    this.nextLabel = S.next,
    this.onBack,
    this.secondary,
    this.busy = false,
  });

  final int step;
  final int total;
  final String title;
  final List<Widget> children;
  final VoidCallback? onNext;
  final String nextLabel;
  final VoidCallback? onBack;
  final Widget? secondary;
  final bool busy;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: onBack == null ? null : IconButton(tooltip: S.back, icon: const Icon(Icons.arrow_back), onPressed: onBack),
          title: Text(S.stepOf(step, total)),
          bottom: LoadingBar(loading: busy),
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 16),
                ...children,
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
                ?secondary,
                FilledButton(onPressed: onNext, child: Text(nextLabel)),
              ]),
            ),
          ]),
        ),
      );
}

Future<bool> confirm(BuildContext context, {required String title, required String body, required String yes, String no = S.cancel}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
      ],
    ),
  );
  return r ?? false;
}
