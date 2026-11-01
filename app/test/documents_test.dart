import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telebackup/bridge/fake_core.dart';

import 'helpers.dart';

void main() {
  group('Sending settings', () {
    testWidgets('grouping a day\'s photos is on by default and can be switched off', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      expect(core.settings.groupByDay, isTrue);
      await t.tap(find.byKey(const Key('group-by-day')));
      await t.pumpAndSettle();
      expect(core.settings.groupByDay, isFalse);
      expect(core.calls, contains('setGroupByDay:false'));
    });

    testWidgets('the Documents topic can be made in one tap and then turned off', (t) async {
      final core = FakeCore();
      await pumpApp(t, core: core, location: '/settings');
      expect(find.text('Not chosen'), findsOneWidget);
      await t.tap(find.byKey(const Key('documents-topic')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('documents-topic-make')));
      await t.pumpAndSettle();
      expect(core.settings.documentsTopicId, isNotNull);
      expect(core.topics.any((x) => x.name == 'Documents'), isTrue);
      expect(find.text('Documents'), findsWidgets);
      await t.tap(find.byKey(const Key('documents-topic')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('documents-topic-off')));
      await t.pumpAndSettle();
      expect(core.settings.documentsTopicId, isNull);
    });

    testWidgets('making the Documents topic twice does not make two', (t) async {
      final core = FakeCore();
      final a = await core.createDocumentsTopic();
      final b = await core.createDocumentsTopic();
      expect(a, b);
      expect(core.topics.where((x) => x.name == 'Documents').length, 1);
    });
  });

  group('Rule editor: sorting documents', () {
    testWidgets('is off by default and says what to do first when no Documents topic is chosen', (t) async {
      await pumpApp(t, location: '/rules/new');
      final sw = t.widget<SwitchListTile>(find.byKey(const Key('rule-sort-documents')));
      expect(sw.value, isFalse);
      expect(find.text('Choose the Documents topic in Settings first.'), findsOneWidget);
    });

    testWidgets('turning it on is saved with the rule', (t) async {
      final core = FakeCore();
      core.settings.documentsTopicId = 11;
      await pumpApp(t, core: core, location: '/rules/new');
      await t.enterText(find.byKey(const Key('rule-name')), 'My camera');
      await t.tap(find.byKey(const Key('rule-folder')));
      await t.pumpAndSettle();
      await t.tap(find.text('Gallery photos'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('rule-sort-documents')));
      await t.tap(find.byKey(const Key('rule-sort-documents')));
      await t.pumpAndSettle();
      expect(t.widget<SwitchListTile>(find.byKey(const Key('rule-sort-documents'))).value, isTrue);
      await t.ensureVisible(find.text('Save'));
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(core.rules.single.rule.sortDocuments, isTrue);
    });
  });
}
