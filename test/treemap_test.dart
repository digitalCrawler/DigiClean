import 'dart:ui';

import 'package:digiclean/src/core/treemap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bounds = Rect.fromLTWH(0, 0, 600, 400);

  test('tiles fill the area in proportion to their values', () {
    final values = <double>[6, 6, 4, 3, 2, 2, 1];
    final rects = squarify(values, bounds);
    final total = values.reduce((a, b) => a + b);
    for (var i = 0; i < values.length; i++) {
      final area = rects[i].width * rects[i].height;
      expect(area, closeTo(values[i] / total * bounds.width * bounds.height, 0.01));
      expect(bounds.inflate(0.01).contains(rects[i].topLeft), isTrue);
      expect(rects[i].right, lessThanOrEqualTo(bounds.right + 0.01));
      expect(rects[i].bottom, lessThanOrEqualTo(bounds.bottom + 0.01));
    }
    // No two tiles overlap.
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final overlap = rects[i].intersect(rects[j]);
        expect(overlap.width <= 0.01 || overlap.height <= 0.01, isTrue, reason: '$i and $j overlap');
      }
    }
  });

  test('tiles stay reasonably square', () {
    final rects = squarify([for (var i = 0; i < 20; i++) 20.0 - i], bounds);
    for (final r in rects) {
      final ratio = r.width > r.height ? r.width / r.height : r.height / r.width;
      expect(ratio, lessThan(5));
    }
  });

  test('empty and zero values produce no tiles', () {
    expect(squarify([], bounds), isEmpty);
    final rects = squarify([5, 0], bounds);
    expect(rects[0].width * rects[0].height, closeTo(600 * 400, 0.01));
    expect(rects[1], Rect.zero);
    expect(squarify([0, 0], bounds), [Rect.zero, Rect.zero]);
  });
}
