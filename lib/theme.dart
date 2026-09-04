import 'package:flutter/material.dart';

/// Layout breakpoints. These were previously scattered as literals — 700 for
/// navigation, 900 for the editor, 980 for the calculator — which left the
/// 700–980 band using a cramped single column on a wide window.
abstract final class Breaks {
  /// Below this, use bottom navigation instead of a rail.
  static const compact = 640.0;

  /// At or above this, two-column layouts are worth it.
  static const wide = 900.0;

  /// At or above this, three panes or extra detail columns fit.
  static const extraWide = 1300.0;

  static bool isCompact(double w) => w < compact;
  static bool isWide(double w) => w >= wide;
}

/// Consistent spacing scale, so padding stops being ad hoc.
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;

  static const hSm = SizedBox(width: sm);
  static const hMd = SizedBox(width: md);
  static const hLg = SizedBox(width: lg);
  static const vXs = SizedBox(height: xs);
  static const vSm = SizedBox(height: sm);
  static const vMd = SizedBox(height: md);
  static const vLg = SizedBox(height: lg);
  static const vXl = SizedBox(height: xl);
}

const _seed = Color(0xFF00897B); // teal 600

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: Gap.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.all(Gap.lg),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: Gap.xl),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: Gap.md),
    ),
  );
}
