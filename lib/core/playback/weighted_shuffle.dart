import 'dart:math';

int weightedShuffleIndex(List<int> weights, Random random,
    {int currentIndex = -1}) {
  if (weights.isEmpty) throw ArgumentError.value(weights, 'weights');
  final values = weights.map((weight) => weight.clamp(1, 10)).toList();
  // Preserve the existing non-repeating shuffle when every song is at default.
  if (values.every((weight) => weight == 1)) {
    if (values.length == 1 ||
        currentIndex < 0 ||
        currentIndex >= values.length) {
      return random.nextInt(values.length);
    }
    final index = random.nextInt(values.length - 1);
    return index >= currentIndex ? index + 1 : index;
  }
  var ticket = random.nextInt(values.fold<int>(0, (sum, value) => sum + value));
  for (var index = 0; index < values.length; index++) {
    ticket -= values[index];
    if (ticket < 0) return index;
  }
  return values.length - 1;
}
