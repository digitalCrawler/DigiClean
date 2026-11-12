import 'dart:math' as math;
import 'dart:ui';

/// Squarified treemap layout (Bruls, Huizing & van Wijk): tiles keep close
/// to square, so sizes stay easy to compare. `values` must be sorted
/// largest first; tiles are returned in the same order. Zero and negative
/// values get no tile.
List<Rect> squarify(List<double> values, Rect bounds) {
  final out = List<Rect>.filled(values.length, Rect.zero);
  final total = values.fold<double>(0, (s, v) => s + math.max(v, 0));
  if (total <= 0 || bounds.isEmpty) return out;
  final scale = bounds.width * bounds.height / total;
  final areas = [for (final v in values) math.max(v, 0) * scale];

  var free = bounds;
  var start = 0;
  while (start < areas.length && areas[start] > 0) {
    final side = math.min(free.width, free.height);
    // Grow the row while the worst aspect ratio improves.
    var end = start + 1;
    var rowArea = areas[start];
    var worst = _worst(areas, start, end, rowArea, side);
    while (end < areas.length && areas[end] > 0) {
      final nextArea = rowArea + areas[end];
      final next = _worst(areas, start, end + 1, nextArea, side);
      if (next > worst) break;
      worst = next;
      rowArea = nextArea;
      end++;
    }
    // Lay the row along the shorter side.
    final thickness = rowArea / side;
    var offset = 0.0;
    final horizontal = free.width >= free.height; // row is a column on the left
    for (var i = start; i < end; i++) {
      final length = areas[i] / thickness;
      out[i] = horizontal
          ? Rect.fromLTWH(free.left, free.top + offset, thickness, length)
          : Rect.fromLTWH(free.left + offset, free.top, length, thickness);
      offset += length;
    }
    free = horizontal
        ? Rect.fromLTRB(free.left + thickness, free.top, free.right, free.bottom)
        : Rect.fromLTRB(free.left, free.top + thickness, free.right, free.bottom);
    start = end;
  }
  return out;
}

/// Largest aspect ratio of the tiles `areas[start..end)` laid along `side`.
double _worst(List<double> areas, int start, int end, double rowArea, double side) {
  final thickness = rowArea / side;
  var worst = 0.0;
  for (var i = start; i < end; i++) {
    final length = areas[i] / thickness;
    worst = math.max(worst, math.max(length / thickness, thickness / length));
  }
  return worst;
}
