import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/playback/playback_interruption_controller.dart';

void main() {
  group('PlaybackInterruptionController', () {
    test('resumes after a resumable interruption that paused active playback',
        () {
      final controller = PlaybackInterruptionController();

      controller.begin(wasPlaying: true, mayResume: true);

      expect(controller.end(), isTrue);
      expect(controller.end(), isFalse);
    });

    test('does not resume after permanent focus loss', () {
      final controller = PlaybackInterruptionController();

      controller.begin(wasPlaying: true, mayResume: false);

      expect(controller.end(), isFalse);
    });

    test('does not resume media that was already paused', () {
      final controller = PlaybackInterruptionController();

      controller.begin(wasPlaying: false, mayResume: true);

      expect(controller.end(), isFalse);
    });

    test('manual playback changes cancel pending automatic resume', () {
      final controller = PlaybackInterruptionController();
      controller.begin(wasPlaying: true, mayResume: true);

      controller.cancelPendingResume();

      expect(controller.end(), isFalse);
    });
  });
}
