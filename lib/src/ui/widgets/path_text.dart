import 'package:flutter/material.dart';

import '../../core/path_display.dart';

/// Shows path segments joined by " › ". When the text does not fit, leading
/// segments are replaced by "…" so the most specific part (the end of the
/// path) stays visible — unlike normal ellipsis, which would cut it off.
class PathSegmentsText extends StatelessWidget {
  const PathSegmentsText(this.segments, {super.key, this.style, this.tooltip});

  final List<String> segments;
  final TextStyle? style;

  /// Full path shown on hover / long-press.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final scale = MediaQuery.textScalerOf(context);
    final text = LayoutBuilder(
      builder: (context, constraints) {
        final fitted = _fit(effective, scale, constraints.maxWidth);
        return Text(fitted, style: effective, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
      },
    );
    if (tooltip == null) return text;
    return Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: text);
  }

  String _fit(TextStyle style, TextScaler scale, double maxWidth) {
    final visible = segments.where((s) => s != '/').toList();
    if (visible.isEmpty) return '';
    String candidate(int drop) => drop == 0 ? joinSegments(visible) : '… › ${joinSegments(visible.sublist(drop))}';
    if (!maxWidth.isFinite) return candidate(0);
    final painter = TextPainter(textDirection: TextDirection.ltr, textScaler: scale, maxLines: 1);
    try {
      for (var drop = 0; drop < visible.length; drop++) {
        painter.text = TextSpan(text: candidate(drop), style: style);
        painter.layout();
        if (painter.width <= maxWidth) return candidate(drop);
      }
      // Even the last segment is too long: let normal ellipsis handle it.
      return visible.length > 1 ? candidate(visible.length - 1) : visible.last;
    } finally {
      painter.dispose();
    }
  }
}
