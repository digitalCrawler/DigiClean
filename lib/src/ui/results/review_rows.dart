import 'package:flutter/material.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/path_display.dart';
import '../../rust/api/types.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import 'photo_cards.dart' show photoIssueLabel;

/// Every row in a review list has this height, so long lists scroll cheaply
/// and keyboard navigation can scroll to any row directly.
const double reviewRowExtent = 76;

typedef SelectCallback = void Function(int id, bool selected);

/// One line of a review list: picture, what it is, where, and how much.
class ReviewRow extends StatelessWidget {
  const ReviewRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.focused,
    required this.onTap,
    this.amount,
    this.status,
    this.marked = false,
    this.onMarked,
  });

  final Widget leading;
  final String title;
  final String subtitle;

  /// Size shown on the right (space to free, or the file size).
  final int? amount;

  /// Small badge under the amount ("2 to remove").
  final Widget? status;

  /// The row is the one shown in the preview pane.
  final bool focused;
  final VoidCallback onTap;

  /// Single items (large files, junk…): marked for removal, with a checkbox.
  final bool marked;
  final ValueChanged<bool>? onMarked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return Material(
      color: focused ? ds.surfaceStrong : theme.colorScheme.surfaceContainerLowest,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: reviewRowExtent,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: focused ? ds.accent : Colors.transparent, width: 4),
              bottom: BorderSide(color: ds.hairline),
            ),
          ),
          padding: EdgeInsets.only(left: onMarked == null ? 12 : 2, right: 12),
          child: Row(
            children: [
              if (onMarked != null) Checkbox(value: marked, onChanged: (v) => onMarked!(v ?? false)),
              SizedBox(width: 52, height: 52, child: leading),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        decoration: marked ? TextDecoration.lineThrough : null,
                        decorationColor: ds.muted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (amount != null || status != null) ...[
                const SizedBox(width: 10),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (amount != null)
                      Text(
                        formatBytes(amount!),
                        style: displayStyle(
                          17,
                          color: ds.ink,
                        ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    if (status != null) ...[const SizedBox(height: 4), status!],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "2 to remove" when a group has a decision, nothing otherwise.
Widget? removalStatus(BuildContext context, int marked, int total) {
  if (marked == 0) return null;
  if (marked >= total) return TagChip('All marked', color: Theme.of(context).colorScheme.error);
  return TagChip('$marked to remove', color: context.ds.ink, outlined: true);
}

class FolderIconBox extends StatelessWidget {
  const FolderIconBox({super.key, this.icon = Icons.folder_copy_outlined});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.ds.surfaceStrong,
      alignment: Alignment.center,
      child: Icon(icon, color: context.ds.ink, size: 26),
    );
  }
}

Widget fileGroupRow(BuildContext context, FileGroupDto g, {required bool focused, required VoidCallback onTap}) {
  final files = g.files;
  final where = GroupLocations.of([for (final f in files) f.parent]).prefixLabel;
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    leading: FileThumbnail(
      path: files.first.path,
      size: 52,
      color: categoryColor(g.category, Theme.of(context).brightness),
    ),
    title: files.first.name,
    subtitle: ['${files.length} copies', '${formatBytes(g.size)} each', if (where.isNotEmpty) 'in $where'].join(' · '),
    amount: g.wasted,
    status: removalStatus(context, files.where((f) => f.selected).length, files.length),
  );
}

Widget folderGroupRow(BuildContext context, FolderGroupDto g, {required bool focused, required VoidCallback onTap}) {
  final folders = g.folders;
  final sameName = folders.every((f) => f.name == folders.first.name);
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    leading: const FolderIconBox(),
    title: sameName ? folders.first.name : '${folders.length} identical folders',
    subtitle: [
      '${folders.length} copies',
      plural(g.fileCount.toInt(), 'file'),
      '${formatBytes(g.totalBytes.toInt())} each',
    ].join(' · '),
    amount: g.wasted.toInt(),
    status: removalStatus(context, folders.where((f) => f.selected).length, folders.length),
  );
}

Widget similarGroupRow(BuildContext context, SimilarGroupDto g, {required bool focused, required VoidCallback onTap}) {
  final photos = g.photos;
  final where = GroupLocations.of([for (final p in photos) p.parent]).prefixLabel;
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    leading: _PhotoStack(paths: [for (final p in photos.take(3)) p.path]),
    title: '${photos.length} similar photos',
    subtitle: [if (where.isNotEmpty) 'in $where', photos.first.name].join(' · '),
    amount: g.reclaimable,
    status: removalStatus(context, photos.where((p) => p.selected).length, photos.length),
  );
}

Widget mediaGroupRow(BuildContext context, MediaGroupDto g, {required bool focused, required VoidCallback onTap}) {
  final items = g.items;
  final video = items.any((m) => m.video);
  final best = items.firstWhere((m) => m.best, orElse: () => items.first);
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    leading: FileThumbnail(path: best.path, size: 52, color: context.ds.ink),
    title: best.name,
    subtitle: [
      '${items.length} copies of the same ${video ? 'video' : 'song'}',
      if (best.durationMs != null) formatClock(best.durationMs!),
    ].join(' · '),
    amount: g.reclaimable,
    status: removalStatus(context, items.where((m) => m.selected).length, items.length),
  );
}

Widget fileEntryRow(
  BuildContext context,
  FileEntryDto f,
  List<String> roots, {
  required bool focused,
  required VoidCallback onTap,
  required SelectCallback onSelect,
}) {
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    marked: f.selected,
    onMarked: (v) => onSelect(f.id, v),
    leading: FileThumbnail(path: f.path, size: 52),
    title: f.name,
    subtitle: [
      joinSegments(segmentsUnderRoot(f.parent, roots)),
      'modified ${formatRelative(f.modifiedMs)}',
    ].join(' · '),
    amount: f.size,
  );
}

Widget photoIssueRow(
  BuildContext context,
  PhotoDto p,
  List<String> roots, {
  required bool focused,
  required VoidCallback onTap,
  required SelectCallback onSelect,
}) {
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    marked: p.selected,
    onMarked: (v) => onSelect(p.id, v),
    leading: FileThumbnail(path: p.path, size: 52),
    title: p.name,
    subtitle: [p.issues.map(photoIssueLabel).join(', '), joinSegments(segmentsUnderRoot(p.parent, roots))].join(' · '),
    amount: p.size,
  );
}

Widget junkRow(
  BuildContext context,
  JunkEntryDto j,
  List<String> roots, {
  required bool focused,
  required VoidCallback onTap,
  required SelectCallback onSelect,
}) {
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    marked: j.selected,
    onMarked: (v) => onSelect(j.id, v),
    leading: FolderIconBox(icon: junkKindIcon(j.kind)),
    title: j.name,
    subtitle: [
      junkKindLabel(j.kind),
      if (j.safe) 'safe to remove',
      joinSegments(segmentsUnderRoot(j.parent, roots)),
    ].join(' · '),
    amount: j.size > 0 ? j.size : null,
  );
}

Widget emptyFolderRow(
  BuildContext context,
  FolderEntryDto f, {
  required bool focused,
  required VoidCallback onTap,
  required SelectCallback onSelect,
}) {
  return ReviewRow(
    focused: focused,
    onTap: onTap,
    marked: f.selected,
    onMarked: (v) => onSelect(f.id, v),
    leading: const FolderIconBox(icon: Icons.folder_off_outlined),
    title: f.name,
    subtitle: joinSegments(splitPath(f.parent)),
  );
}

/// Up to three photos fanned out, for similar-photo rows.
class _PhotoStack extends StatelessWidget {
  const _PhotoStack({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final rule = context.ds.ink;
    return Stack(
      children: [
        for (var i = paths.length - 1; i >= 0; i--)
          Positioned(
            left: i * 6.0,
            top: i * 6.0,
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: rule, width: 1.5)),
              child: FileThumbnail(path: paths[i], size: 52 - (paths.length - 1) * 6.0 - 3),
            ),
          ),
      ],
    );
  }
}

String junkKindLabel(JunkKind kind) => switch (kind) {
  JunkKind.systemCache => 'System cache',
  JunkKind.partialDownload => 'Unfinished download',
  JunkKind.tempFile => 'Temporary file',
  JunkKind.emptyFile => 'Empty file',
  JunkKind.brokenLink => 'Broken shortcut',
};

/// Why an item counts as junk, for the preview pane.
String junkKindExplanation(JunkKind kind) => switch (kind) {
  JunkKind.systemCache => 'A cache the system or an app rebuilds by itself when needed, such as thumbnail databases.',
  JunkKind.partialDownload => 'A download that never finished. Browsers leave these behind when a download fails.',
  JunkKind.tempFile => 'A temporary file an app left behind. It is usually safe to remove once the app is closed.',
  JunkKind.emptyFile => 'A file with no contents at all.',
  JunkKind.brokenLink => 'A shortcut whose target no longer exists.',
};

IconData junkKindIcon(JunkKind kind) => switch (kind) {
  JunkKind.systemCache => Icons.cached,
  JunkKind.partialDownload => Icons.downloading,
  JunkKind.tempFile => Icons.timelapse,
  JunkKind.emptyFile => Icons.insert_drive_file_outlined,
  JunkKind.brokenLink => Icons.link_off,
};
