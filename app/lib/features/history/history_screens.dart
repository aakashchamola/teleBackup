import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/core.dart';
import '../../ui/format.dart';
import '../../ui/run.dart';
import '../../ui/strings.dart';
import '../../ui/widgets/widgets.dart';

// ---------------------------------------------------------------- S-HIST

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.initialFilter, this.ruleId});
  final HistoryFilter? initialFilter;
  final int? ruleId;
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryState();
}

class _HistoryState extends ConsumerState<HistoryScreen> {
  late HistoryFilter _filter = widget.initialFilter ?? HistoryFilter.all;
  final List<EventItem> _items = [];
  int? _cursor;
  bool _loading = true;
  bool _more = true;
  String _search = '';
  bool _searching = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
    });
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HistoryScreen old) {
    super.didUpdateWidget(old);
    if (old.initialFilter != widget.initialFilter || old.ruleId != widget.ruleId) {
      _filter = widget.initialFilter ?? HistoryFilter.all;
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() { _items.clear(); _cursor = null; _more = true; _loading = true; });
    await _loadMore(first: true);
  }

  Future<void> _loadMore({bool first = false}) async {
    if (!first && (_loading || !_more)) return;
    setState(() => _loading = true);
    try {
      final page = await guarded(() => ref.read(coreProvider).listEvents(_filter, _search.isEmpty ? null : _search, widget.ruleId, _cursor));
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _more = page.nextCursor != null;
      });
    } on AppError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _filters = {
    HistoryFilter.all: S.filterAll,
    HistoryFilter.uploaded: S.filterUploaded,
    HistoryFilter.deleted: S.filterDeleted,
    HistoryFilter.skipped: S.filterSkipped,
    HistoryFilter.problems: S.filterProblems,
  };

  @override
  Widget build(BuildContext context) {
    ref.listen(refreshProvider, (_, _) => _reload());
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'File name', border: InputBorder.none),
                onSubmitted: (v) { _search = v.trim(); _reload(); },
              )
            : const Text(S.historyTitle),
        actions: [
          IconButton(
            tooltip: _searching ? S.close : S.find,
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () { setState(() => _searching = !_searching); if (!_searching && _search.isNotEmpty) { _search = ''; _reload(); } },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                for (final e in _filters.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(label: Text(e.value), selected: _filter == e.key, onSelected: (_) { _filter = e.key; _reload(); }),
                  ),
              ]),
            ),
          ),
        ),
      ),
      body: _items.isEmpty && !_loading
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text(S.historyEmpty, textAlign: TextAlign.center)))
          : ListView.builder(
              controller: _scroll,
              itemCount: _items.length + (_loading ? 1 : 0),
              itemBuilder: (c, i) {
                if (i >= _items.length) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                final e = _items[i];
                final newDay = i == 0 || dayHeader(_items[i - 1].at) != dayHeader(e.at);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (newDay) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(dayHeader(e.at), style: Theme.of(context).textTheme.titleSmall)),
                  EventTile(event: e, onTap: () => c.push('/file/${e.fileId}')),
                ]);
              },
            ),
    );
  }
}

// ---------------------------------------------------------------- S-FILE

class FileScreen extends ConsumerWidget {
  const FileScreen({super.key, required this.fileId});
  final int fileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(_fileProvider(fileId));
    return Scaffold(
      appBar: AppBar(title: Text(file.value?.displayName ?? ''), bottom: LoadingBar(loading: file.isLoading)),
      body: file.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => const Center(child: Text(S.somethingWentWrong)),
        data: (f) => ListView(padding: const EdgeInsets.all(16), children: [
          _Thumb(file: f),
          const SizedBox(height: 16),
          Text(f.ruleName, style: Theme.of(context).textTheme.titleMedium),
          Text(_details(f)),
          if (f.sendAs != null) Text('Sent as ${_sendAs(f.sendAs!)}'),
          if (f.lastError != null && (f.state == FileState.skipped || f.state == FileState.failed))
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(f.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
          Text(_stateWords(f.state), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          FileTimeline(file: f),
          const SizedBox(height: 16),
          if (f.telegramLink != null)
            OutlinedButton(onPressed: () => launchUrl(Uri.parse(f.telegramLink!), mode: LaunchMode.externalApplication), child: const Text(S.openInTelegram)),
          if (f.state == FileState.skipped || f.state == FileState.failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton(
                onPressed: () async {
                  await ref.attempt(context, (c) => c.retryFile(f.id));
                  ref.invalidate(_fileProvider(fileId));
                },
                child: const Text(S.tryAgain),
              ),
            ),
          if (f.shortHash != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(S.checkCode(f.shortHash!), style: Theme.of(context).textTheme.bodySmall)),
        ]),
      ),
    );
  }

  String _sendAs(String s) => switch (s) { 'DOCUMENT' => 'original file', 'PHOTO' => 'photo', 'VIDEO' => 'video', _ => s.toLowerCase() };

  String _details(FileItem f) {
    final parts = <String>[sizeText(f.sizeBytes)];
    if (f.width != null && f.height != null) parts.add('${f.width} x ${f.height}');
    if (f.takenAt != null) parts.add('taken ${dateText(f.takenAt!)}');
    return parts.join(' · ');
  }
}

String _stateWords(FileState s) => switch (s) {
      FileState.queued => 'In queue',
      FileState.uploading => 'Uploading',
      FileState.uploaded => 'Uploaded (checking)',
      FileState.verified => 'Backed up',
      FileState.deleted => 'Deleted from phone',
      FileState.failed => 'Will try again',
      FileState.skipped => 'Skipped (tap to retry)',
      FileState.ignored => 'Not backed up (outside the rule)',
      FileState.gone => 'Removed from phone by you',
      FileState.changed => 'Changed after upload (uploaded again as new)',
    };

final _fileProvider = FutureProvider.autoDispose.family<FileItem, int>((ref, id) => guarded(() => ref.watch(coreProvider).getFile(id)));

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});
  final FileItem file;
  @override
  Widget build(BuildContext context) {
    final deleted = file.state == FileState.deleted || file.state == FileState.gone || file.state == FileState.changed;
    final box = BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12));
    if (deleted) {
      return Container(height: 160, decoration: box, alignment: Alignment.center, child: const Text(S.deletedFromPhone));
    }
    final isVideo = file.sendAs == 'VIDEO' || file.displayName.toLowerCase().endsWith('.mp4');
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 200,
        child: isVideo
            ? Container(decoration: box, alignment: Alignment.center, child: const Icon(Icons.play_circle_outline, size: 56))
            : Image.file(File(file.path), fit: BoxFit.cover, cacheWidth: 600, errorBuilder: (_, _, _) => Container(decoration: box, alignment: Alignment.center, child: const Icon(Icons.image_outlined, size: 56))),
      ),
    );
  }
}

// ---------------------------------------------------------------- S-REVIEW

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.ruleId, this.previewOnly = false});
  final int ruleId;
  final bool previewOnly;
  @override
  ConsumerState<ReviewScreen> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<ReviewScreen> {
  Review? _review;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final core = ref.read(coreProvider);
    try {
      final r = await guarded(() async => widget.previewOnly ? await core.previewDeletes(widget.ruleId) : (await core.getReview(widget.ruleId) ?? await core.previewDeletes(widget.ruleId)));
      if (mounted) setState(() => _review = r);
    } on AppError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _approve() async {
    final r = _review!;
    setState(() => _busy = true);
    final ok = await ref.attempt(context, (c) => c.approveReview(r.id).then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      ref.reload();
      context.leave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _review;
    final preview = r?.preview ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text(S.reviewTitle), bottom: LoadingBar(loading: _loading || _busy)),
      body: r == null
          ? const SizedBox.shrink()
          : Column(children: [
              Expanded(
                child: CustomScrollView(slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverList.list(children: [
                      Text(r.ruleName, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(r.fileCount == 0 ? 'Nothing is ready to delete yet.' : S.reviewBody(r.fileCount)),
                      const SizedBox(height: 4),
                      Text(S.reviewTotal(sizeText(r.totalBytes))),
                      const SizedBox(height: 12),
                      if (r.files.isNotEmpty) const Text(S.reviewTap),
                    ]),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 100, mainAxisSpacing: 6, crossAxisSpacing: 6),
                      itemCount: r.files.length,
                      itemBuilder: (c, i) {
                        final f = r.files[i];
                        return Semantics(
                          label: f.displayName,
                          button: true,
                          child: InkWell(
                            onTap: () => c.push('/file/${f.id}'),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: f.displayName.toLowerCase().endsWith('.mp4')
                                  ? Container(color: Theme.of(c).colorScheme.surfaceContainerHighest, child: const Icon(Icons.play_circle_outline))
                                  : Image.file(File(f.path), fit: BoxFit.cover, cacheWidth: 200, errorBuilder: (_, _, _) => Container(color: Theme.of(c).colorScheme.surfaceContainerHighest, child: const Icon(Icons.image_outlined))),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ]),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: preview
                      ? Wrap(alignment: WrapAlignment.end, children: [FilledButton(onPressed: () => context.leave(), child: const Text(S.close))])
                      : Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                          TextButton(onPressed: _busy ? null : () => context.leave(), child: const Text(S.notNow)),
                          FilledButton(key: const Key('approve-review'), onPressed: _busy ? null : _approve, child: const Text(S.looksRight)),
                        ]),
                ),
              ),
            ]),
    );
  }
}
