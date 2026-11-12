import 'package:flutter/material.dart';

/// Brand colours from branding/brand-sheet.png.
abstract final class Brand {
  static const navy = Color(0xFF112F47);
  static const navyDeep = Color(0xFF0B2235);
  static const mint = Color(0xFF6FD8B0);
  static const mintDeep = Color(0xFF17795A);
  static const mintSoft = Color(0xFFD6F4E8);

  /// Display face used by the wordmark and headings.
  static const displayFont = 'Outfit';
}

ColorScheme _scheme(Brightness brightness) {
  // Neutrals come from the navy seed (cool, slightly blue greys); the
  // primary roles are pinned to the brand colours.
  final base = ColorScheme.fromSeed(seedColor: Brand.navy, brightness: brightness);
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: Brand.navy,
      onPrimary: Colors.white,
      primaryContainer: Brand.mintSoft,
      onPrimaryContainer: Brand.navyDeep,
      secondary: Brand.mintDeep,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFE3F1F8),
      onSecondaryContainer: Brand.navyDeep,
    );
  }
  return base.copyWith(
    primary: Brand.mint,
    onPrimary: Brand.navyDeep,
    primaryContainer: const Color(0xFF1D4A62),
    onPrimaryContainer: const Color(0xFFD3F7E9),
    secondary: const Color(0xFF9FE6CB),
    onSecondary: Brand.navyDeep,
  );
}

TextTheme _textTheme(TextTheme base) {
  // Outfit for display and titles; body text keeps the platform font, which
  // reads best at small sizes in dense lists.
  TextStyle? brand(TextStyle? s) => s?.copyWith(fontFamily: Brand.displayFont);
  return base.copyWith(
    displayLarge: brand(base.displayLarge),
    displayMedium: brand(base.displayMedium),
    displaySmall: brand(base.displaySmall),
    headlineLarge: brand(base.headlineLarge),
    headlineMedium: brand(base.headlineMedium),
    headlineSmall: brand(base.headlineSmall),
    titleLarge: brand(base.titleLarge),
    titleMedium: brand(base.titleMedium),
  );
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = _scheme(brightness);
  final plain = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
  final base = plain.copyWith(textTheme: _textTheme(plain.textTheme));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
  );
}

/// Breakpoints for adaptive layouts.
abstract final class Breakpoints {
  static const double medium = 720;
  static const double expanded = 1100;
}

extension LayoutContext on BuildContext {
  double get width => MediaQuery.sizeOf(this).width;
  bool get isCompact => width < Breakpoints.medium;
  bool get isExpanded => width >= Breakpoints.expanded;
}
