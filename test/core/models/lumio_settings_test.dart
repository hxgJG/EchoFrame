import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/models/lumio_settings.dart';

void main() {
  group('LumioSettings display preferences', () {
    test('uses safe defaults when older JSON has no display preferences', () {
      final settings = LumioSettings.fromJson(const <String, Object?>{});

      expect(settings.musicViewMode, MusicViewMode.list);
      expect(settings.themeAccent, ThemeAccent.blue);
    });

    test('round-trips music view mode and theme accent', () {
      const settings = LumioSettings(
        musicViewMode: MusicViewMode.grid,
        themeAccent: ThemeAccent.coral,
      );

      final restored = LumioSettings.fromJson(settings.toJson());

      expect(restored.musicViewMode, MusicViewMode.grid);
      expect(restored.themeAccent, ThemeAccent.coral);
    });

    test('falls back when persisted enum values are unknown', () {
      final settings = LumioSettings.fromJson(const <String, Object?>{
        'musicViewMode': 'future-mode',
        'themeAccent': 'future-color',
      });

      expect(settings.musicViewMode, MusicViewMode.list);
      expect(settings.themeAccent, ThemeAccent.blue);
    });

    test('crossfade is off by default and enables at three seconds', () {
      const settings = LumioSettings();

      final enabled = settings.withCrossfadeEnabled(true);

      expect(settings.crossfadeEnabled, isFalse);
      expect(enabled.crossfadeEnabled, isTrue);
      expect(enabled.crossfadeSeconds, 3);
      expect(enabled.withCrossfadeEnabled(false).crossfadeSeconds, 0);
    });
  });
}
