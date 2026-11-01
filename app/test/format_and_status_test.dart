import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telebackup/bridge/core.dart';
import 'package:telebackup/bridge/fake_core.dart';
import 'package:telebackup/ui/format.dart';
import 'package:telebackup/ui/widgets/widgets.dart';

void main() {
  group('sizeText', () {
    test('picks the unit', () {
      expect(sizeText(0), '0 B');
      expect(sizeText(640), '640 B');
      expect(sizeText(640000), '640 KB');
      expect(sizeText(3200000), '3.2 MB');
      expect(sizeText(412000000), '412 MB');
      expect(sizeText(1200000000), '1.2 GB');
      expect(sizeText(18400000000), '18.4 GB');
      expect(sizeText(-5), '0 B');
    });
  });

  group('timeText', () {
    final now = DateTime(2026, 11, 8, 12, 0);
    int at(DateTime d) => d.millisecondsSinceEpoch;
    test('recent', () {
      expect(timeText(null, now: now), 'never');
      expect(timeText(at(now.subtract(const Duration(seconds: 20))), now: now), 'just now');
      expect(timeText(at(now.subtract(const Duration(minutes: 1))), now: now), '1 minute ago');
      expect(timeText(at(now.subtract(const Duration(minutes: 2))), now: now), '2 minutes ago');
    });
    test('today, yesterday and older', () {
      expect(timeText(at(DateTime(2026, 11, 8, 3, 12)), now: now), 'today 03:12');
      expect(timeText(at(DateTime(2026, 11, 7, 8, 10)), now: now), 'yesterday 08:10');
      expect(timeText(at(DateTime(2026, 11, 1, 8, 10)), now: now), '1 Nov');
      expect(timeText(at(DateTime(2025, 11, 1, 8, 10)), now: now), '1 Nov 2025');
    });
    test('day headers', () {
      expect(dayHeader(at(DateTime(2026, 11, 8, 9)), now: now), 'Today');
      expect(dayHeader(at(DateTime(2026, 11, 7, 9)), now: now), 'Yesterday');
      expect(dayHeader(at(DateTime(2026, 11, 3, 9)), now: now), 'Tuesday 3 Nov');
    });
  });

  test('delay labels and words', () {
    expect(delayLabel(120), 'Delay 2h');
    expect(delayLabel(300), 'Delay 5h');
    expect(delayLabel(45), 'Delay 45 min');
    expect(delayWords(60), '1 hour');
    expect(delayWords(120), '2 hours');
    expect(delayWords(45), '45 minutes');
    expect(plural(1, 'file'), '1 file');
    expect(plural(2, 'file'), '2 files');
  });

  group('statusCardKind (first match wins)', () {
    StatusCardKind kind(Status s, {bool setup = true}) => statusCardKind(s, setupDone: setup);
    test('setup first', () => expect(kind(statusWith(run: RunState.uploading), setup: false), StatusCardKind.notSetUp));
    test('lost files access blocks everything else', () {
      final s = statusWith(run: RunState.uploading, attention: [Attention(kind: AttentionKind.allFilesLost, text: 'x')]);
      expect(kind(s), StatusCardKind.blocked);
    });
    test('uploading', () => expect(kind(statusWith(run: RunState.uploading)), StatusCardKind.uploading));
    test('pausing', () => expect(kind(statusWith(run: RunState.pausing)), StatusCardKind.pausing));
    test('paused while a file finishes reads as pausing', () => expect(kind(statusWith(control: ControlState.paused, run: RunState.uploading)), StatusCardKind.pausing));
    test('paused', () => expect(kind(statusWith(control: ControlState.paused)), StatusCardKind.paused));
    test('delayed', () => expect(kind(statusWith(control: ControlState.delayed, delayedUntil: 1)), StatusCardKind.delayed));
    test('scanning', () => expect(kind(statusWith(run: RunState.scanning)), StatusCardKind.scanning));
    test('waiting for wifi', () => expect(kind(statusWith(run: RunState.waitingNetwork, queuedCount: 5)), StatusCardKind.waitingWifi));
    test('done for today', () => expect(kind(statusWith(run: RunState.stoppedTimeLimit)), StatusCardKind.stoppedToday));
    test('up to date', () => expect(kind(statusWith()), StatusCardKind.upToDate));
  });

  group('StatusCard words', () {
    Future<void> show(WidgetTester t, Status s, {bool setup = true, List<int> delays = const [120, 300], StatusCardActions actions = const StatusCardActions()}) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: StatusCard(status: s, setupDone: setup, delayOptions: delays, actions: actions))));

    testWidgets('uploading shows counts, bar and file name', (t) async {
      await show(t, statusWith(run: RunState.uploading, filesDone: 12, filesTotal: 240, queuedBytes: 1200000000, currentFileName: 'IMG_1.jpg'));
      expect(find.text('Backing up'), findsOneWidget);
      expect(find.text('12 of 240 files · 1.2 GB left'), findsOneWidget);
      expect(find.text('IMG_1.jpg'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
    });

    testWidgets('a big file shows its own bytes', (t) async {
      await show(t, statusWith(run: RunState.uploading, filesDone: 1, filesTotal: 3, bytesDone: 340000000, bytesTotal: 812000000, currentFileName: 'VID.mp4'));
      expect(find.text('VID.mp4 · 340 MB of 812 MB'), findsOneWidget);
    });

    testWidgets('paused shows the delay buttons and Resume', (t) async {
      await show(t, statusWith(control: ControlState.paused, queuedCount: 228), delays: [120, 300]);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('228 files waiting.'), findsOneWidget);
      expect(find.text('Delay 2h'), findsOneWidget);
      expect(find.text('Delay 5h'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets('delay labels follow the settings', (t) async {
      await show(t, statusWith(control: ControlState.paused), delays: [30, 60]);
      expect(find.text('Delay 30 min'), findsOneWidget);
      expect(find.text('Delay 1h'), findsOneWidget);
    });

    testWidgets('delayed shows the time and Resume now', (t) async {
      final until = DateTime(2026, 11, 8, 18, 30).millisecondsSinceEpoch;
      await show(t, statusWith(control: ControlState.delayed, delayedUntil: until));
      expect(find.text('Paused until 18:30'), findsOneWidget);
      expect(find.text('Resumes by itself.'), findsOneWidget);
      expect(find.text('Resume now'), findsOneWidget);
    });

    testWidgets('waiting for Wi-Fi offers mobile data once', (t) async {
      await show(t, statusWith(run: RunState.waitingNetwork, queuedCount: 240));
      expect(find.text('Waiting for Wi-Fi'), findsOneWidget);
      expect(find.text('240 files ready. Starts when you are on Wi-Fi.'), findsOneWidget);
      expect(find.text('Use mobile data once'), findsOneWidget);
    });

    testWidgets('the other variants', (t) async {
      await show(t, statusWith(), setup: false);
      expect(find.text('Setup not finished'), findsOneWidget);
      expect(find.text('Continue setup'), findsOneWidget);
      await show(t, statusWith(run: RunState.pausing, currentFileName: 'IMG_2041.jpg'));
      expect(find.text('Pausing...'), findsOneWidget);
      expect(find.text('Finishing IMG_2041.jpg first.'), findsOneWidget);
      await show(t, statusWith(run: RunState.scanning));
      expect(find.text('Checking folders'), findsOneWidget);
      await show(t, statusWith(run: RunState.stoppedTimeLimit));
      expect(find.text('Done for today'), findsOneWidget);
      await show(t, statusWith());
      expect(find.text('All backed up'), findsOneWidget);
      expect(find.text('Next check tonight.'), findsOneWidget);
      await show(t, statusWith(attention: [Attention(kind: AttentionKind.allFilesLost, text: 'teleBackup lost All files access.')]));
      expect(find.text('Backup stopped'), findsOneWidget);
      expect(find.text('teleBackup lost All files access.'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
    });

    testWidgets('the card is read as one sentence', (t) async {
      final h = t.ensureSemantics();
      await show(t, statusWith(run: RunState.uploading, filesDone: 12, filesTotal: 240, queuedBytes: 1200000000));
      expect(find.bySemanticsLabel('Backing up, 12 of 240 files, 1.2 gigabytes left'), findsOneWidget);
      h.dispose();
    });

    testWidgets('buttons call back', (t) async {
      var paused = false;
      var resumed = false;
      int? delayed;
      await show(t, statusWith(run: RunState.uploading), actions: StatusCardActions(onPause: () => paused = true));
      await t.tap(find.text('Pause'));
      expect(paused, isTrue);
      await show(t, statusWith(control: ControlState.paused), actions: StatusCardActions(onResume: () => resumed = true, onDelay: (m) => delayed = m));
      await t.tap(find.text('Delay 5h'));
      await t.tap(find.text('Resume'));
      expect(delayed, 300);
      expect(resumed, isTrue);
    });
  });
}
