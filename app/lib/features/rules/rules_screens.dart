import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/core.dart';
import '../../ui/format.dart';
import '../../ui/run.dart';
import '../../ui/strings.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/widgets.dart';

String folderLabel(String path) {
  // iPhone albums: "smart:recents", "smart:screenshots", "album:<id>|<title>"
  if (path.startsWith('smart:')) {
    const names = {'recents': 'Camera Roll', 'screenshots': 'Screenshots', 'videos': 'Videos', 'selfies': 'Selfies', 'panoramas': 'Panoramas'};
    return names[path.substring(6)] ?? path.substring(6);
  }
  if (path.startsWith('album:')) {
    final i = path.indexOf('|');
    return i >= 0 ? path.substring(i + 1) : 'Album';
  }
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

String typesWords(MediaTypes t) => switch (t) { MediaTypes.photos => 'photos', MediaTypes.videos => 'videos', MediaTypes.both => 'photos and videos' };

// ---------------------------------------------------------------- S-RULES

class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(rulesProvider);
    final topics = ref.watch(topicsProvider).value ?? const <Topic>[];
    return Scaffold(
      appBar: AppBar(title: const Text(S.rulesTitle), bottom: LoadingBar(loading: rules.isLoading)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/rules/new'),
        icon: const Icon(Icons.add),
        label: const Text('Rule'),
      ),
      body: rules.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(S.rulesEmpty, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => context.push('/rules/new'), child: const Text(S.addRule)),
                ]),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (c, i) => RuleCard(item: list[i], topics: topics),
          );
        },
      ),
    );
  }
}

class RuleCard extends ConsumerWidget {
  const RuleCard({super.key, required this.item, this.topics = const []});
  final RuleWithStats item;
  final List<Topic> topics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = item.rule;
    final st = item.stats;
    final theme = Theme.of(context).textTheme;
    final topic = topics.where((t) => t.threadId == r.topicId).map((t) => t.name).firstOrNull ?? (r.topicId == null ? 'General' : 'topic ${r.topicId}');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/rules/${r.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(r.name, style: theme.titleMedium)),
              Switch(
                value: r.enabled,
                onChanged: (v) async {
                  await ref.attempt(context, (c) => c.setRuleEnabled(r.id!, v));
                  ref.invalidate(rulesProvider);
                },
              ),
            ]),
            if (!r.enabled)
              const Text(S.ruleOffNote)
            else ...[
              Text('${folderLabel(r.folderPath)} · ${typesWords(r.mediaTypes)}'),
              Text('Topic: $topic'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                ModeChip(mode: r.mode, retentionDays: r.retentionDays, blockedReason: st.deleteBlockedReason),
                FormChip(uploadAs: r.uploadAs),
              ]),
              const SizedBox(height: 6),
              Text(_counts(st), style: theme.bodySmall),
              if (st.waitingDelete > 0) Text('${st.waitingDelete} waiting to delete', style: theme.bodySmall),
              if (st.topicMissing) Text('Topic gone in Telegram', style: theme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.attention)),
            ],
          ]),
        ),
      ),
    );
  }

  String _counts(RuleStats s) {
    final parts = <String>['${s.backedUp} backed up'];
    if (s.queued > 0) parts.add('${s.queued} in queue');
    if (s.deleted > 0) parts.add('${s.deleted} deleted');
    return parts.join(' · ');
  }
}

// ---------------------------------------------------------------- S-RULE

class RuleDetailScreen extends ConsumerWidget {
  const RuleDetailScreen({super.key, required this.ruleId});
  final int ruleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(refreshProvider);
    final future = ref.watch(_ruleProvider(ruleId));
    final topics = ref.watch(topicsProvider).value ?? const <Topic>[];
    final tg = ref.watch(telegramStateProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: Text(future.value?.rule.name ?? ''),
        bottom: LoadingBar(loading: future.isLoading),
        actions: [
          if (future.hasValue) TextButton(onPressed: () => context.push('/rules/$ruleId/edit'), child: const Text('Edit')),
        ],
      ),
      body: future.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (item) {
          final r = item.rule;
          final st = item.stats;
          final topic = topics.where((t) => t.threadId == r.topicId).map((t) => t.name).firstOrNull ?? 'General';
          final chat = tg?.group?.chatId;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${folderLabel(r.folderPath)} · ${typesWords(r.mediaTypes)}'),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: Text('Topic: $topic')),
              if (chat != null && r.topicId != null)
                TextButton(onPressed: () => launchUrl(Uri.parse('https://t.me/c/${chat.toString().replaceFirst('-100', '')}/${r.topicId}')), child: const Text('Open in Telegram')),
            ]),
            if (st.topicMissing)
              WarningRow(
                text: 'This topic is gone in Telegram.',
                actionLabel: 'Make it again',
                onAction: () async {
                  await ref.attempt(context, (c) => c.remakeTopic(ruleId));
                  ref.reload();
                },
              ),
            const SizedBox(height: 4),
            ModeChip(mode: r.mode, retentionDays: r.retentionDays, blockedReason: st.deleteBlockedReason),
            const SizedBox(height: 4),
            Text('Sent as: ${r.uploadAs == UploadAs.media ? S.media : S.originalFile}'),
            Text('Backing up from: ${_from(r)}'),
            const SizedBox(height: 16),
            _row(context, S.inQueue, '${st.queued}'),
            _row(context, 'Backed up', '${st.backedUp}  (${sizeText(st.backedUpBytes)})'),
            _row(context, 'Waiting to delete', '${st.waitingDelete}'),
            _row(context, 'Deleted', '${st.deleted}  (freed ${sizeText(st.freedBytes)})'),
            _row(context, S.skipped, '${st.skipped}'),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => ref.attempt(context, (c) => c.scanNow(ruleId)), child: const Text(S.scanNow)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => context.push('/review/$ruleId?preview=1'), child: const Text('Check what would be deleted')),
            const SizedBox(height: 8),
            TextButton(onPressed: () => context.go('/history?rule=$ruleId'), child: const Text('See history for this rule')),
          ]);
        },
      ),
    );
  }

  String _from(Rule r) => switch (r.startMode) {
        StartMode.today => r.startDate == null ? 'today' : dateText(r.startDate!),
        StartMode.sinceDate => r.startDate == null ? '' : dateText(r.startDate!),
        StartMode.everything => 'everything',
      };

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [SizedBox(width: 160, child: Text(label)), Expanded(child: Text(value, style: Theme.of(context).textTheme.titleMedium))]),
      );
}

final _ruleProvider = FutureProvider.autoDispose.family<RuleWithStats, int>((ref, id) {
  ref.watch(refreshProvider);
  return guarded(() => ref.watch(coreProvider).getRule(id));
});

// ---------------------------------------------------------------- S-EDIT

class RuleEditScreen extends ConsumerStatefulWidget {
  const RuleEditScreen({super.key, this.ruleId});
  final int? ruleId;

  @override
  ConsumerState<RuleEditScreen> createState() => _RuleEditState();
}

class _RuleEditState extends ConsumerState<RuleEditScreen> {
  final _name = TextEditingController();
  final _days = TextEditingController(text: '7');
  Rule _rule = Rule(
    name: '',
    folderPath: '',
    includeSubfolders: false,
    mediaTypes: MediaTypes.both,
    uploadAs: UploadAs.media,
    mode: RuleMode.uploadOnly,
    retentionDays: 7,
    startMode: StartMode.today,
    enabled: true,
    dryRun: true,
    deleteWarningAccepted: false,
  );
  String _topicLabel = 'General';
  bool _loaded = false;
  bool _saving = false;
  BacklogPreview? _preview;
  final Map<String, String> _errors = {};
  Future<void>? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await ref.read(settingsProvider.future);
    if (widget.ruleId != null) {
      final item = await ref.read(coreProvider).getRule(widget.ruleId!);
      _rule = item.rule;
    } else {
      _rule.retentionDays = settings.defaultRetentionDays;
    }
    final topics = await ref.read(topicsProvider.future);
    _topicLabel = topics.where((t) => t.threadId == _rule.topicId).map((t) => t.name).firstOrNull ?? 'General';
    _name.text = _rule.name;
    _days.text = '${_rule.retentionDays}';
    if (mounted) {
      setState(() => _loaded = true);
      _updatePreview();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _days.dispose();
    super.dispose();
  }

  /// Live line under "Back up from" (debounced 300 ms).
  void _updatePreview() {
    final stamp = _pending = Future.delayed(const Duration(milliseconds: 300));
    stamp.then((_) async {
      if (!mounted || _pending != stamp || _rule.folderPath.isEmpty) return;
      final p = await ref.read(coreProvider).previewRule(_rule).catchError((_) => BacklogPreview(count: 0, bytes: 0));
      if (mounted) setState(() => _preview = p);
    });
  }

  Future<void> _pickFolder() async {
    final path = await context.push<String>('/folder');
    if (path == null) return;
    setState(() {
      _rule.folderPath = path;
      if (_rule.name.trim().isEmpty && widget.ruleId == null) {
        _rule.name = _guessName(path);
        _name.text = _rule.name;
      }
      if (widget.ruleId == null) _rule.uploadAs = path.startsWith('DCIM/') ? UploadAs.original : UploadAs.media;
      _errors.remove('folder');
    });
    _updatePreview();
  }

  String _guessName(String path) {
    final parts = folderLabel(path).split('/');
    return parts.last;
  }

  Future<void> _pickTopic() async {
    final r = await context.push<({int? id, String? newName, String label})>('/topic', extra: {'name': _rule.name});
    if (r == null) return;
    setState(() {
      _rule.topicId = r.id;
      _rule.newTopicName = r.newName;
      _topicLabel = r.label;
    });
  }

  Future<void> _chooseDelete(bool on) async {
    if (!on) {
      setState(() { _rule.mode = RuleMode.uploadOnly; _errors.remove('mode'); });
      return;
    }
    final days = int.tryParse(_days.text) ?? _rule.retentionDays;
    final ok = await showDialog<bool>(context: context, builder: (c) => _DeleteOnDialog(days: days)) ?? false;
    if (ok) setState(() { _rule.mode = RuleMode.uploadAndDelete; _rule.deleteWarningAccepted = true; _errors.remove('mode'); });
  }

  Future<void> _save() async {
    _rule.name = _name.text.trim();
    _rule.retentionDays = int.tryParse(_days.text) ?? _rule.retentionDays;
    setState(() { _saving = true; _errors.clear(); });
    try {
      await guarded(() => ref.read(coreProvider).saveRule(_rule));
      ref.reload();
      if (mounted) context.leave();
    } on AppError catch (e) {
      if (!mounted) return;
      if (e.isValidation && e.details != null) {
        setState(() => _errors[e.details!] = e.message);
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final ok = await confirm(context, title: S.removeRuleTitle(_rule.name), body: S.removeRuleBody, yes: S.deleteRule);
    if (!ok || !mounted) return;
    final done = await ref.attempt(context, (c) => c.deleteRule(_rule.id!).then((_) => true));
    if (done == true) {
      ref.reload();
      if (mounted) context.go('/rules');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.ruleId == null;
    final del = _rule.mode == RuleMode.uploadAndDelete;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? S.newRule : S.editRule),
        bottom: LoadingBar(loading: !_loaded || _saving),
        actions: [TextButton(onPressed: _loaded && !_saving ? _save : null, child: const Text(S.save))],
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : ListView(padding: const EdgeInsets.all(16), children: [
              TextField(
                key: const Key('rule-name'),
                controller: _name,
                maxLength: 40,
                decoration: InputDecoration(labelText: S.ruleName, errorText: _errors['name']),
                onChanged: (v) => setState(() => _errors.remove('name')),
              ),
              const SizedBox(height: 8),
              Text(S.folder, style: Theme.of(context).textTheme.labelLarge),
              ListTile(
                key: const Key('rule-folder'),
                contentPadding: EdgeInsets.zero,
                title: Text(_rule.folderPath.isEmpty ? 'Pick a folder' : folderLabel(_rule.folderPath)),
                subtitle: _errors['folder'] == null ? null : Text(_errors['folder']!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickFolder,
              ),
              if (!Platform.isIOS) // albums have no folders inside
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _rule.includeSubfolders,
                title: const Text(S.includeSubfolders),
                onChanged: (v) { setState(() => _rule.includeSubfolders = v ?? false); _updatePreview(); },
              ),
              if (!Platform.isIOS) // the document detector is not on iPhone
              SwitchListTile(
                key: const Key('rule-sort-documents'),
                contentPadding: EdgeInsets.zero,
                value: _rule.sortDocuments,
                title: const Text(S.sortDocuments),
                subtitle: Text(ref.watch(settingsProvider).value?.documentsTopicId == null ? S.sortDocumentsNeedsTopic : S.sortDocumentsHelp),
                onChanged: (v) => setState(() => _rule.sortDocuments = v),
              ),
              const SizedBox(height: 8),
              Text(S.fileTypes, style: Theme.of(context).textTheme.labelLarge),
              RadioGroup<MediaTypes>(
                groupValue: _rule.mediaTypes,
                onChanged: (v) { setState(() => _rule.mediaTypes = v ?? _rule.mediaTypes); _updatePreview(); },
                child: Column(children: const [
                  RadioListTile<MediaTypes>(value: MediaTypes.both, title: Text(S.photosAndVideos), contentPadding: EdgeInsets.zero),
                  RadioListTile<MediaTypes>(value: MediaTypes.photos, title: Text(S.photosOnly), contentPadding: EdgeInsets.zero),
                  RadioListTile<MediaTypes>(value: MediaTypes.videos, title: Text(S.videosOnly), contentPadding: EdgeInsets.zero),
                ]),
              ),
              Text(S.telegramTopic, style: Theme.of(context).textTheme.labelLarge),
              ListTile(
                key: const Key('rule-topic'),
                contentPadding: EdgeInsets.zero,
                title: Text(_rule.newTopicName != null ? '${_rule.newTopicName} (new)' : _topicLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickTopic,
              ),
              const SizedBox(height: 8),
              Text(S.sendAs, style: Theme.of(context).textTheme.labelLarge),
              RadioGroup<UploadAs>(
                groupValue: _rule.uploadAs,
                onChanged: (v) => setState(() => _rule.uploadAs = v ?? _rule.uploadAs),
                child: Column(children: const [
                  RadioListTile<UploadAs>(value: UploadAs.media, title: Text(S.sendAsMediaHelp), contentPadding: EdgeInsets.zero),
                  RadioListTile<UploadAs>(value: UploadAs.original, title: Text(S.sendAsOriginalHelp), contentPadding: EdgeInsets.zero),
                ]),
              ),
              const SizedBox(height: 8),
              Text(S.backUpFrom, style: Theme.of(context).textTheme.labelLarge),
              RadioGroup<StartMode>(
                groupValue: _rule.startMode,
                onChanged: (v) { setState(() => _rule.startMode = v ?? _rule.startMode); _updatePreview(); },
                child: Column(children: [
                  const RadioListTile<StartMode>(value: StartMode.today, title: Text('Today on'), contentPadding: EdgeInsets.zero),
                  const RadioListTile<StartMode>(value: StartMode.everything, title: Text(S.fromEverything), contentPadding: EdgeInsets.zero),
                  RadioListTile<StartMode>(
                    value: StartMode.sinceDate,
                    contentPadding: EdgeInsets.zero,
                    title: Row(children: [
                      const Text('Since '),
                      TextButton(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: DateTime.fromMillisecondsSinceEpoch(_rule.startDate ?? DateTime.now().millisecondsSinceEpoch),
                            firstDate: DateTime(2010),
                            lastDate: DateTime.now(),
                          );
                          if (d != null) { setState(() { _rule.startMode = StartMode.sinceDate; _rule.startDate = d.millisecondsSinceEpoch; }); _updatePreview(); }
                        },
                        child: Text(_rule.startDate == null ? 'pick a date' : dateText(_rule.startDate!)),
                      ),
                    ]),
                  ),
                ]),
              ),
              if (_preview != null)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(S.previewLine(_preview!.count, sizeText(_preview!.bytes)), key: const Key('rule-preview'))),
              const SizedBox(height: 8),
              Text(S.afterUpload, style: Theme.of(context).textTheme.labelLarge),
              RadioGroup<bool>(
                groupValue: del,
                onChanged: (v) => _chooseDelete(v ?? false),
                child: Column(children: [
                  const RadioListTile<bool>(key: Key('mode-keep'), value: false, title: Text(S.keepOnPhone), contentPadding: EdgeInsets.zero),
                  RadioListTile<bool>(
                    key: const Key('mode-delete'),
                    value: true,
                    contentPadding: EdgeInsets.zero,
                    title: Row(children: [
                      const Flexible(child: Text(S.deleteFromPhone)),
                      const SizedBox(width: 8),
                      SizedBox(width: 56, child: TextField(controller: _days, keyboardType: TextInputType.number, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true))),
                      const SizedBox(width: 6),
                      const Text(S.days),
                    ]),
                  ),
                ]),
              ),
              if (_errors['mode'] != null) Text(_errors['mode']!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (del)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _rule.dryRun,
                  title: const Text(S.firstDeleteCheck),
                  onChanged: (v) => setState(() => _rule.dryRun = v ?? true),
                ),
              if (!isNew) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _remove,
                  style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  child: const Text(S.deleteThisRule),
                ),
              ],
            ]),
    );
  }
}

/// D-DELETE-ON: the warning that comes before a rule may delete (docs/UI.md "Dialogs").
class _DeleteOnDialog extends StatefulWidget {
  const _DeleteOnDialog({required this.days});
  final int days;
  @override
  State<_DeleteOnDialog> createState() => _DeleteOnDialogState();
}

class _DeleteOnDialogState extends State<_DeleteOnDialog> {
  bool _ok = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(S.deleteOnTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.deleteOnBody(widget.days)),
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('delete-understand'),
              contentPadding: EdgeInsets.zero,
              value: _ok,
              title: const Text(S.deleteOnCheck),
              onChanged: (v) => setState(() => _ok = v ?? false),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(S.cancel)),
          FilledButton(key: const Key('delete-turn-on'), onPressed: _ok ? () => Navigator.pop(context, true) : null, child: const Text(S.turnOnDelete)),
        ],
      );
}

// ---------------------------------------------------------------- S-FOLDER

class FolderScreen extends ConsumerStatefulWidget {
  const FolderScreen({super.key});
  @override
  ConsumerState<FolderScreen> createState() => _FolderState();
}

class _FolderState extends ConsumerState<FolderScreen> {
  String _path = '';
  late Future<List<FolderInfo>> _suggested;
  late Future<List<FolderInfo>> _browse;

  @override
  void initState() {
    super.initState();
    _suggested = guarded(() => ref.read(coreProvider).suggestedFolders());
    _browse = guarded(() => ref.read(coreProvider).listFolder(''));
  }

  void _open(String path) => setState(() { _path = path; _browse = guarded(() => ref.read(coreProvider).listFolder(path)); });

  String _up() {
    final parts = folderLabel(_path).split('/')..removeLast();
    return parts.isEmpty ? '' : '${parts.join('/')}/';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pick a folder')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (_path.isEmpty) ...[
            Text('Suggested', style: Theme.of(context).textTheme.titleMedium),
            FutureBuilder<List<FolderInfo>>(
              future: _suggested,
              builder: (c, snap) => Column(children: [
                for (final f in (snap.data ?? const <FolderInfo>[]))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.label),
                    subtitle: Text([folderLabel(f.path.split('?').first), if (f.usedByRule != null) '(used by ${f.usedByRule})', if (f.hint != null) f.hint!].join('  ')),
                    trailing: Text('${f.mediaCount}'),
                    onTap: () => context.pop(f.path.split('?').first),
                  ),
              ]),
            ),
            const Divider(),
          ],
          Text('Browse', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open),
            title: Text(_path.isEmpty ? '/ (phone storage)' : '/${folderLabel(_path)}'),
            trailing: _path.isEmpty ? null : IconButton(tooltip: S.back, icon: const Icon(Icons.arrow_upward), onPressed: () => _open(_up())),
          ),
          FutureBuilder<List<FolderInfo>>(
            future: _browse,
            builder: (c, snap) => Column(children: [
              for (final f in (snap.data ?? const <FolderInfo>[]))
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 16),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.label),
                  subtitle: f.usedByRule == null ? null : Text('(used by ${f.usedByRule})'),
                  trailing: Text('${f.mediaCount}'),
                  onTap: () => _open(f.path),
                ),
            ]),
          ),
          if (_path.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FilledButton(onPressed: () => context.pop(_path), child: const Text('Use this folder'))),
        ]),
      );
}

// ---------------------------------------------------------------- S-TOPIC

class TopicScreen extends ConsumerStatefulWidget {
  const TopicScreen({super.key, this.suggestedName = ''});
  final String suggestedName;
  @override
  ConsumerState<TopicScreen> createState() => _TopicState();
}

class _TopicState extends ConsumerState<TopicScreen> {
  late final TextEditingController _new = TextEditingController(text: widget.suggestedName);

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topics = ref.watch(topicsProvider).value ?? const <Topic>[];
    return Scaffold(
      appBar: AppBar(title: const Text(S.telegramTopic)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('New topic', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(key: const Key('new-topic'), controller: _new, maxLength: 60, decoration: const InputDecoration(labelText: 'Name'))),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => _new.text.trim().isEmpty ? null : context.pop((id: null, newName: _new.text.trim(), label: _new.text.trim())),
            child: const Text('Use'),
          ),
        ]),
        const Divider(),
        Text('Topics made by teleBackup', style: Theme.of(context).textTheme.titleMedium),
        for (final t in topics)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tag),
            title: Text(t.name),
            subtitle: t.missing ? const Text('Gone in Telegram') : null,
            onTap: () => context.pop((id: t.threadId, newName: null, label: t.name)),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.forum_outlined),
          title: const Text("General (the group's main chat)"),
          onTap: () => context.pop((id: null, newName: null, label: 'General')),
        ),
      ]),
    );
  }
}
