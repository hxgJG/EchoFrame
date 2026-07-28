import 'package:flutter/material.dart';

import '../core/models/lumio_settings.dart';
import '../core/models/media_item.dart';

class LumioTheme {
  static const Color brandViolet = Color(0xFF9B35FF);
  static const Color brandBlue = Color(0xFF2A63FF);
  static const Color brandCyan = Color(0xFF12CDEB);
  static const Color coral = Color(0xFFFF5068);
  static const Color audioGold = Color(0xFFFFB000);
  static const Color audioOrange = Color(0xFFE87500);
  static const Color videoMint = Color(0xFF18DDBE);
  static const Color videoTeal = Color(0xFF008F7A);
  static const Color teal = videoTeal;
  static const Color ink = Color(0xFF14142A);
  static const Color mist = Color(0xFFE9EAF8);
  static const Color paper = Color(0xFFF8F8FE);
  static const Color night = Color(0xFF07091F);

  static ThemeData light({ThemeAccent accent = ThemeAccent.blue}) {
    final seedColor = accentColor(accent);
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
      primary: seedColor,
      secondary: coral,
      tertiary: brandCyan,
      surface: paper,
    );
    return _theme(scheme);
  }

  static ThemeData dark({ThemeAccent accent = ThemeAccent.blue}) {
    final seedColor = darkAccentColor(accent);
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
      primary: seedColor,
      secondary: const Color(0xFFFF8999),
      tertiary: const Color(0xFF58DDF0),
      surface: const Color(0xFF101229),
    );
    return _theme(scheme);
  }

  static Color accentColor(ThemeAccent accent) {
    return switch (accent) {
      ThemeAccent.blue => brandBlue,
      ThemeAccent.coral => coral,
      ThemeAccent.teal => videoTeal,
      ThemeAccent.violet => brandViolet,
    };
  }

  static Color darkAccentColor(ThemeAccent accent) {
    return switch (accent) {
      ThemeAccent.blue => const Color(0xFF8395FF),
      ThemeAccent.coral => const Color(0xFFFF8999),
      ThemeAccent.teal => const Color(0xFF57DFC9),
      ThemeAccent.violet => const Color(0xFFC08CFF),
    };
  }

  static Color audioColor(Brightness brightness) =>
      brightness == Brightness.dark ? audioGold : audioOrange;

  static Color videoColor(Brightness brightness) =>
      brightness == Brightness.dark ? videoMint : videoTeal;

  static Color mediaColor(MediaKind kind, Brightness brightness) =>
      kind == MediaKind.audio ? audioColor(brightness) : videoColor(brightness);

  static ThemeData _theme(ColorScheme scheme) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: scheme.brightness,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
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
        color: scheme.surface,
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
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
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
