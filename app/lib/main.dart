import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const HelloApp());

class HelloApp extends StatelessWidget {
  const HelloApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'teleBackup',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true),
        home: const HelloScreen(),
      );
}

class HelloScreen extends StatefulWidget {
  const HelloScreen({super.key, this.channel = const MethodChannel('telebackup/hello')});
  final MethodChannel channel;

  @override
  State<HelloScreen> createState() => _HelloScreenState();
}

class _HelloScreenState extends State<HelloScreen> {
  String _reply = '';

  Future<void> _ping() async {
    try {
      final r = await widget.channel.invokeMethod<String>('ping');
      setState(() => _reply = 'Kotlin says: $r');
    } catch (e) {
      setState(() => _reply = 'No answer from Kotlin');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('teleBackup')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(onPressed: _ping, child: const Text('Ping Kotlin')),
            const SizedBox(height: 16),
            Text(_reply),
          ]),
        ),
      );
}
