import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telebackup/main.dart';

void main() {
  testWidgets('Ping Kotlin button shows the native reply', (tester) async {
    const channel = MethodChannel('telebackup/hello');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 'pong (Android 14, Test)');
    await tester.pumpWidget(const HelloApp());
    expect(find.text('Ping Kotlin'), findsOneWidget);
    await tester.tap(find.text('Ping Kotlin'));
    await tester.pump();
    expect(find.text('Kotlin says: pong (Android 14, Test)'), findsOneWidget);
  });
}
