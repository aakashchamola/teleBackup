import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

const seedColor = Color(0xFF1565C0);
const _doneLight = Color(0xFF2E7D32);
const _doneDark = Color(0xFF81C784);

/// Status colours (docs/UI.md section 2): working = primary, paused = tertiary, attention = error, done = green.
extension StatusColors on ColorScheme {
  Color get working => primary;
  Color get holding => tertiary;
  Color get attention => error;
  Color get done => brightness == Brightness.dark ? _doneDark : _doneLight;
}

ThemeData buildTheme(ColorScheme scheme) => ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 0),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );

/// Wraps the app in Material You colours (Android 12+), with the blue seed as the fallback.
Widget withDynamicColor(Widget Function(ThemeData light, ThemeData dark) builder) => DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final light = lightDynamic ?? ColorScheme.fromSeed(seedColor: seedColor);
        final dark = darkDynamic ?? ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
        return builder(buildTheme(light), buildTheme(dark));
      },
    );
