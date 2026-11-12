import 'package:intl/intl.dart';

const _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// Human-readable size using binary multiples (what file managers show).
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : decimals;
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

final _count = NumberFormat.decimalPattern();

String formatCount(int n) => _count.format(n);

String plural(int n, String one, [String? many]) => '${formatCount(n)} ${n == 1 ? one : (many ?? '${one}s')}';

String formatDuration(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  if (d.inSeconds > 0) return '${d.inSeconds}s';
  return '${d.inMilliseconds} ms';
}

final _date = DateFormat.yMMMd();
final _dateTime = DateFormat.yMMMd().add_jm();

String formatDate(int epochMs) => _date.format(DateTime.fromMillisecondsSinceEpoch(epochMs));

String formatDateTime(int epochMs) => _dateTime.format(DateTime.fromMillisecondsSinceEpoch(epochMs));

String formatRelative(int epochMs) {
  final then = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = DateTime.now().difference(then);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${plural(diff.inDays, 'day')} ago';
  return formatDate(epochMs);
}

/// Shortens long paths in the middle, keeping the start and the file name.
String middleEllipsis(String s, int max) {
  if (s.length <= max || max < 8) return s;
  final keepEnd = (max * 0.6).floor();
  final keepStart = max - keepEnd - 1;
  return '${s.substring(0, keepStart)}…${s.substring(s.length - keepEnd)}';
}

/// Parses "10", "10K", "1.5 MB", "2g" into bytes. Returns null if invalid.
int? parseSize(String input) {
  final s = input.trim().toUpperCase().replaceAll(' ', '');
  if (s.isEmpty) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([KMGT]?)(I?B)?$').firstMatch(s);
  if (match == null) return null;
  final value = double.parse(match.group(1)!);
  const multipliers = {'': 1, 'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30, 'T': 1 << 40};
  return (value * multipliers[match.group(2)]!).round();
}
