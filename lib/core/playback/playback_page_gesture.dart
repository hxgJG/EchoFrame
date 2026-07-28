enum PlaybackPageGestureAction { none, toggleView, dismiss }

PlaybackPageGestureAction resolvePlaybackPageGesture({
  required double deltaX,
  required double deltaY,
  double threshold = 72,
}) {
  final horizontalDistance = deltaX.abs();
  final verticalDistance = deltaY.abs();
  if (deltaY >= threshold && verticalDistance > horizontalDistance * 1.2) {
    return PlaybackPageGestureAction.dismiss;
  }
  if (horizontalDistance >= threshold &&
      horizontalDistance > verticalDistance * 1.2) {
    return PlaybackPageGestureAction.toggleView;
  }
  return PlaybackPageGestureAction.none;
}
