import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/playback/playback_page_gesture.dart';

void main() {
  group('resolvePlaybackPageGesture', () {
    test('toggles the audio view for a dominant horizontal swipe', () {
      expect(
        resolvePlaybackPageGesture(deltaX: -96, deltaY: 18),
        PlaybackPageGestureAction.toggleView,
      );
      expect(
        resolvePlaybackPageGesture(deltaX: 96, deltaY: -12),
        PlaybackPageGestureAction.toggleView,
      );
    });

    test('dismisses the page for a dominant downward swipe', () {
      expect(
        resolvePlaybackPageGesture(deltaX: 8, deltaY: 110),
        PlaybackPageGestureAction.dismiss,
      );
    });

    test('ignores short, upward, and ambiguous gestures', () {
      expect(
        resolvePlaybackPageGesture(deltaX: 30, deltaY: 4),
        PlaybackPageGestureAction.none,
      );
      expect(
        resolvePlaybackPageGesture(deltaX: 3, deltaY: -120),
        PlaybackPageGestureAction.none,
      );
      expect(
        resolvePlaybackPageGesture(deltaX: 90, deltaY: 80),
        PlaybackPageGestureAction.none,
      );
    });
  });
}
