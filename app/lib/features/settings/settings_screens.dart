import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/core.dart';
import '../../ui/format.dart';
import '../../ui/run.dart';
import '../../ui/strings.dart';
import '../../ui/version.dart';
import '../../ui/widgets/widgets.dart';

// ---------------------------------------------------------------- S-SET

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  String _documentsTopicName(WidgetRef ref, AppSettings s) {
    final id = s.documentsTopicId;
    if (id == null) return S.documentsTopicNone;
    return (ref.watch(topicsProvider).value ?? const <Topic>[]).where((t) => t.threadId == id).map((t) => t.name).firstOrNull ?? 'Topic $id';
  }

  Widget _head(BuildContext c, String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: Theme.of(c).textTheme.titleSmall?.copyWith(color: Theme.of(c).colorScheme.primary)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.settingsTitle), bottom: LoadingBar(loading: settings.isLoading)),
      body: settings.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (s) => ListView(children: [
          _head(context, S.network),
          SwitchListTile(
            key: const Key('mobile-data'),
            title: const Text(S.useMobileData),
            subtitle: const Text(S.mobileDataHelp),
            value: s.allowMobileData,
            onChanged: (v) async {
              if (v && !await confirm(context, title: S.mobileSettingTitle, body: S.mobileSettingBody, yes: S.turnOn)) return;
              if (!context.mounted) return;
              await ref.attempt(context, (c) => c.setAllowMobileData(v));
              ref.invalidate(settingsProvider);
            },
          ),
          _head(context, S.sending),
          SwitchListTile(
            key: const Key('group-by-day'),
            title: const Text(S.groupByDay),
            subtitle: const Text(S.groupByDayHelp),
            value: s.groupByDay,
            onChanged: (v) async {
              await ref.attempt(context, (c) => c.setGroupByDay(v));
              ref.invalidate(settingsProvider);
            },
          ),
          ListTile(
            key: const Key('documents-topic'),
            title: const Text(S.documentsTopic),
            subtitle: Text(_documentsTopicName(ref, s)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showDialog<void>(context: context, builder: (c) => _DocumentsTopicDialog(current: s.documentsTopicId));
              ref.invalidate(settingsProvider);
              ref.invalidate(topicsProvider);
            },
          ),
          _head(context, S.pauseButtons),
          ListTile(
            title: const Text(S.delayOptions),
            subtitle: Text(s.delayOptionsMinutes.map(_short).join(', ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showDialog<void>(context: context, builder: (c) => _DelayOptionsDialog(initial: s.delayOptionsMinutes));
              ref.invalidate(settingsProvider);
            },
          ),
          _head(context, S.newRules),
          ListTile(
            title: const Text(S.keepAfterUpload),
            subtitle: Text('${s.defaultRetentionDays} days'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showDialog<void>(context: context, builder: (c) => _RetentionDialog(initial: s.defaultRetentionDays));
              ref.invalidate(settingsProvider);
            },
          ),
          _head(context, S.telegram),
          ListTile(title: const Text(S.botGroupAccount), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/telegram')),
          _head(context, S.phone),
          ListTile(title: const Text(S.permissions), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/permissions')),
          ListTile(title: const Text(S.backgroundRunning), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/permissions')),
          _head(context, S.safety),
          ListTile(
            key: const Key('stop-deletes'),
            title: const Text(S.stopAllDeletes),
            subtitle: const Text(S.stopAllDeletesHelp),
            onTap: () async {
              if (!await confirm(context, title: S.killTitle, body: S.killBody, yes: S.stopDeletes)) return;
              if (!context.mounted) return;
              await ref.attempt(context, (c) => c.stopAllDeletes());
              ref.reload();
            },
          ),
          _head(context, S.rulesSection),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => _export(context, ref), child: const Text(S.exportRules))),
            Expanded(child: TextButton(onPressed: () => _import(context, ref), child: const Text(S.importRules))),
          ]),
          _head(context, S.help),
          ListTile(title: const Text(S.diagnostics), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/diagnostics')),
          ListTile(
            title: const Text(S.setupAgain),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ref.attempt(context, (c) => c.setSetupStep('O2'));
              if (context.mounted) context.go('/setup');
            },
          ),
          if (s.debugBuild) ListTile(title: const Text(S.developer), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/dev')),
          ListTile(title: Text('About · $appVersionLabel')),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  String _short(int m) => m % 60 == 0 ? '${m ~/ 60}h' : '${m}m';

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final text = await ref.attempt(context, (c) => c.exportRules());
    if (text == null) return;
    await SharePlus.instance.share(ShareParams(text: text, subject: 'teleBackup rules'));
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text(S.importRules),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Paste the rules text here. Imported rules arrive as upload only and switched off.'),
          const SizedBox(height: 8),
          TextField(key: const Key('import-text'), controller: c, maxLines: 6, decoration: const InputDecoration(hintText: '{"format":"telebackup-rules",...}')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Import')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final n = await ref.attempt(context, (core) => core.importRules(c.text));
    if (n != null && context.mounted) {
      ref.reload();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported ${plural(n, 'rule')}. They are off until you switch them on.')));
    }
  }
}

class _DelayOptionsDialog extends ConsumerStatefulWidget {
  const _DelayOptionsDialog({required this.initial});
  final List<int> initial;
  @override
  ConsumerState<_DelayOptionsDialog> createState() => _DelayOptionsState();
}

class _DelayOptionsState extends ConsumerState<_DelayOptionsDialog> {
  late List<int> _opts = List.of(widget.initial);
  static const _choices = [15, 30, 60, 120, 180, 300, 480, 720, 1440];

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(S.delayOptions),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pick 1 to 4 pause times.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final m in _choices)
              FilterChip(
                label: Text(delayWords(m)),
                selected: _opts.contains(m),
                onSelected: (on) => setState(() {
                  if (on && _opts.length < 4) { _opts = [..._opts, m]..sort(); }
                  if (!on && _opts.length > 1) { _opts = _opts.where((x) => x != m).toList(); }
                }),
              ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () async {
              final ok = await ref.attempt(context, (c) => c.setDelayOptions(_opts).then((_) => true));
              if (ok == true && context.mounted) Navigator.pop(context);
            },
            child: const Text(S.save),
          ),
        ],
      );
}

class _RetentionDialog extends ConsumerStatefulWidget {
  const _RetentionDialog({required this.initial});
  final int initial;
  @override
  ConsumerState<_RetentionDialog> createState() => _RetentionState();
}

class _RetentionState extends ConsumerState<_RetentionDialog> {
  late final _c = TextEditingController(text: '${widget.initial}');
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(S.keepAfterUpload),
        content: TextField(key: const Key('retention-days'), controller: _c, keyboardType: TextInputType.number, decoration: const InputDecoration(suffixText: S.days, helperText: 'For new rules. 1 to 365.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () async {
              final ok = await ref.attempt(context, (c) => c.setDefaultRetention(int.tryParse(_c.text) ?? 0).then((_) => true));
              if (ok == true && context.mounted) Navigator.pop(context);
            },
            child: const Text(S.save),
          ),
        ],
      );
}

// ---------------------------------------------------------------- S-TG

class TelegramScreen extends ConsumerWidget {
  const TelegramScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tg = ref.watch(telegramStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.tgTitle), bottom: LoadingBar(loading: tg.isLoading)),
      body: tg.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (t) {
          final g = t.group;
          final acc = t.account;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('Bot', style: Theme.of(context).textTheme.titleMedium),
            CheckRow(ok: t.bot != null, title: t.bot != null ? '@${t.bot!.username}' : 'No bot yet', subtitle: t.bot != null ? 'Connected' : null),
            const SizedBox(height: 8),
            Text('Group', style: Theme.of(context).textTheme.titleMedium),
            CheckRow(ok: g != null, title: g?.title ?? 'No group chosen'),
            if (g != null) ...[
              CheckRow(ok: g.topicsOn, title: S.checkTopicsOn),
              CheckRow(ok: g.botIsAdmin, title: S.checkBotAdmin),
              CheckRow(ok: g.botCanManageTopics, title: S.checkBotTopics),
            ],
            const SizedBox(height: 8),
            Text('Account', style: Theme.of(context).textTheme.titleMedium),
            CheckRow(
              ok: acc == AccountState.ready,
              title: switch (acc) {
                AccountState.ready => 'Logged in as ${t.accountName ?? ''}',
                AccountState.expired => 'Logged out. Log in again.',
                _ => 'Not logged in',
              },
              subtitle: t.accountPhoneMasked,
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: () => ref.reload(), child: const Text(S.checkAgain)),
              OutlinedButton(onPressed: () => _change(context, ref, 'O3'), child: const Text(S.changeBot)),
              OutlinedButton(onPressed: () => _change(context, ref, 'O4'), child: const Text(S.changeGroup)),
              if (acc == AccountState.ready)
                OutlinedButton(
                  onPressed: () async {
                    if (!await confirm(context, title: S.logoutTitle, body: S.logoutBody, yes: S.logOut)) return;
                    if (!context.mounted) return;
                    await ref.attempt(context, (c) => c.accountLogout());
                    ref.reload();
                  },
                  child: const Text(S.logOut),
                )
              else
                FilledButton(onPressed: () => context.push('/telegram/login'), child: const Text(S.logIn)),
            ]),
          ]);
        },
      ),
    );
  }

  Future<void> _change(BuildContext context, WidgetRef ref, String step) async {
    if (!await confirm(context, title: S.changeGroupTitle, body: S.changeTgBody, yes: S.change)) return;
    if (!context.mounted) return;
    await ref.attempt(context, (c) => c.setSetupStep(step));
    if (context.mounted) context.go('/setup');
  }
}

// ---------------------------------------------------------------- S-LOGIN

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginState();
}

class _LoginState extends ConsumerState<LoginScreen> {
  final _apiId = TextEditingController();
  final _apiHash = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_apiId, _apiHash, _phone, _code, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _do(Future<void> Function(CoreHostApi c) call) async {
    setState(() => _busy = true);
    await ref.attempt(context, (c) => call(c).then((_) => true));
    ref.invalidate(telegramStateProvider);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tg = ref.watch(telegramStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.loginTitle), bottom: LoadingBar(loading: _busy || tg.isLoading)),
      body: tg.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (t) => ListView(padding: const EdgeInsets.all(16), children: [
          if (t.lastError != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(t.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ..._step(context, t),
        ]),
      ),
    );
  }

  List<Widget> _step(BuildContext context, TelegramState t) {
    switch (t.account) {
      case AccountState.ready:
        return [
          Text('Logged in as ${t.accountName ?? ''}.', style: Theme.of(context).textTheme.titleMedium),
          if (t.accountPhoneMasked != null) Text(t.accountPhoneMasked!),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.leave(), child: const Text(S.close)),
        ];
      case AccountState.waitPhone:
        return [
          const Text('Your phone number, with the country code.'),
          const SizedBox(height: 12),
          TextField(key: const Key('login-phone'), controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number', hintText: '+91 98765 43210')),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : () => _do((c) => c.accountPhone(_phone.text.trim())), child: const Text('Send code')),
        ];
      case AccountState.waitCode:
        return [
          Text('Telegram sent a code to ${t.codeSentTo ?? 'your Telegram app'}.'),
          const SizedBox(height: 12),
          TextField(key: const Key('login-code'), controller: _code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Code')),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(onPressed: _busy ? null : () => _do((c) => c.accountCode(_code.text.trim())), child: const Text(S.next)),
            const SizedBox(width: 8),
            TextButton(onPressed: _busy ? null : () => _do((c) => c.accountResendCode()), child: const Text('Send again')),
          ]),
        ];
      case AccountState.waitPassword:
        return [
          Text(t.passwordHint == null ? 'Your Telegram cloud password.' : 'Your Telegram cloud password. Hint: ${t.passwordHint}'),
          const SizedBox(height: 12),
          SecretField(controller: _password, label: 'Password'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : () => _do((c) => c.accountPassword(_password.text)), child: const Text(S.logIn)),
        ];
      case AccountState.waitOther:
        return [const Text('Telegram asks for an email. Finish login in the Telegram app first, then come back.')];
      case AccountState.none:
      case AccountState.waitParams:
      case AccountState.expired:
        return [
          if (t.account == AccountState.expired) const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Your Telegram account was logged out. Log in again.')),
          const Text('Get your app keys'),
          const SizedBox(height: 4),
          const Text('Open my.telegram.org, log in, choose "API development tools" and make an app (any name). Copy the api_id and api_hash.'),
          TextButton(onPressed: () => launchUrl(Uri.parse('https://my.telegram.org'), mode: LaunchMode.externalApplication), child: const Text('Open my.telegram.org')),
          TextField(key: const Key('login-api-id'), controller: _apiId, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'api_id')),
          const SizedBox(height: 12),
          SecretField(controller: _apiHash, label: 'api_hash'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => _do((c) => c.accountStart(int.tryParse(_apiId.text.trim()) ?? 0, _apiHash.text.trim())),
            child: const Text(S.next),
          ),
        ];
    }
  }
}

// ---------------------------------------------------------------- S-PERM

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});
  @override
  ConsumerState<PermissionsScreen> createState() => _PermState();
}

class _PermState extends ConsumerState<PermissionsScreen> with WidgetsBindingObserver {
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

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(permissionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.permissions), bottom: LoadingBar(loading: p.isLoading)),
      body: p.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (v) => ListView(padding: const EdgeInsets.all(16), children: [
          CheckRow(ok: v.notifications, title: S.permNotifications, subtitle: S.permNotificationsWhy, actionLabel: S.openSettings, onAction: () => ref.attempt(context, (c) => c.openNotificationSettings())),
          CheckRow(ok: v.allFiles, title: S.permFiles, subtitle: S.permFilesWhy, actionLabel: S.allow, onAction: () => ref.attempt(context, (c) => c.openAllFilesSettings())),
          CheckRow(ok: v.batteryExempt, title: S.permBackground, subtitle: S.permBackgroundWhy, actionLabel: S.allow, onAction: () => ref.attempt(context, (c) => c.requestBatteryExemption())),
          if (v.makerGuide != null) ...[
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Text('${S.makerLine} ${makerHelp(v.makerGuide!)}'))),
          ],
        ]),
      ),
    );
  }
}

/// Short steps for phones that stop background apps (filled in more fully in M6).
String makerHelp(String guide) => switch (guide) {
      'samsung' => 'Settings > Battery > Background usage limits: remove teleBackup from "Sleeping apps", and set it to "Unrestricted".',
      'xiaomi' => 'Settings > Apps > Manage apps > teleBackup: turn on Autostart, and set Battery saver to "No restrictions".',
      'oppo' => 'Settings > Battery > teleBackup: allow background activity and Auto-start.',
      'vivo' => 'Settings > Battery > Background power consumption > teleBackup: allow. Also allow Autostart.',
      'huawei' => 'Settings > Battery > App launch > teleBackup: turn off "Manage automatically" and allow everything.',
      'motorola' => 'Settings > Battery > Battery optimization: set teleBackup to "Not optimized".',
      _ => 'Settings > Apps > teleBackup > Battery: choose "Unrestricted".',
    };

// ---------------------------------------------------------------- S-DIAG

class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(_diagProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(S.diagnostics), bottom: LoadingBar(loading: d.isLoading), actions: [
        if (d.hasValue) ...[
          IconButton(
            tooltip: S.copy,
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: d.value!));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
            },
          ),
          IconButton(tooltip: S.share, icon: const Icon(Icons.share), onPressed: () => SharePlus.instance.share(ShareParams(text: d.value!, subject: 'teleBackup diagnostics'))),
        ],
      ]),
      body: d.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (text) => SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
      ),
    );
  }
}

final _diagProvider = FutureProvider.autoDispose<String>((ref) => guarded(() => ref.watch(coreProvider).diagnostics()));

// ---------------------------------------------------------------- S-DEV

class DevScreen extends ConsumerStatefulWidget {
  const DevScreen({super.key});
  @override
  ConsumerState<DevScreen> createState() => _DevState();
}

class _DevState extends ConsumerState<DevScreen> {
  final _log = <String>[];
  final _arg = TextEditingController();

  @override
  void dispose() {
    _arg.dispose();
    super.dispose();
  }

  Future<void> _cmd(String command, [String? arg]) async {
    final r = await ref.attempt(context, (c) => c.devCommand(command, arg));
    if (r != null && mounted) setState(() => _log.insert(0, '$command: $r'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text(S.developer)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Debug builds only. Use the test group and test folder.'),
          const SizedBox(height: 12),
          TextField(key: const Key('dev-arg'), controller: _arg, decoration: const InputDecoration(labelText: 'Argument (if the button needs one)')),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: () => _cmd('timeWarp', 'on'), child: const Text('Time warp on')),
            OutlinedButton(onPressed: () => _cmd('timeWarp', 'off'), child: const Text('Time warp off')),
            OutlinedButton(onPressed: () => _cmd('scan'), child: const Text('Scan')),
            OutlinedButton(onPressed: () => _cmd('upload'), child: const Text('Upload')),
            OutlinedButton(onPressed: () => _cmd('clean'), child: const Text('Clean')),
            OutlinedButton(onPressed: () => _cmd('queue'), child: const Text('Show queue')),
            OutlinedButton(onPressed: () => _cmd('fault', _arg.text.isEmpty ? '429' : _arg.text), child: const Text('Fail next send')),
            OutlinedButton(onPressed: () => _cmd('addTopic', _arg.text), child: const Text('Add topic id|name')),
            OutlinedButton(onPressed: () => _cmd('setChat', _arg.text), child: const Text('Set chat id')),
            OutlinedButton(
              onPressed: () async {
                if (await confirm(context, title: S.wipeTitle, body: 'This removes every rule, file record and secret.', yes: S.wipe)) {
                  await _cmd('wipe');
                  ref.reload();
                }
              },
              child: const Text('Wipe database'),
            ),
          ]),
          const Divider(height: 32),
          for (final l in _log) Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(l)),
        ]),
      );
}

// Choose where photos of documents go: an existing topic, a new one called Documents, or nowhere.
class _DocumentsTopicDialog extends ConsumerWidget {
  const _DocumentsTopicDialog({required this.current});
  final int? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topics = ref.watch(topicsProvider).value ?? const <Topic>[];
    Future<void> done(Future<void> Function(CoreHostApi c) f) async {
      await ref.attempt(context, f);
      if (context.mounted) Navigator.of(context).pop();
    }

    return SimpleDialog(
      title: const Text(S.documentsTopic),
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(S.documentsTopicHelp, style: Theme.of(context).textTheme.bodySmall)),
        SimpleDialogOption(
          key: const Key('documents-topic-make'),
          onPressed: () => done((c) async { await c.createDocumentsTopic(); }),
          child: const Text(S.documentsTopicMake),
        ),
        RadioGroup<int>(
          groupValue: current,
          onChanged: (v) { if (v != null) done((c) => c.setDocumentsTopic(v)); },
          child: Column(children: [
            for (final t in topics.where((t) => !t.missing)) RadioListTile<int>(value: t.threadId, title: Text(t.name)),
          ]),
        ),
        if (current != null)
          SimpleDialogOption(
            key: const Key('documents-topic-off'),
            onPressed: () => done((c) => c.setDocumentsTopic(null)),
            child: const Text(S.documentsTopicOff),
          ),
      ],
    );
  }
}
