import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/core.dart';
import '../../ui/format.dart';
import '../../ui/run.dart';
import '../../ui/strings.dart';
import '../../ui/widgets/widgets.dart';
import '../settings/settings_screens.dart' show makerHelp;

/// Asks Android for the notification permission. Replaced in tests, where no plugin is running.
final notificationRequestProvider = Provider<Future<bool> Function()>((ref) => () async {
      final s = await Permission.notification.request();
      return s.isGranted;
    });

const _steps = ['O1', 'O2', 'O3', 'O4', 'O5', 'O6', 'O7'];

/// First run, one step per screen. Progress is saved after each step, so leaving and coming back resumes (docs/UI.md section 4).
class SetupFlow extends ConsumerStatefulWidget {
  const SetupFlow({super.key});
  @override
  ConsumerState<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends ConsumerState<SetupFlow> {
  String? _step;

  @override
  void initState() {
    super.initState();
    ref.read(coreProvider).getSettings().then((s) {
      if (mounted) setState(() => _step = _steps.contains(s.setupStep) ? s.setupStep : 'O1');
    }).catchError((_) {
      if (mounted) setState(() => _step = 'O1');
    });
  }

  Future<void> _goTo(String step) async {
    setState(() => _step = step);
    await ref.read(coreProvider).setSetupStep(step).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    if (step == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final i = _steps.indexOf(step);
    void next() => _goTo(_steps[i + 1]);
    void back() => _goTo(_steps[i - 1]);
    switch (step) {
      case 'O1':
        return _Welcome(onStart: next);
      case 'O2':
        return _Permissions(onNext: next, onBack: back);
      case 'O3':
        return _BotStep(onNext: next, onBack: back);
      case 'O4':
        return _GroupStep(onNext: next, onBack: back);
      case 'O5':
        return _AccountStep(onNext: next, onBack: back);
      case 'O6':
        return _SuggestStep(onNext: next, onBack: back);
      default:
        return _DoneStep(onBack: back);
    }
  }
}

// ---------------------------------------------------------------- O1

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onStart});
  final VoidCallback onStart;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Spacer(),
              Center(child: Icon(Icons.cloud_upload_outlined, size: 96, color: Theme.of(context).colorScheme.primary)),
              const SizedBox(height: 24),
              Text(S.welcomeTitle, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              const Text(S.welcomeBody),
              const SizedBox(height: 16),
              const Text(S.welcomeTime),
              const Spacer(),
              SizedBox(width: double.infinity, child: FilledButton(key: const Key('start-setup'), onPressed: onStart, child: const Text(S.startSetup))),
            ]),
          ),
        ),
      );
}

// ---------------------------------------------------------------- O2

class _Permissions extends ConsumerStatefulWidget {
  const _Permissions({required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;
  @override
  ConsumerState<_Permissions> createState() => _PermissionsState();
}

class _PermissionsState extends ConsumerState<_Permissions> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.resumed) ref.invalidate(permissionsProvider);
  }

  Future<void> _notifications() async {
    final granted = await ref.read(notificationRequestProvider)().catchError((_) => false);
    if (!granted && mounted) await ref.attempt(context, (c) => c.openNotificationSettings());
    ref.invalidate(permissionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(permissionsProvider);
    final v = p.value;
    final all = v != null && v.notifications && v.allFiles && v.batteryExempt;
    return StepScaffold(
      step: 1,
      total: 6,
      title: S.permissionsTitle,
      busy: p.isLoading,
      onBack: widget.onBack,
      onNext: all ? widget.onNext : null,
      children: [
        CheckRow(ok: v?.notifications ?? false, title: S.permNotifications, subtitle: S.permNotificationsWhy, actionLabel: S.allow, onAction: _notifications),
        CheckRow(ok: v?.allFiles ?? false, title: S.permFiles, subtitle: S.permFilesWhy, actionLabel: S.allow, onAction: () => ref.attempt(context, (c) => c.openAllFilesSettings())),
        CheckRow(ok: v?.batteryExempt ?? false, title: S.permBackground, subtitle: S.permBackgroundWhy, actionLabel: S.allow, onAction: () => ref.attempt(context, (c) => c.requestBatteryExemption())),
        if (v?.makerGuide != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Expanded(child: Text(S.makerLine)),
              TextButton(
                onPressed: () => showDialog<void>(context: context, builder: (c) => AlertDialog(title: const Text(S.permBackground), content: Text(makerHelp(v!.makerGuide!)), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text(S.close))])),
                child: const Text(S.makerHow),
              ),
            ]),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- O3

enum _TokenState { idle, checking, ok, wrong, offline }

class _BotStep extends ConsumerStatefulWidget {
  const _BotStep({required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;
  @override
  ConsumerState<_BotStep> createState() => _BotStepState();
}

class _BotStepState extends ConsumerState<_BotStep> {
  final _c = TextEditingController();
  Timer? _debounce;
  _TokenState _state = _TokenState.idle;
  BotInfo? _bot;

  @override
  void initState() {
    super.initState();
    // coming back to this step with a bot already connected
    ref.read(coreProvider).getTelegramState().then((t) {
      if (mounted && t.bot != null && _state == _TokenState.idle) setState(() { _bot = t.bot; _state = _TokenState.ok; });
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) return setState(() => _state = _TokenState.idle);
    _debounce = Timer(const Duration(seconds: 1), _check);
  }

  Future<void> _check() async {
    final token = _c.text.trim();
    if (token.isEmpty) return;
    setState(() => _state = _TokenState.checking);
    try {
      final bot = await guarded(() => ref.read(coreProvider).setBotToken(token));
      if (mounted) setState(() { _bot = bot; _state = _TokenState.ok; });
    } on AppError catch (e) {
      if (mounted) setState(() => _state = e.isNoNetwork ? _TokenState.offline : _TokenState.wrong);
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) {
      _c.text = d!.text!.trim();
      _debounce?.cancel();
      _check();
    }
  }

  @override
  Widget build(BuildContext context) => StepScaffold(
        step: 2,
        total: 6,
        title: S.botTitle,
        onBack: widget.onBack,
        busy: _state == _TokenState.checking,
        onNext: _state == _TokenState.ok ? widget.onNext : null,
        children: [
          const Text(S.botIntro),
          const SizedBox(height: 12),
          const Text(S.botStep1),
          Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => launchUrl(Uri.parse('https://t.me/BotFather'), mode: LaunchMode.externalApplication), child: const Text(S.openTelegram))),
          const Text(S.botStep2),
          const Text(S.botStep3),
          const Text(S.botStep4),
          const SizedBox(height: 16),
          SecretField(
            controller: _c,
            label: S.botTokenLabel,
            onChanged: _changed,
            trailing: TextButton(onPressed: _paste, child: const Text(S.paste)),
          ),
          const SizedBox(height: 8),
          switch (_state) {
            _TokenState.idle => const SizedBox.shrink(),
            _TokenState.checking => const Text(S.tokenChecking),
            _TokenState.ok => CheckRow(ok: true, title: S.tokenOk(_bot?.username ?? '')),
            _TokenState.wrong => Text(S.tokenWrong, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            _TokenState.offline => Text(S.noInternet, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          },
        ],
      );
}

// ---------------------------------------------------------------- O4

class _GroupStep extends ConsumerStatefulWidget {
  const _GroupStep({required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;
  @override
  ConsumerState<_GroupStep> createState() => _GroupStepState();
}

class _GroupStepState extends ConsumerState<_GroupStep> {
  List<GroupCandidate>? _groups;
  int? _chosen;
  GroupCheck? _check;
  bool _busy = false;

  Future<void> _find() async {
    setState(() { _busy = true; _check = null; });
    final g = await ref.attempt(context, (c) => c.findGroups());
    if (!mounted) return;
    setState(() { _groups = g; _busy = false; });
    if (g != null && g.length == 1) _choose(g.first.chatId);
  }

  Future<void> _choose(int chatId) async {
    setState(() { _chosen = chatId; _busy = true; });
    final c = await ref.attempt(context, (core) => core.checkGroup(chatId));
    if (mounted) setState(() { _check = c; _busy = false; });
  }

  Future<void> _next() async {
    setState(() => _busy = true);
    final ok = await ref.attempt(context, (c) => c.selectGroup(_chosen!).then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final c = _check;
    return StepScaffold(
      step: 3,
      total: 6,
      title: S.groupTitle,
      onBack: widget.onBack,
      busy: _busy,
      onNext: (c != null && c.topicsOn && c.botIsAdmin && c.botCanManageTopics) ? _next : null,
      children: [
        const Text(S.groupStep1),
        const Text(S.groupStep2),
        const Text(S.groupStep3),
        const Text(S.groupStep4),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerLeft, child: FilledButton.tonal(key: const Key('find-group'), onPressed: _busy ? null : _find, child: const Text(S.findGroup))),
        const SizedBox(height: 8),
        if (_groups != null && _groups!.isEmpty) const Text(S.noGroupFound),
        if (_groups != null)
          RadioGroup<int>(
            groupValue: _chosen,
            onChanged: (v) { if (v != null) _choose(v); },
            child: Column(children: [for (final g in _groups!) RadioListTile<int>(contentPadding: EdgeInsets.zero, value: g.chatId, title: Text(g.title))]),
          ),
        if (c != null) ...[
          CheckRow(ok: c.topicsOn, title: S.checkTopicsOn, subtitle: c.topicsOn ? null : S.fixTopicsOff),
          CheckRow(ok: c.botIsAdmin, title: S.checkBotAdmin, subtitle: c.botIsAdmin ? null : S.fixNotAdmin),
          CheckRow(ok: c.botCanManageTopics, title: S.checkBotTopics, subtitle: c.botCanManageTopics ? null : S.fixNoManageTopics),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- O5

class _AccountStep extends ConsumerWidget {
  const _AccountStep({required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(telegramStateProvider).value;
    final ready = t?.account == AccountState.ready;
    return StepScaffold(
      step: 4,
      total: 6,
      title: S.accountTitle,
      onBack: onBack,
      onNext: ready ? onNext : null,
      secondary: ready ? null : TextButton(key: const Key('skip-account'), onPressed: onNext, child: const Text(S.skip)),
      children: [
        const Text(S.accountBody),
        const SizedBox(height: 8),
        const Text(S.recommended),
        const SizedBox(height: 16),
        if (ready)
          CheckRow(ok: true, title: 'Logged in as ${t?.accountName ?? ''}', subtitle: t?.accountPhoneMasked)
        else
          Align(alignment: Alignment.centerLeft, child: FilledButton.tonal(onPressed: () => context.push('/telegram/login'), child: const Text(S.loginToAccount))),
        const SizedBox(height: 16),
        if (!ready) Text(S.skipNote, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ---------------------------------------------------------------- O6

class _SuggestStep extends ConsumerStatefulWidget {
  const _SuggestStep({required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;
  @override
  ConsumerState<_SuggestStep> createState() => _SuggestStepState();
}

class _SuggestStepState extends ConsumerState<_SuggestStep> {
  List<FolderInfo>? _folders;
  final Set<String> _checked = {};
  StartMode _from = StartMode.today;
  int? _date;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(coreProvider).suggestedFolders().then((f) {
      if (!mounted) return;
      setState(() {
        _folders = f;
        _checked.addAll(f.where((x) => x.hint == null && x.usedByRule == null).map((x) => x.path));
      });
    }).catchError((_) {
      if (mounted) setState(() => _folders = []);
    });
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final n = await ref.attempt(context, (c) => c.createSuggestedRules(_checked.toList(), _from, _date));
    if (!mounted) return;
    setState(() => _busy = false);
    if (n != null) {
      ref.reload();
      widget.onNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _folders;
    return StepScaffold(
      step: 5,
      total: 6,
      title: S.suggestTitle,
      onBack: widget.onBack,
      busy: _busy || f == null,
      nextLabel: S.createRules,
      onNext: (_busy || _checked.isEmpty) ? null : _create,
      secondary: TextButton(onPressed: _busy ? null : widget.onNext, child: const Text(S.skip)),
      children: [
        const Text(S.suggestBody),
        const SizedBox(height: 12),
        if (f != null && f.isEmpty) const Text(S.noFoldersFound),
        if (_busy) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text(S.makingTopics)),
        for (final x in f ?? const <FolderInfo>[])
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _checked.contains(x.path),
            onChanged: _busy ? null : (v) => setState(() => v == true ? _checked.add(x.path) : _checked.remove(x.path)),
            title: Text(x.label),
            subtitle: Text('${x.path.split('?').first.replaceAll(RegExp(r'/$'), '')}\n${plural(x.mediaCount, 'file')}${x.hint == null ? '' : ' · ${x.hint}'}'),
            isThreeLine: true,
          ),
        const SizedBox(height: 8),
        const Text(S.backUpFrom),
        RadioGroup<StartMode>(
          groupValue: _from,
          onChanged: (v) => setState(() => _from = v ?? _from),
          child: Column(children: [
            const RadioListTile<StartMode>(contentPadding: EdgeInsets.zero, value: StartMode.today, title: Text(S.fromToday)),
            const RadioListTile<StartMode>(contentPadding: EdgeInsets.zero, value: StartMode.everything, title: Text(S.fromEverything)),
            RadioListTile<StartMode>(
              contentPadding: EdgeInsets.zero,
              value: StartMode.sinceDate,
              title: Row(children: [
                const Text('Since '),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2010), lastDate: DateTime.now());
                    if (d != null) setState(() { _from = StartMode.sinceDate; _date = d.millisecondsSinceEpoch; });
                  },
                  child: Text(_date == null ? 'pick a date' : dateText(_date!)),
                ),
              ]),
            ),
          ]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- O7

class _DoneStep extends ConsumerStatefulWidget {
  const _DoneStep({required this.onBack});
  final VoidCallback onBack;
  @override
  ConsumerState<_DoneStep> createState() => _DoneStepState();
}

class _DoneStepState extends ConsumerState<_DoneStep> {
  bool _busy = false;

  Future<void> _finish() async {
    setState(() => _busy = true);
    final ok = await ref.attempt(context, (c) => c.finishSetup().then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      ref.reload();
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(statusProvider).value;
    return StepScaffold(
      step: 6,
      total: 6,
      title: S.doneTitle,
      onBack: widget.onBack,
      busy: _busy,
      nextLabel: S.goHome,
      onNext: _busy ? null : _finish,
      children: [
        const Text(S.doneBody),
        const SizedBox(height: 12),
        if (s != null && s.queuedCount > 0) Text('First backup: ${plural(s.queuedCount, 'file')}, ${sizeText(s.queuedBytes)}. It starts now if you are on Wi-Fi.'),
        const SizedBox(height: 12),
        const Text(S.doneNothingDeleted),
      ],
    );
  }
}
