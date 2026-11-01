import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telebackup/bridge/core.dart';
import 'package:telebackup/bridge/fake_core.dart';

import 'helpers.dart';

void main() {
  group('Home', () {
    testWidgets('shows the status card, today numbers and the last times', (t) async {
      final core = FakeCore();
      core.status = statusWith(todayUploaded: 38, todayFreed: 412000000, queuedCount: 202, todaySkipped: 1, freedTotal: 18400000000);
      await pumpApp(t, core: core);
      expect(find.text('All backed up'), findsOneWidget);
      expect(find.text('38'), findsOneWidget);
      expect(find.text('412 MB'), findsOneWidget);
      expect(find.text('202'), findsOneWidget);
      expect(find.text('Freed so far: 18.4 GB'), findsOneWidget);
      expect(find.text('Last scan:  never'), findsOneWidget);
    });

    testWidgets('Pause and Resume go to the core and the card follows', (t) async {
      final core = FakeCore();
      core.status = statusWith(run: RunState.uploading, filesDone: 1, filesTotal: 3, currentFileName: 'a.jpg');
      await pumpApp(t, core: core);
      await t.tap(find.text('Pause'));
      await t.pumpAndSettle();
      expect(core.calls, contains('pause'));
      expect(find.text('Pausing...'), findsOneWidget);
    });

    testWidgets('delay buttons come from settings', (t) async {
      final core = FakeCore();
      core.settings.delayOptionsMinutes = [60, 180];
      core.status = statusWith(control: ControlState.paused, queuedCount: 5);
      await pumpApp(t, core: core);
      await t.tap(find.text('Delay 3h'));
      await t.pumpAndSettle();
      expect(core.calls, contains('delay:180'));
      expect(find.textContaining('Paused until'), findsOneWidget);
      await t.tap(find.text('Resume now'));
      await t.pumpAndSettle();
      expect(core.calls, contains('resume'));
    });

    testWidgets('warnings carry one action each', (t) async {
      final core = FakeCore();
      core.status = statusWith(attention: [
        Attention(kind: AttentionKind.bigFilesWaitAccount, text: '3 big videos wait for your Telegram account.', count: 3),
        Attention(kind: AttentionKind.reviewWaiting, text: 'Screenshots: 42 files ready to delete. Check first.', ruleId: 7),
        Attention(kind: AttentionKind.notificationsOff, text: 'Notifications are off.'),
      ]);
      await pumpApp(t, core: core);
      expect(find.text('3 big videos wait for your Telegram account.'), findsOneWidget);
      expect(find.text('Log in'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      await t.tap(find.text('Fix'));
      await t.pumpAndSettle();
      expect(core.calls, contains('openNotificationSettings'));
    });

    testWidgets('Scan now and Upload now', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core);
      await tapText(t, 'Scan now');
      await tapText(t, 'Upload now');
      expect(core.calls, containsAll(['scanNow:null', 'uploadNow:false']));
    });

    testWidgets('mobile data once asks first, with the size', (t) async {
      final core = FakeCore();
      core.status = statusWith(run: RunState.waitingNetwork, queuedCount: 240, queuedBytes: 1200000000);
      await pumpApp(t, core: core);
      await t.tap(find.text('Use mobile data once'));
      await t.pumpAndSettle();
      expect(find.text('This uploads 240 files (1.2 GB) on mobile data.'), findsOneWidget);
      await t.tap(find.text(cancelWord));
      await t.pumpAndSettle();
      expect(core.calls, isNot(contains('uploadNow:true')));
      await t.tap(find.text('Use mobile data once'));
      await t.pumpAndSettle();
      await t.tap(find.text('Use mobile data'));
      await t.pumpAndSettle();
      expect(core.calls, contains('uploadNow:true'));
    });

    testWidgets('a core error shows a plain message, never a stack trace', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core);
      core.failNext = AppError('INTERNAL', 'Something went wrong. Try again.');
      await tapText(t, 'Scan now');
      expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    });

    testWidgets('live status pushes update the screen', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core);
      expect(find.text('All backed up'), findsOneWidget);
      core.setStatus(statusWith(run: RunState.uploading, filesDone: 5, filesTotal: 9, currentFileName: 'x.jpg'));
      await t.pumpAndSettle();
      expect(find.text('Backing up'), findsOneWidget);
      expect(find.text('x.jpg'), findsOneWidget);
    });

    testWidgets('works at the largest font size and in the dark theme', (t) async {
      final core = FakeCore();
      core.status = statusWith(control: ControlState.paused, queuedCount: 228, attention: [Attention(kind: AttentionKind.notificationsOff, text: 'Notifications are off.')]);
      await pumpApp(t, core: core, textScale: 2.0, logicalSize: const Size(320, 700), themeMode: ThemeMode.dark);
      expect(takeTestException(t), isNull);
      expect(find.text('Paused'), findsOneWidget);
    });
  });

  group('Rules list', () {
    testWidgets('empty state', (t) async {
      await pumpApp(t, location: '/rules');
      expect(find.text('No rules yet. A rule picks a folder and the topic it goes to.'), findsOneWidget);
      expect(find.text('Add a rule'), findsOneWidget);
    });

    testWidgets('cards show the chips and counts; the switch turns a rule off', (t) async {
      final core = FakeCore();
      final r = FakeCore.newRule(name: 'Screenshots', folder: 'Pictures/Screenshots/', mode: RuleMode.uploadAndDelete);
      r.topicId = 12;
      core.addRule(r, stats: RuleStats(ruleId: 1, queued: 24, backedUp: 600, backedUpBytes: 2100000000, waitingDelete: 9, deleted: 31, freedBytes: 11000000, skipped: 0, topicMissing: false));
      core.addRule(FakeCore.newRule(name: 'WhatsApp video', folder: 'WhatsApp/Media/WhatsApp Video/')..enabled = false);
      await pumpApp(t, core: core, location: '/rules');
      expect(find.text('Screenshots'), findsOneWidget);
      expect(find.text('Upload & delete · 7 days'), findsOneWidget);
      expect(find.text('Media'), findsOneWidget);
      expect(find.text('600 backed up · 24 in queue · 31 deleted'), findsOneWidget);
      expect(find.text('9 waiting to delete'), findsOneWidget);
      expect(find.text('Off. Nothing is scanned.'), findsOneWidget);
      await t.tap(find.byType(Switch).first);
      await t.pumpAndSettle();
      expect(core.calls, contains('setRuleEnabled:1:false'));
    });

    testWidgets('a rule whose deletes are blocked says why', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Shots', mode: RuleMode.uploadAndDelete),
          stats: RuleStats(ruleId: 1, queued: 0, backedUp: 1, backedUpBytes: 1, waitingDelete: 0, deleted: 0, freedBytes: 0, skipped: 0, deleteBlockedReason: 'PERMISSION_LOST', topicMissing: false));
      await pumpApp(t, core: core, location: '/rules');
      expect(find.text('Delete paused: no access to files'), findsOneWidget);
    });
  });

  group('Rule editor', () {
    testWidgets('a name already used is refused in plain words', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Camera'));
      await pumpApp(t, core: core, location: '/rules/new');
      await t.enterText(find.byKey(const Key('rule-name')), 'camera');
      core.suggested; // untouched
      await t.tap(find.byKey(const Key('rule-folder')));
      await t.pumpAndSettle();
      await t.tap(find.text('Gallery photos'));
      await t.pumpAndSettle();
      await tapText(t, 'Save');
      expect(find.text('This name is already used.'), findsOneWidget);
    });

    testWidgets('no folder: "Pick a folder."', (t) async {
      await pumpApp(t, location: '/rules/new');
      await t.enterText(find.byKey(const Key('rule-name')), 'New one');
      await tapText(t, 'Save');
      expect(find.text('Pick a folder.'), findsOneWidget);
    });

    testWidgets('saves a new rule with a new topic and shows the live preview', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/rules/new');
      await t.tap(find.byKey(const Key('rule-folder')));
      await t.pumpAndSettle();
      await t.tap(find.text('Screenshots'));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rule-name')), findsOneWidget);
      expect((t.widget(find.byKey(const Key('rule-name'))) as TextField).controller!.text, isNotEmpty);
      await t.scrollUntilVisible(find.byKey(const Key('rule-preview')), 250, scrollable: find.byType(Scrollable).first);
      expect(find.text('This adds 12 files (3.4 MB), newest first.'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('rule-topic')), -250, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byKey(const Key('rule-topic')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('new-topic')), 'My shots');
      await t.tap(find.text('Use'));
      await t.pumpAndSettle();
      expect(find.text('My shots (new)'), findsOneWidget);
      await tapText(t, 'Save');
      expect(core.rules, hasLength(1));
      expect(core.rules.single.rule.topicId, isNotNull);
      expect(core.calls, contains('saveRule'));
    });

    testWidgets('choosing Delete opens the warning; Turn on delete needs the checkbox', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/rules/new');
      await tapText(t, 'Delete from phone after');
      expect(find.text('Delete from this phone?'), findsOneWidget);
      final turnOn = find.byKey(const Key('delete-turn-on'));
      expect(t.widget<FilledButton>(turnOn).onPressed, isNull);
      await t.tap(find.byKey(const Key('delete-understand')));
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(turnOn).onPressed, isNotNull);
      await t.tap(turnOn);
      await t.pumpAndSettle();
      expect(find.text('First delete needs your check'), findsOneWidget);
    });

    testWidgets('cancelling the warning leaves it on Keep on phone', (t) async {
      await pumpApp(t, location: '/rules/new');
      await tapText(t, 'Delete from phone after');
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('First delete needs your check'), findsNothing);
    });

    testWidgets('editing an existing rule; Delete this rule asks first', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Camera'));
      await pumpApp(t, core: core, location: '/rules/1/edit');
      expect((t.widget(find.byKey(const Key('rule-name'))) as TextField).controller!.text, 'Camera');
      await tapText(t, 'Delete this rule');
      expect(find.text('Delete rule "Camera"?'), findsOneWidget);
      await t.tap(find.text('Delete rule'));
      await t.pumpAndSettle();
      expect(core.rules, isEmpty);
    });
  });

  group('Rule detail', () {
    testWidgets('numbers, topic warning and actions', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Shots', mode: RuleMode.uploadAndDelete),
          stats: RuleStats(ruleId: 1, queued: 24, backedUp: 600, backedUpBytes: 2100000000, waitingDelete: 9, deleted: 31, freedBytes: 11000000, skipped: 2, topicMissing: true));
      await pumpApp(t, core: core, location: '/rules/1');
      expect(find.text('Backed up'), findsOneWidget);
      expect(find.text('600  (2.1 GB)'), findsOneWidget);
      expect(find.text('31  (freed 11 MB)'), findsOneWidget);
      expect(find.text('This topic is gone in Telegram.'), findsOneWidget);
      await t.tap(find.text('Make it again'));
      await t.pumpAndSettle();
      expect(core.calls, contains('remakeTopic:1'));
      await tapText(t, 'Scan now');
      expect(core.calls, contains('scanNow:1'));
    });

    testWidgets('Check what would be deleted opens the preview with Close', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Shots', mode: RuleMode.uploadAndDelete));
      await pumpApp(t, core: core, location: '/rules/1');
      await tapText(t, 'Check what would be deleted');
      expect(find.text('Check before deleting'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Looks right, delete'), findsNothing);
    });
  });
}

const cancelWord = 'Cancel';

Object? takeTestException(WidgetTester t) => t.takeException();
