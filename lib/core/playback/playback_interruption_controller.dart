class PlaybackInterruptionController {
  bool _resumeWhenInterruptionEnds = false;

  void begin({required bool wasPlaying, required bool mayResume}) {
    _resumeWhenInterruptionEnds = wasPlaying && mayResume;
  }

  bool end() {
    final shouldResume = _resumeWhenInterruptionEnds;
    _resumeWhenInterruptionEnds = false;
    return shouldResume;
  }

  void cancelPendingResume() {
    _resumeWhenInterruptionEnds = false;
  }
}
