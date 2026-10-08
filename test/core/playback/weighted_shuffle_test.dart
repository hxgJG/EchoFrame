import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/core/playback/weighted_shuffle.dart';

void main() {
  test('默认权重保留不连续重复的原有随机行为', () {
    final random = Random(13);
    for (var i = 0; i < 100; i++) {
      expect(
          weightedShuffleIndex([1, 1, 1], random, currentIndex: 1), isNot(1));
    }
    expect(weightedShuffleIndex([1], random, currentIndex: 0), 0);
  });

  test('设置权重后按比例抽样，包括当前歌曲', () {
    final random = Random(42);
    var heavy = 0;
    for (var i = 0; i < 10000; i++) {
      if (weightedShuffleIndex([10, 1], random, currentIndex: 0) == 0) heavy++;
    }
    expect(heavy / 10000, inInclusiveRange(0.89, 0.93));
  });

  test('相同非默认权重保持同等机会', () {
    final random = Random(17);
    final counts = List.filled(3, 0);
    for (var i = 0; i < 9000; i++) {
      counts[weightedShuffleIndex([4, 4, 4], random)]++;
    }
    expect(counts.every((count) => count > 2700 && count < 3300), isTrue);
  });

  test('无候选时报错，越界权重限制到合法范围', () {
    expect(() => weightedShuffleIndex([], Random(1)), throwsArgumentError);
    for (var seed = 0; seed < 100; seed++) {
      expect(weightedShuffleIndex([0, 999], Random(seed)),
          weightedShuffleIndex([1, 10], Random(seed)));
    }
  });
}
