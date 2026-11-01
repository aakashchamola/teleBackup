import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telebackup/bridge/core.dart';
import 'package:telebackup/bridge/fake_core.dart';

import 'helpers.dart';

FileItem file(int id, {FileState state = FileState.verified, String name = 'IMG_1.jpg', String? error, String? link, String? hash}) => FileItem(
      id: id, ruleId: 1, ruleName: 'Shots', displayName: name, path: '/nope/$name', sizeBytes: 3200000, state: state,
      width: 4000, height: 3000, takenAt: DateTime(2026, 11, 1).millisecondsSinceEpoch, sendAs: 'DOCUMENT', shortHash: hash,
      telegramLink: link, queuedAt: DateTime(2026, 11, 1, 3, 12).millisecondsSinceEpoch, uploadedAt: DateTime(2026, 11, 1, 9, 41).millisecondsSinceEpoch,
      verifiedAt: DateTime(2026, 11, 1, 9, 41).millisecondsSinceEpoch, lastError: error, attempts: 0,
    );

EventItem ev(int id, String kind, String msg, {int? fileId, int? bytes, DateTime? at}) =>
    EventItem(id: id, at: (at ?? DateTime.now()).millisecondsSinceEpoch, kind: kind, message: msg, fileId: fileId, ruleId: 1, bytes: bytes);

void main() {
  group('Setup flow', () {
    testWidgets('a family member can walk O1 to O7', (t) async {
      final core = FakeCore();
      core.settings.setupDone = false;
      core.settings.setupStep = 'O1';
      core.permissions = Permissions(notifications: false, allFiles: false, batteryExempt: false, mediaRead: true);
      await pumpApp(t, core: core);
      // O1
      expect(find.text('Free up your phone, keep every photo in your own Telegram.'), findsOneWidget);
      await t.tap(find.byKey(const Key('start-setup')));
      await t.pumpAndSettle();
      // O2: Next is off until all three are granted
      expect(find.text('Permissions'), findsOneWidget);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed, isNull);
      core.permissions = Permissions(notifications: true, allFiles: true, batteryExempt: true, mediaRead: true);
      await t.tap(find.text('Allow').first);   // re-reads the permissions
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed, isNotNull);
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      // O3: a wrong token, then the right one
      expect(find.text('Create your bot'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'wrong');
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('That token did not work. Copy it again from BotFather.'), findsOneWidget);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed, isNull);
      await t.enterText(find.byType(TextField), core.validToken);
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('Connected to @family_photos_bot'), findsOneWidget);
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      // O4
      expect(find.text('Make your private group'), findsOneWidget);
      await t.tap(find.byKey(const Key('find-group')));
      await t.pumpAndSettle();
      expect(find.text('Topics on'), findsOneWidget);
      expect(find.text('Bot is admin'), findsOneWidget);
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(core.calls, contains('selectGroup:-1001'));
      // O5: skip the account
      expect(find.text('Big videos (50 MB and over)'), findsOneWidget);
      await t.tap(find.byKey(const Key('skip-account')));
      await t.pumpAndSettle();
      // O6: suggestions; the Telegram folder is not ticked by default
      expect(find.text('What to back up'), findsOneWidget);
      expect(find.text('Gallery photos'), findsOneWidget);
      await tapText(t, 'Create rules');
      expect(core.rules.map((r) => r.rule.name), containsAll(['Gallery photos', 'Gallery videos', 'Screenshots']));
      expect(core.rules.map((r) => r.rule.name), isNot(contains('Telegram images')));
      expect(core.rules.every((r) => r.rule.mode == RuleMode.uploadOnly), isTrue);
      // O7
      expect(find.text("You're set"), findsOneWidget);
      expect(find.text('Nothing is deleted from your phone until you turn on delete for a rule.'), findsOneWidget);
      await t.tap(find.text('Go to Home'));
      await t.pumpAndSettle();
      expect(core.settings.setupDone, isTrue);
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('it resumes at the saved step', (t) async {
      final core = FakeCore();
      core.settings.setupDone = false;
      core.settings.setupStep = 'O4';
      await pumpApp(t, core: core);
      expect(find.text('Make your private group'), findsOneWidget);
    });

    testWidgets('a group without Topics shows its fix and blocks Next', (t) async {
      final core = FakeCore();
      core.settings.setupDone = false;
      core.settings.setupStep = 'O4';
      core.groupCheck = GroupCheck(chatId: -1001, title: 'My photos backup', topicsOn: false, botIsAdmin: true, botCanManageTopics: true);
      await pumpApp(t, core: core);
      await t.tap(find.byKey(const Key('find-group')));
      await t.pumpAndSettle();
      expect(find.text('Topics are off. Turn on Topics in the group settings, then tap Find again.'), findsOneWidget);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed, isNull);
    });

    testWidgets('no group found says what to do', (t) async {
      final core = FakeCore();
      core.settings.setupDone = false;
      core.settings.setupStep = 'O4';
      core.groups = [];
      await pumpApp(t, core: core);
      await t.tap(find.byKey(const Key('find-group')));
      await t.pumpAndSettle();
      expect(find.textContaining('No group found yet.'), findsOneWidget);
    });

    testWidgets('an unfinished setup sends every tab to setup', (t) async {
      final core = FakeCore();
      core.settings.setupDone = false;
      core.settings.setupStep = 'O1';
      await pumpApp(t, core: core, location: '/rules');
      expect(find.text('Free up your phone, keep every photo in your own Telegram.'), findsOneWidget);
    });
  });

  group('History and files', () {
    testWidgets('empty state', (t) async {
      await pumpApp(t, location: '/history');
      expect(find.text('Nothing yet. Uploads and deletes will show up here.'), findsOneWidget);
    });

    testWidgets('rows are grouped by day and filtered by chips', (t) async {
      final core = FakeCore();
      core.eventItems = [
        ev(5, 'UPLOADED', 'IMG_2041.jpg uploaded', fileId: 5, bytes: 3200000),
        ev(4, 'DELETED', 'Screenshot_0931.png deleted from the phone', fileId: 4, bytes: 400000),
        ev(3, 'SKIPPED', 'VID_0012.mp4 skipped: Telegram refused it 5 times', fileId: 3),
        ev(2, 'SCAN_DONE', 'Gallery photos: 41 new files', at: DateTime.now().subtract(const Duration(days: 1))),
      ];
      await pumpApp(t, core: core, location: '/history');
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('IMG_2041.jpg uploaded'), findsOneWidget);
      await tapText(t, 'Deleted');
      expect(find.text('Screenshot_0931.png deleted from the phone'), findsOneWidget);
      expect(find.text('IMG_2041.jpg uploaded'), findsNothing);
      await tapText(t, 'Skipped');
      await t.pumpAndSettle();
      expect(find.text('VID_0012.mp4 skipped: Telegram refused it 5 times'), findsOneWidget);
    });

    testWidgets('a warning can open History already filtered', (t) async {
      final core = FakeCore();
      core.eventItems = [ev(3, 'SKIPPED', 'VID.mp4 skipped'), ev(2, 'UPLOADED', 'IMG.jpg uploaded')];
      await pumpApp(t, core: core, location: '/history?filter=skipped');
      expect(find.text('VID.mp4 skipped'), findsOneWidget);
      expect(find.text('IMG.jpg uploaded'), findsNothing);
    });

    testWidgets('search by file name', (t) async {
      final core = FakeCore();
      core.eventItems = [ev(3, 'UPLOADED', 'IMG_2041.jpg uploaded'), ev(2, 'UPLOADED', 'IMG_9999.jpg uploaded')];
      await pumpApp(t, core: core, location: '/history');
      await t.tap(find.byIcon(Icons.search));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '9999');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.text('IMG_9999.jpg uploaded'), findsOneWidget);
      expect(find.text('IMG_2041.jpg uploaded'), findsNothing);
    });

    testWidgets('more than 50 rows load a page at a time', (t) async {
      final core = FakeCore();
      core.eventItems = [for (var i = 120; i > 0; i--) ev(i, 'UPLOADED', 'file $i uploaded')];
      await pumpApp(t, core: core, location: '/history');
      expect(find.text('file 120 uploaded'), findsOneWidget);
      await t.dragUntilVisible(find.text('file 55 uploaded'), find.byType(ListView), const Offset(0, -300));
      await t.pumpAndSettle();
      expect(core.calls.where((c) => c.startsWith('listEvents')).length, greaterThan(1));
    });

    testWidgets('file detail: timeline, link, check code', (t) async {
      final core = FakeCore();
      core.fileItems = [file(1, link: 'https://t.me/c/1/5/9', hash: 'a1b2c3d4e5f6')];
      await pumpApp(t, core: core, location: '/file/1');
      expect(find.text('Shots'), findsOneWidget);
      expect(find.text('3.2 MB · 4000 x 3000 · taken 1 Nov 2026'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('Checked'), findsOneWidget);
      expect(find.text('Open in Telegram'), findsOneWidget);
      expect(find.text('Check code: a1b2c3d4e5f6'), findsOneWidget);
    });

    testWidgets('a skipped file shows its reason and Try again', (t) async {
      final core = FakeCore();
      core.fileItems = [file(2, state: FileState.skipped, name: 'VID_0012.mp4', error: 'Telegram refused it')];
      await pumpApp(t, core: core, location: '/file/2');
      expect(find.text('Telegram refused it'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(core.calls, contains('retryFile:2'));
    });

    testWidgets('a deleted file shows a placeholder, not a picture', (t) async {
      final core = FakeCore();
      core.fileItems = [file(3, state: FileState.deleted)];
      await pumpApp(t, core: core, location: '/file/3');
      expect(find.text('Deleted from phone'), findsWidgets);
    });
  });

  group('Review', () {
    Review review({int id = 5, bool preview = false}) => Review(
        id: id, ruleId: 1, ruleName: 'Screenshots', fileCount: 42, totalBytes: 18000000,
        files: [for (var i = 1; i <= 4; i++) file(i, name: 'S$i.png')], preview: preview);

    testWidgets('approve deletes through the core', (t) async {
      final core = FakeCore()..waitingReview = review();
      core.addRule(FakeCore.newRule(name: 'Screenshots', mode: RuleMode.uploadAndDelete));
      await pumpApp(t, core: core, location: '/review/1');
      expect(find.text('These 42 files are backed up and checked in Telegram. teleBackup will delete them from this phone.'), findsOneWidget);
      expect(find.text('Total: 18 MB'), findsOneWidget);
      await t.tap(find.byKey(const Key('approve-review')));
      await t.pumpAndSettle();
      expect(core.calls, contains('approveReview:5'));
    });

    testWidgets('Not now keeps the review', (t) async {
      final core = FakeCore()..waitingReview = review();
      core.addRule(FakeCore.newRule(name: 'Screenshots', mode: RuleMode.uploadAndDelete));
      await pumpApp(t, core: core, location: '/review/1');
      await t.tap(find.text('Not now'));
      await t.pumpAndSettle();
      expect(core.calls.where((c) => c.startsWith('approveReview') || c.startsWith('dismissReview')), isEmpty);
    });
  });

  group('Settings', () {
    testWidgets('mobile data needs a confirm to turn on, none to turn off', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      await t.tap(find.byKey(const Key('mobile-data')));
      await t.pumpAndSettle();
      expect(find.text('Use mobile data for backups?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(core.settings.allowMobileData, isFalse);
      await t.tap(find.byKey(const Key('mobile-data')));
      await t.pumpAndSettle();
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(core.settings.allowMobileData, isTrue);
      await t.tap(find.byKey(const Key('mobile-data')));
      await t.pumpAndSettle();
      expect(core.settings.allowMobileData, isFalse);
    });

    testWidgets('Stop all deletes asks first, then turns every rule to upload only', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'A', mode: RuleMode.uploadAndDelete));
      await pumpApp(t, core: core, location: '/settings');
      await tapText(t, 'Stop all deletes now');
      expect(find.text('Stop all deletes?'), findsOneWidget);
      await t.tap(find.text('Stop deletes'));
      await t.pumpAndSettle();
      expect(core.rules.single.rule.mode, RuleMode.uploadOnly);
    });

    testWidgets('delay options: 1 to 4 choices', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      expect(find.text('2h, 5h'), findsOneWidget);
      await tapText(t, 'Delay options');
      await t.tap(find.text('1 hour'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(core.settings.delayOptionsMinutes, [60, 120, 300]);
    });

    testWidgets('default retention is checked', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      await tapText(t, 'Keep on phone after upload');
      await t.enterText(find.byKey(const Key('retention-days')), '0');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Use 1 to 365 days.'), findsOneWidget);
      await t.enterText(find.byKey(const Key('retention-days')), '30');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(core.settings.defaultRetentionDays, 30);
    });

    testWidgets('import takes pasted rules; a bad file is refused in plain words', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      await tapText(t, 'Import rules');
      await t.enterText(find.byKey(const Key('import-text')), 'nonsense');
      await t.tap(find.text('Import'));
      await t.pumpAndSettle();
      expect(find.text('That is not a teleBackup rules file.'), findsOneWidget);
    });

    testWidgets('the Developer entry only exists in debug builds', (t) async {
      final core = FakeCore();
      core.settings.debugBuild = false;
      await pumpApp(t, core: core, location: '/settings');
      await t.scrollUntilVisible(find.textContaining('About'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Developer'), findsNothing);
    });
  });

  group('Telegram screens', () {
    testWidgets('connection screen shows bot, group checks and account', (t) async {
      final core = FakeCore();
      core.telegram = TelegramState(
        bot: BotInfo(id: 1, username: 'fam_bot', name: 'Fam'),
        group: GroupCheck(chatId: -1001, title: 'My photos backup', topicsOn: true, botIsAdmin: true, botCanManageTopics: true),
        account: AccountState.expired,
      );
      await pumpApp(t, core: core, location: '/telegram');
      expect(find.text('@fam_bot'), findsOneWidget);
      expect(find.text('My photos backup'), findsOneWidget);
      expect(find.text('Logged out. Log in again.'), findsOneWidget);
      expect(find.text('Log in'), findsOneWidget);
    });

    testWidgets('logging out asks first', (t) async {
      final core = FakeCore();
      core.telegram = TelegramState(account: AccountState.ready, accountName: 'Aakash');
      await pumpApp(t, core: core, location: '/telegram');
      await tapText(t, 'Log out');
      expect(find.text('Log out of Telegram account?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Log out'));
      await t.pumpAndSettle();
      expect(core.calls, contains('accountLogout'));
    });

    testWidgets('login walks the four steps', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/telegram/login');
      await t.enterText(find.byKey(const Key('login-api-id')), '1234567');
      await t.enterText(find.byType(TextField).last, 'abcdef');
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('login-phone')), '+919876543210');
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(find.textContaining('Telegram sent a code'), findsOneWidget);
      await t.enterText(find.byKey(const Key('login-code')), '00000');
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(find.text('Wrong code.'), findsOneWidget);
      await t.enterText(find.byKey(const Key('login-code')), '12345');
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(find.text('Logged in as Aakash.'), findsOneWidget);
    });

    testWidgets('permissions screen shows each state and the maker help', (t) async {
      final core = FakeCore();
      core.permissions = Permissions(notifications: true, allFiles: false, batteryExempt: false, mediaRead: true, makerGuide: 'xiaomi');
      await pumpApp(t, core: core, location: '/permissions');
      expect(find.text('All files access'), findsOneWidget);
      expect(find.textContaining('Autostart'), findsOneWidget);
      await t.tap(find.text('Allow').first);
      await t.pumpAndSettle();
      expect(core.calls, contains('openAllFilesSettings'));
    });

    testWidgets('diagnostics shows the text with its header', (t) async {
      await pumpApp(t, location: '/diagnostics');
      expect(find.textContaining('No passwords, tokens or phone numbers are included.'), findsOneWidget);
    });

    testWidgets('developer screen runs a command and logs the answer', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/dev');
      await tapText(t, 'Scan');
      expect(find.text('scan: ok: scan'), findsOneWidget);
    });
  });

  group('Navigation', () {
    testWidgets('the four tabs switch screens and keep Home as the back target', (t) async {
      await pumpApp(t);
      await t.tap(find.text('Rules'));
      await t.pumpAndSettle();
      expect(find.text('No rules yet. A rule picks a folder and the topic it goes to.'), findsOneWidget);
      await t.tap(find.text('History'));
      await t.pumpAndSettle();
      expect(find.text('Nothing yet. Uploads and deletes will show up here.'), findsOneWidget);
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      expect(find.text('Network'), findsOneWidget);
      await t.tap(find.text('Home'));
      await t.pumpAndSettle();
      expect(find.text('All backed up'), findsOneWidget);
    });

    testWidgets('a tapped notification opens its screen', (t) async {
      final core = FakeCore();
      core.addRule(FakeCore.newRule(name: 'Shots'));
      await pumpApp(t, core: core);
      core.events.route.add('rule:1');
      await t.pumpAndSettle();
      expect(find.text('Shots'), findsWidgets);
      core.events.route.add('login');
      await t.pumpAndSettle();
      expect(find.text('Log in to your account'), findsOneWidget);
    });
  });
}
