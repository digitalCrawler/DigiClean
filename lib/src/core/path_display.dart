/// Turns the full paths of the copies in a group into short labels that
/// show only what differs between them.
///
/// For `C:\Users\me\Pictures\Desktop\Old` and `C:\Users\me\Pictures\Downloads`
/// the shared prefix is `C:\Users\me\Pictures` (shown once per group) and the
/// labels are `Desktop › Old` and `Downloads`.
class GroupLocations {
  GroupLocations._(this.prefix, this._relative);

  /// [folders] are the directories to compare: the parent folder of each
  /// file, or each duplicate folder itself.
  factory GroupLocations.of(List<String> folders) {
    final split = folders.map(splitPath).toList();
    if (split.isEmpty) return GroupLocations._(const [], const []);
    var common = split.first.length;
    for (final parts in split.skip(1)) {
      var i = 0;
      while (i < common && i < parts.length && _sameSegment(parts[i], split.first[i])) {
        i++;
      }
      common = i;
    }
    // A single item has nothing to compare against: keep its own name visible.
    if (split.length == 1 && common > 0) common--;
    // Keep at least one segment per item where possible, so a copy that sits
    // directly in the shared folder is still labelled by that folder's name.
    final allLonger = split.every((parts) => parts.length > common);
    if (!allLonger && common > 0) common--;
    return GroupLocations._(split.first.sublist(0, common), [for (final parts in split) parts.sublist(common)]);
  }

  /// Segments shared by every item.
  final List<String> prefix;
  final List<List<String>> _relative;

  /// Distinguishing segments for item [i] (never empty unless the item is
  /// a drive root).
  List<String> segmentsOf(int i) => _relative[i];

  /// Name of the shared folder, e.g. `Pictures` (short enough for a
  /// subtitle; [prefixPath] has the full path).
  String get prefixLabel {
    if (prefix.isEmpty) return '';
    final last = prefix.last;
    if (last == '/') return '/';
    return last.endsWith(':') ? '$last$_separator' : last;
  }

  /// The shared prefix as a path (for tooltips).
  String get prefixPath {
    if (prefix.isEmpty) return '';
    if (prefix.first == '/') return '/${prefix.skip(1).join('/')}';
    return prefix.join(_separator);
  }

  String get _separator =>
      prefix.isNotEmpty && (prefix.first.contains(':') || prefix.first.startsWith(r'\')) ? r'\' : '/';

  static bool _sameSegment(String a, String b) => a == b || (a.toLowerCase() == b.toLowerCase() && a.contains(':'));
}

/// Splits a path on both separators. Keeps a leading `/` (Unix root) as its
/// own segment so absolute paths stay distinguishable.
List<String> splitPath(String path) {
  final parts = path.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();
  if (path.startsWith('/') && !path.startsWith('//')) return ['/', ...parts];
  if (path.startsWith(r'\\') || path.startsWith('//')) {
    return parts.isEmpty ? parts : ['\\\\${parts.first}', ...parts.skip(1)];
  }
  return parts;
}

/// Lets long paths wrap only at separators instead of mid-name, by adding a
/// zero-width break opportunity after each `\` and `/`.
String softWrapPath(String path) => path.replaceAllMapped(RegExp(r'[\\/]'), (m) => '${m[0]}\u200B');

/// Joins display segments with a readable separator.
String joinSegments(List<String> segments) => segments.where((s) => s != '/').join(' › ');

/// Segments of [folder] starting at the scan root that contains it, e.g.
/// `Home › Videos › Family` for `C:\Users\me\Home\Videos\Family` scanned
/// from `C:\Users\me\Home`. Falls back to the last few segments.
List<String> segmentsUnderRoot(String folder, List<String> roots) {
  final parts = splitPath(folder);
  for (final root in roots) {
    final r = splitPath(root);
    if (r.isEmpty || r.length > parts.length) continue;
    var match = true;
    for (var i = 0; i < r.length; i++) {
      if (r[i].toLowerCase() != parts[i].toLowerCase()) {
        match = false;
        break;
      }
    }
    if (match) return [r.last, ...parts.sublist(r.length)];
  }
  return parts.length > 3 ? parts.sublist(parts.length - 3) : parts;
}
