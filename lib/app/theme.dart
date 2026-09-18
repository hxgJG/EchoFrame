import 'package:flutter/material.dart';

import '../core/models/lumio_settings.dart';
import '../core/models/media_item.dart';
import 'theme_catalog.dart';

class LumioTheme {
  static const Color brandJade = Color(0xFF276B5B);
  static const Color brandMint = Color(0xFF9ADAC6);
  static const Color peach = Color(0xFFF3BCAD);
  static const Color peachInk = Color(0xFF9B5141);
  static const Color deepTeal = Color(0xFF326C66);
  static const Color sage = Color(0xFF566C61);

  static ThemeData light(
      {ThemeAccent accent = ThemeAccent.blue,
      String themeId = LumioThemeCatalog.defaultId}) {
    final definition = LumioThemeCatalog.resolve(themeId);
    final scheme = definition.light.copyWith(
      primary: accentColor(accent),
      onPrimary: Colors.white,
      primaryContainer: Color.alphaBlend(
          darkAccentColor(accent).withValues(alpha: 0.5),
          definition.light.surface),
      onPrimaryContainer: definition.light.onSurface,
    );
    return _theme(scheme, definition.lightMedia);
  }

  static ThemeData dark(
      {ThemeAccent accent = ThemeAccent.blue,
      String themeId = LumioThemeCatalog.defaultId}) {
    final definition = LumioThemeCatalog.resolve(themeId);
    final seed = darkAccentColor(accent);
    final scheme = definition.dark.copyWith(
      primary: seed,
      onPrimary: definition.dark.surface,
      primaryContainer: Color.alphaBlend(
          seed.withValues(alpha: 0.2), definition.dark.surface),
      onPrimaryContainer: seed,
    );
    return _theme(scheme, definition.darkMedia);
  }

  static Color accentColor(ThemeAccent accent) {
    return switch (accent) {
      ThemeAccent.blue => brandJade,
      ThemeAccent.coral => peachInk,
      ThemeAccent.teal => deepTeal,
      ThemeAccent.violet => sage,
    };
  }

  static Color darkAccentColor(ThemeAccent accent) {
    return switch (accent) {
      ThemeAccent.blue => brandMint,
      ThemeAccent.coral => peach,
      ThemeAccent.teal => const Color(0xFF91CEC2),
      ThemeAccent.violet => const Color(0xFFBDCEC0),
    };
  }

  static LumioMediaColors mediaColors(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<LumioMediaColors>() ??
        (theme.brightness == Brightness.dark
            ? LumioThemeCatalog.resolve(null).darkMedia
            : LumioThemeCatalog.resolve(null).lightMedia);
  }

  static Color audioColor(BuildContext context) => mediaColors(context).audio;
  static Color videoColor(BuildContext context) => mediaColors(context).video;
  static Color mediaColor(MediaKind kind, BuildContext context) =>
      kind == MediaKind.audio ? audioColor(context) : videoColor(context);
  static Color mediaContainerColor(MediaKind kind, BuildContext context) =>
      kind == MediaKind.audio
          ? mediaColors(context).audioContainer
          : mediaColors(context).videoContainer;
  static Color onMediaColor(BuildContext context) =>
      mediaColors(context).onContainer;

  static ThemeData _theme(ColorScheme scheme, LumioMediaColors mediaColors) {
    final isLight = scheme.brightness == Brightness.light;
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: scheme.brightness,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[mediaColors],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w800,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isLight ? scheme.surfaceContainerLow : scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
        labelStyle: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: isLight ? scheme.primaryContainer : scheme.primary,
          foregroundColor:
              isLight ? scheme.onPrimaryContainer : scheme.onPrimary,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.primary,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: isLight ? scheme.primaryContainer : scheme.primary,
        foregroundColor: isLight ? scheme.onPrimaryContainer : scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
          ),
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(letterSpacing: 0),
      ),
    );
  }
}
