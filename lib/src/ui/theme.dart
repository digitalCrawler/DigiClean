import 'package:flutter/material.dart';

/// Design tokens of the "Typography-Driven" system (design.md), shared with
/// the website (website/assets/site.css).
///
/// Oversized, tightly tracked display type carries the design. The only
/// ornaments are a 3px ink rule and one accent colour. Square corners
/// everywhere except pill buttons; no shadows, no gradients.
abstract final class Tokens {
  // Light
  static const bg = Color(0xFFF4F4F0);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceStrong = Color(0xFFEAEAE4);
  static const border = Color(0xFF0F0F0F);
  static const text = Color(0xFF0F0F0F);
  static const textMuted = Color(0xFF55554E);
  static const hairline = Color(0xFFD5D5CD);

  // Dark: the same system inverted; the accent survives unchanged.
  static const bgDark = Color(0xFF0F0F0F);
  static const surfaceDark = Color(0xFF181816);
  static const surfaceStrongDark = Color(0xFF24241F);
  static const borderDark = Color(0xFFF4F4F0);
  static const textDark = Color(0xFFF4F4F0);
  static const textMutedDark = Color(0xFFAAAAA0);
  static const hairlineDark = Color(0xFF34342F);

  static const accent = Color(0xFFFF3D00);
  static const onAccent = Color(0xFF0F0F0F);

  /// The rule under key surfaces (app bars, cards, sections).
  static const rule = 3.0;

  /// Borders of small controls (checkboxes, outlined buttons, chips).
  static const control = 2.0;

  // Spacing scale.
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s6 = 24.0;
  static const s8 = 32.0;
  static const s12 = 48.0;
}

/// Brand values used outside the theme.
abstract final class Brand {
  static const displayFont = 'Archivo';
  static const accent = Tokens.accent;
}

/// Design-system colours that Material's [ColorScheme] has no role for.
@immutable
class Ds extends ThemeExtension<Ds> {
  const Ds({
    required this.accent,
    required this.onAccent,
    required this.ink,
    required this.muted,
    required this.surfaceStrong,
    required this.hairline,
  });

  final Color accent;
  final Color onAccent;

  /// Text and rule colour (black in light mode, off-white in dark mode).
  final Color ink;
  final Color muted;
  final Color surfaceStrong;
  final Color hairline;

  BorderSide get rule => BorderSide(color: ink, width: Tokens.rule);

  static const light = Ds(
    accent: Tokens.accent,
    onAccent: Tokens.onAccent,
    ink: Tokens.text,
    muted: Tokens.textMuted,
    surfaceStrong: Tokens.surfaceStrong,
    hairline: Tokens.hairline,
  );

  static const dark = Ds(
    accent: Tokens.accent,
    onAccent: Tokens.onAccent,
    ink: Tokens.textDark,
    muted: Tokens.textMutedDark,
    surfaceStrong: Tokens.surfaceStrongDark,
    hairline: Tokens.hairlineDark,
  );

  @override
  Ds copyWith({Color? accent, Color? onAccent, Color? ink, Color? muted, Color? surfaceStrong, Color? hairline}) => Ds(
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    surfaceStrong: surfaceStrong ?? this.surfaceStrong,
    hairline: hairline ?? this.hairline,
  );

  @override
  Ds lerp(Ds? other, double t) {
    if (other == null) return this;
    return Ds(
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      surfaceStrong: Color.lerp(surfaceStrong, other.surfaceStrong, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
    );
  }
}

extension DsContext on BuildContext {
  Ds get ds => Theme.of(this).extension<Ds>() ?? Ds.light;
}

/// Display type: heavy, tightly tracked, set solid.
TextStyle displayStyle(double size, {Color? color, FontWeight weight = FontWeight.w800}) => TextStyle(
  fontFamily: Brand.displayFont,
  fontSize: size,
  fontWeight: weight,
  height: 0.98,
  letterSpacing: -0.035 * size,
  color: color,
);

/// Uppercase label ("label-caps").
TextStyle capsStyle(Color color, {double size = 11.5}) => TextStyle(
  fontFamily: Brand.displayFont,
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.08 * size,
  height: 1.2,
  color: color,
);

ColorScheme _scheme(Brightness brightness) {
  if (brightness == Brightness.light) {
    return const ColorScheme(
      brightness: Brightness.light,
      // Ink is the primary colour: text, icons and plain buttons. The accent
      // is spent on purpose (main actions, selection, progress, "Keep").
      primary: Tokens.text,
      onPrimary: Tokens.bg,
      primaryContainer: Tokens.surfaceStrong,
      onPrimaryContainer: Tokens.text,
      secondary: Tokens.text,
      onSecondary: Tokens.bg,
      // Selected navigation, chips and segments: solid ink.
      secondaryContainer: Tokens.text,
      onSecondaryContainer: Tokens.bg,
      tertiary: Tokens.textMuted,
      onTertiary: Tokens.bg,
      tertiaryContainer: Tokens.surfaceStrong,
      onTertiaryContainer: Tokens.text,
      error: Color(0xFFB3261E),
      onError: Color(0xFFFFFFFF),
      errorContainer: Color(0xFFF9DEDC),
      onErrorContainer: Color(0xFF410E0B),
      surface: Tokens.bg,
      onSurface: Tokens.text,
      onSurfaceVariant: Tokens.textMuted,
      surfaceDim: Color(0xFFE2E2DC),
      surfaceBright: Tokens.surface,
      surfaceContainerLowest: Tokens.surface,
      surfaceContainerLow: Tokens.surface,
      surfaceContainer: Tokens.surface,
      surfaceContainerHigh: Color(0xFFEFEFEA),
      surfaceContainerHighest: Tokens.surfaceStrong,
      outline: Tokens.border,
      outlineVariant: Tokens.hairline,
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Tokens.text,
      onInverseSurface: Tokens.bg,
      inversePrimary: Tokens.accent,
      surfaceTint: Colors.transparent,
    );
  }
  return const ColorScheme(
    brightness: Brightness.dark,
    primary: Tokens.textDark,
    onPrimary: Tokens.bgDark,
    primaryContainer: Tokens.surfaceStrongDark,
    onPrimaryContainer: Tokens.textDark,
    secondary: Tokens.textDark,
    onSecondary: Tokens.bgDark,
    secondaryContainer: Tokens.textDark,
    onSecondaryContainer: Tokens.bgDark,
    tertiary: Tokens.textMutedDark,
    onTertiary: Tokens.bgDark,
    tertiaryContainer: Tokens.surfaceStrongDark,
    onTertiaryContainer: Tokens.textDark,
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Tokens.bgDark,
    onSurface: Tokens.textDark,
    onSurfaceVariant: Tokens.textMutedDark,
    surfaceDim: Tokens.bgDark,
    surfaceBright: Tokens.surfaceStrongDark,
    surfaceContainerLowest: Tokens.surfaceDark,
    surfaceContainerLow: Tokens.surfaceDark,
    surfaceContainer: Tokens.surfaceDark,
    surfaceContainerHigh: Color(0xFF1E1E1B),
    surfaceContainerHighest: Tokens.surfaceStrongDark,
    outline: Tokens.borderDark,
    outlineVariant: Tokens.hairlineDark,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Tokens.textDark,
    onInverseSurface: Tokens.bgDark,
    inversePrimary: Tokens.accent,
    surfaceTint: Colors.transparent,
  );
}

TextTheme _textTheme(Color ink, Color muted) {
  // Exaggerated jumps between sizes; display sizes tightly tracked.
  TextStyle t(double size, FontWeight weight, {double tracking = 0, double? height}) => TextStyle(
    fontFamily: Brand.displayFont,
    fontSize: size,
    fontWeight: weight,
    letterSpacing: tracking * size,
    height: height,
    color: ink,
  );
  return TextTheme(
    displayLarge: t(64, FontWeight.w800, tracking: -0.045, height: 0.95),
    displayMedium: t(48, FontWeight.w800, tracking: -0.04, height: 0.95),
    displaySmall: t(38, FontWeight.w800, tracking: -0.035, height: 1.0),
    headlineLarge: t(32, FontWeight.w800, tracking: -0.035, height: 1.05),
    headlineMedium: t(28, FontWeight.w800, tracking: -0.03, height: 1.08),
    headlineSmall: t(24, FontWeight.w800, tracking: -0.03, height: 1.1),
    titleLarge: t(21, FontWeight.w800, tracking: -0.025, height: 1.15),
    titleMedium: t(16, FontWeight.w700, tracking: -0.01, height: 1.3),
    titleSmall: t(14, FontWeight.w700, tracking: -0.005, height: 1.3),
    bodyLarge: t(16, FontWeight.w400, height: 1.5),
    bodyMedium: t(14, FontWeight.w400, height: 1.45),
    bodySmall: t(12.5, FontWeight.w400, height: 1.4).copyWith(color: muted),
    labelLarge: t(14, FontWeight.w700, tracking: -0.01),
    labelMedium: t(12, FontWeight.w600, tracking: 0.02),
    labelSmall: t(11, FontWeight.w600, tracking: 0.04),
  );
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = _scheme(brightness);
  final ds = brightness == Brightness.light ? Ds.light : Ds.dark;
  final ink = ds.ink;
  final text = _textTheme(ink, ds.muted);
  final rule = BorderSide(color: ink, width: Tokens.rule);
  final control = BorderSide(color: ink, width: Tokens.control);
  const square = RoundedRectangleBorder();
  const pill = StadiumBorder();
  final buttonText = text.labelLarge!.copyWith(fontSize: 15, fontWeight: FontWeight.w700);

  WidgetStateProperty<Color?> accentWhenSelected(Color otherwise) => WidgetStateProperty.resolveWith((s) {
    if (s.contains(WidgetState.disabled)) return otherwise.withValues(alpha: 0.38);
    return s.contains(WidgetState.selected) ? ds.accent : otherwise;
  });

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [ds],
    fontFamily: Brand.displayFont,
    textTheme: text,
    primaryTextTheme: text,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    splashFactory: InkRipple.splashFactory,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: ink),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: ink,
      selectionColor: ds.accent.withValues(alpha: 0.35),
      selectionHandleColor: ds.accent,
    ),

    // App bars: the page title in display type over a 3px rule.
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 64,
      shape: Border(bottom: rule),
      titleTextStyle: displayStyle(26, color: ink),
      iconTheme: IconThemeData(color: ink),
      actionsIconTheme: IconThemeData(color: ink),
    ),

    // Cards: a white surface under a bold rule, square, no shadow.
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: Border(top: rule),
      clipBehavior: Clip.antiAlias,
    ),

    // Buttons: pills set in display type. Filled = accent (main action),
    // tonal = ink, outlined = ink outline, text = ink.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
        shape: const WidgetStatePropertyAll(pill),
        textStyle: WidgetStatePropertyAll(buttonText),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? ds.surfaceStrong : ds.accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? ds.muted : ds.onAccent,
        ),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? ds.muted : ds.onAccent),
        overlayColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.12)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(0, 48),
        shape: pill,
        textStyle: buttonText,
        backgroundColor: ink,
        foregroundColor: scheme.surface,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 10)),
        shape: const WidgetStatePropertyAll(pill),
        textStyle: WidgetStatePropertyAll(buttonText.copyWith(fontSize: 14)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? ds.muted : ink),
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? BorderSide(color: ds.hairline, width: Tokens.control) : control,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: ink, shape: pill, textStyle: buttonText.copyWith(fontSize: 14)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: ink, shape: square),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: ds.accent,
      foregroundColor: ds.onAccent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: pill,
      extendedTextStyle: buttonText,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(pill),
        side: WidgetStatePropertyAll(control),
        textStyle: WidgetStatePropertyAll(buttonText.copyWith(fontSize: 13.5)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ink : null),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return ds.muted;
          return s.contains(WidgetState.selected) ? scheme.surface : ink;
        }),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.surface : ink),
      ),
    ),

    // Navigation: square ink indicator, labels in display type.
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: ink,
      indicatorShape: square,
      selectedIconTheme: IconThemeData(color: scheme.surface),
      unselectedIconTheme: IconThemeData(color: ink),
      selectedLabelTextStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w800),
      unselectedLabelTextStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w600, color: ds.muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: ink,
      indicatorShape: square,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.surface : ink),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelMedium!.copyWith(
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
          color: s.contains(WidgetState.selected) ? ink : ds.muted,
        ),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: ink,
      unselectedLabelColor: ds.muted,
      labelStyle: text.titleSmall!.copyWith(fontWeight: FontWeight.w800),
      unselectedLabelStyle: text.titleSmall!.copyWith(fontWeight: FontWeight.w600),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: ds.accent, width: Tokens.rule),
      ),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: ink,
      dividerHeight: 1,
    ),

    // Selection controls: the accent marks what is chosen.
    checkboxTheme: CheckboxThemeData(
      shape: square,
      side: WidgetStateBorderSide.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return BorderSide(color: ds.accent, width: Tokens.control);
        if (s.contains(WidgetState.disabled)) return BorderSide(color: ds.hairline, width: Tokens.control);
        return control;
      }),
      fillColor: accentWhenSelected(Colors.transparent),
      checkColor: WidgetStatePropertyAll(ds.onAccent),
    ),
    radioTheme: RadioThemeData(fillColor: accentWhenSelected(ink)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return ds.onAccent;
        return ink;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return ds.surfaceStrong;
        return s.contains(WidgetState.selected) ? ds.accent : scheme.surfaceContainerLowest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ds.accent : ink),
      trackOutlineWidth: const WidgetStatePropertyAll(Tokens.control),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: ds.accent,
      inactiveTrackColor: ds.surfaceStrong,
      thumbColor: ink,
      overlayColor: ds.accent.withValues(alpha: 0.16),
      valueIndicatorColor: ink,
      valueIndicatorTextStyle: text.labelMedium!.copyWith(color: scheme.surface),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: ds.accent,
      linearTrackColor: ds.surfaceStrong,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 6,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: ds.accent,
      textColor: ds.onAccent,
      textStyle: text.labelSmall!.copyWith(fontWeight: FontWeight.w800),
    ),
    chipTheme: ChipThemeData(
      shape: square,
      side: BorderSide(color: ink, width: 1.5),
      backgroundColor: scheme.surfaceContainerLowest,
      selectedColor: ink,
      secondarySelectedColor: ink,
      checkmarkColor: scheme.surface,
      labelStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w600, color: ink),
      secondaryLabelStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w700, color: scheme.surface),
      iconTheme: IconThemeData(color: ink, size: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),

    // Inputs: an underline that turns accent on focus.
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
      labelStyle: text.bodyMedium!.copyWith(color: ds.muted),
      floatingLabelStyle: capsStyle(ink),
      hintStyle: text.bodyMedium!.copyWith(color: ds.muted),
      border: UnderlineInputBorder(borderSide: control),
      enabledBorder: UnderlineInputBorder(borderSide: control),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: ds.accent, width: Tokens.rule),
      ),
      errorBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: scheme.error, width: Tokens.control),
      ),
      focusedErrorBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: scheme.error, width: Tokens.rule),
      ),
      disabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: ds.hairline, width: Tokens.control),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: text.bodyLarge,
      inputDecorationTheme: InputDecorationTheme(
        border: UnderlineInputBorder(borderSide: control),
        enabledBorder: UnderlineInputBorder(borderSide: control),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: ds.accent, width: Tokens.rule),
        ),
      ),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLowest),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(side: control)),
      ),
    ),

    // Floating surfaces: square, outlined in ink instead of shadowed.
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(side: rule),
      titleTextStyle: displayStyle(26, color: ink),
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: Border(top: rule),
      showDragHandle: false,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(side: control),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium!.copyWith(fontWeight: FontWeight.w500)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLowest),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(side: control)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(color: scheme.onInverseSurface),
      actionTextColor: ds.accent,
      elevation: 0,
      shape: square,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.inverseSurface),
      textStyle: text.labelMedium!.copyWith(color: scheme.onInverseSurface),
      waitDuration: const Duration(milliseconds: 400),
    ),
    scrollbarTheme: const ScrollbarThemeData(radius: Radius.zero),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: ink,
      titleTextStyle: text.bodyLarge!.copyWith(fontWeight: FontWeight.w600),
      subtitleTextStyle: text.bodySmall,
      selectedColor: ink,
      selectedTileColor: ds.surfaceStrong,
    ),
    expansionTileTheme: const ExpansionTileThemeData(shape: Border(), collapsedShape: Border()),
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
