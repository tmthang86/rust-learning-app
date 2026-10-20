import 'package:flutter/material.dart';

/// Rust's brand orange, used as the seed for the colour scheme.
const _seed = Color(0xFFCE422B);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}

/// Monospace style for code.
const codeTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
  fontSize: 14,
  height: 1.4,
);

/// Width at which layouts switch from phone to tablet/desktop.
const wideBreakpoint = 640.0;
