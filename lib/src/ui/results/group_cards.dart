import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/native.dart';
import '../../core/path_display.dart';
import '../../rust/api/types.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import '../theme.dart';
import '../widgets/path_text.dart';

typedef SelectCallback = void Function(int id, bool selected);
typedef KeepCallback = void Function(int id);

/// Modification times closer than this are treated as equal, so "newest"
/// only appears when it is meaningful.
const _sameTimeMs = 60 * 1000;

/// "newest" / "oldest" hints, only when the copies' dates really differ.
Map<int, String> _ageHints(List<({int id, int modifiedMs})> items) {
  if (items.length < 2) return const {};
  final newest = items.reduce((a, b) => a.modifiedMs >= b.modifiedMs ? a : b);
  final oldest = items.reduce((a, b) => a.modifiedMs <= b.modifiedMs ? a : b);
  if (newest.modifiedMs - oldest.modifiedMs < _sameTimeMs) return const {};
  return {newest.id: 'newest', oldest.id: 'oldest'};
}

class FileGroupCard extends StatelessWidget {
  const FileGroupCard({
    super.key,
    required this.group,
    required this.onSelect,
    required this.onKeepOnly,
    required this.onOpenGroup,
    required this.onIgnoreGroup,
    required this.onIgnoreFolder,
    this.focused = false,
  });

  final FileGroupDto group;
  final SelectCallback onSelect;
  final KeepCallback onKeepOnly;
  final VoidCallback onOpenGroup;

  /// "Not duplicates": hide this group now and in later scans.
  final VoidCallback onIgnoreGroup;

  /// Exclude a folder (the copy's folder) from this and later scans.
  final ValueChanged<String> onIgnoreFolder;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = group.files;
    final first = files.first;
    final locations = GroupLocations.of([for (final f in files) f.parent]);
    final hints = _ageHints([for (final f in files) (id: f.id, modifiedMs: f.modifiedMs)]);
    final anySelected = files.any((f) => f.selected);
    final allSameName = files.every((f) => f.name == first.name);
    final where = locations.prefixLabel;

    return _GroupCard(
      focused: focused,
      header: _GroupHeader(
        leading: FileThumbnail(path: first.path, size: 40, color: categoryColor(group.category, theme.brightness)),
        title: first.name,
        subtitle: [
          '${files.length} copies',
          '${formatBytes(group.size)} each',
          if (where.isNotEmpty) 'in $where',
        ].join(' · '),
        subtitleTooltip: locations.prefix.isEmpty ? null : locations.prefixPath,
        reclaimable: group.wasted,
        onTap: onOpenGroup,
        openTooltip: 'Compare copies',
      ),
      rows: [
        for (var i = 0; i < files.length; i++)
          _CopyRow(
            selected: files[i].selected,
            showStatus: anySelected,
            location: locations.segmentsOf(i),
            fullPath: files[i].path,
            detail: [
              if (!allSameName) files[i].name,
              formatDateTime(files[i].modifiedMs),
              ?hints[files[i].id],
            ].join(' · '),
            onChanged: (v) => onSelect(files[i].id, v),
            menu: _CopyMenu(
              path: files[i].path,
              onKeepOnly: () => onKeepOnly(files[i].id),
              onIgnoreGroup: onIgnoreGroup,
              ignoreFolder: files[i].parent,
              onIgnoreFolder: onIgnoreFolder,
            ),
          ),
      ],
    );
  }
}

class FolderGroupCard extends StatelessWidget {
  const FolderGroupCard({
    super.key,
    required this.group,
    required this.onSelect,
    required this.onKeepOnly,
    required this.onOpenGroup,
    required this.onIgnoreGroup,
    required this.onIgnoreFolder,
    this.focused = false,
  });

  final FolderGroupDto group;
  final SelectCallback onSelect;
  final KeepCallback onKeepOnly;
  final VoidCallback onOpenGroup;

  /// "Not duplicates": hide this group now and in later scans.
  final VoidCallback onIgnoreGroup;

  /// Exclude a folder (the copy's folder) from this and later scans.
  final ValueChanged<String> onIgnoreFolder;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folders = group.folders;
    final locations = GroupLocations.of([for (final f in folders) f.path]);
    final hints = _ageHints([for (final f in folders) (id: f.id, modifiedMs: f.modifiedMs)]);
    final anySelected = folders.any((f) => f.selected);
    final sameName = folders.every((f) => f.name == folders.first.name);
    final where = locations.prefixLabel;

    return _GroupCard(
      focused: focused,
      header: _GroupHeader(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.zero),
          child: Icon(Icons.folder_copy_outlined, color: scheme.onTertiaryContainer, size: 22),
        ),
        title: sameName ? folders.first.name : '${folders.length} identical folders',
        subtitle: [
          if (sameName) '${folders.length} copies',
          plural(group.fileCount.toInt(), 'file'),
          '${formatBytes(group.totalBytes.toInt())} each',
          if (where.isNotEmpty) 'in $where',
        ].join(' · '),
        subtitleTooltip: locations.prefix.isEmpty ? null : locations.prefixPath,
        reclaimable: group.wasted.toInt(),
        onTap: onOpenGroup,
        openTooltip: 'Compare folders',
      ),
      rows: [
        for (var i = 0; i < folders.length; i++)
          _CopyRow(
            selected: folders[i].selected,
            showStatus: anySelected,
            location: locations.segmentsOf(i),
            fullPath: folders[i].path,
            detail: ['Modified ${formatDateTime(folders[i].modifiedMs)}', ?hints[folders[i].id]].join(' · '),
            onChanged: (v) => onSelect(folders[i].id, v),
            menu: _CopyMenu(
              path: folders[i].path,
              onKeepOnly: () => onKeepOnly(folders[i].id),
              isFolder: true,
              onIgnoreGroup: onIgnoreGroup,
              ignoreFolder: folders[i].path,
              onIgnoreFolder: onIgnoreFolder,
            ),
          ),
      ],
    );
  }
}

class EmptyFolderTile extends StatelessWidget {
  const EmptyFolderTile({super.key, required this.folder, required this.onSelect});

  final FolderEntryDto folder;
  final SelectCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: _CopyRow(
        selected: folder.selected,
        showStatus: folder.selected,
        location: [folder.name],
        fullPath: folder.path,
        detailSegments: splitPath(folder.parent),
        onChanged: (v) => onSelect(folder.id, v),
        menu: NativePlatform.canReveal
            ? IconButton(
                tooltip: 'Show in folder',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.folder_open_outlined, size: 20, color: theme.colorScheme.onSurfaceVariant),
                onPressed: () => NativePlatform.revealInFileManager(folder.path),
              )
            : const SizedBox(width: 8),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.header, required this.rows, required this.focused});

  final Widget header;
  final List<Widget> rows;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: focused ? RoundedRectangleBorder(side: BorderSide(color: context.ds.accent, width: Tokens.rule)) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [header, const Divider(height: 1), ...rows],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.reclaimable,
    required this.onTap,
    required this.openTooltip,
    this.subtitleTooltip,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final String? subtitleTooltip;
  final int reclaimable;
  final VoidCallback onTap;
  final String openTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget sub = Text(
      subtitle,
      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    if (subtitleTooltip != null) sub = Tooltip(message: subtitleTooltip!, child: sub);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  sub,
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatBytes(reclaimable),
                  style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                ),
                Text('to free', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
            Tooltip(
              message: openTooltip,
              child: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One copy: checkbox, the location that distinguishes it, and details.
class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.selected,
    required this.showStatus,
    required this.location,
    required this.fullPath,
    required this.onChanged,
    required this.menu,
    this.detail,
    this.detailSegments,
  });

  final bool selected;

  /// Show the Keep/Remove label (once anything in the group is selected).
  final bool showStatus;
  final List<String> location;
  final String fullPath;
  final String? detail;
  final List<String>? detailSegments;
  final ValueChanged<bool> onChanged;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final detailStyle = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Material(
      color: selected ? scheme.errorContainer.withValues(alpha: dark ? 0.28 : 0.4) : Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!selected),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 0, 2),
          child: Row(
            children: [
              Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (showStatus) ...[
                            selected
                                ? TagChip('Remove', color: context.ds.ink, outlined: true)
                                : TagChip('Keep', color: context.ds.accent, icon: Icons.check),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: PathSegmentsText(
                              location,
                              tooltip: fullPath,
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if (detailSegments != null)
                        PathSegmentsText(detailSegments!, style: detailStyle)
                      else if (detail != null)
                        Text(detail!, style: detailStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
              menu,
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyMenu extends StatelessWidget {
  const _CopyMenu({
    required this.path,
    required this.onKeepOnly,
    this.isFolder = false,
    this.onIgnoreGroup,
    this.ignoreFolder,
    this.onIgnoreFolder,
  });

  final String path;

  /// `null` hides "Keep only this" (lists that are not duplicate groups).
  final VoidCallback? onKeepOnly;
  final bool isFolder;

  /// `null` hides "Not duplicates".
  final VoidCallback? onIgnoreGroup;

  /// Folder offered by "Ignore folder"; hidden when `null`.
  final String? ignoreFolder;
  final ValueChanged<String>? onIgnoreFolder;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (v) async {
        switch (v) {
          case 'keep':
            onKeepOnly?.call();
          case 'ignore-group':
            onIgnoreGroup?.call();
          case 'ignore-folder':
            onIgnoreFolder?.call(ignoreFolder!);
          case 'open':
            await openFile(context, path);
          case 'reveal':
            await NativePlatform.revealInFileManager(path);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: path));
            if (context.mounted) showMessage(context, 'Path copied');
        }
      },
      itemBuilder: (_) => [
        if (onKeepOnly != null)
          const PopupMenuItem(
            value: 'keep',
            child: ListTile(leading: Icon(Icons.push_pin_outlined), title: Text('Keep only this')),
          ),
        if (!isFolder)
          const PopupMenuItem(
            value: 'open',
            child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open')),
          ),
        if (NativePlatform.canReveal)
          const PopupMenuItem(
            value: 'reveal',
            child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Show in folder')),
          ),
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(leading: Icon(Icons.copy), title: Text('Copy full path')),
        ),
        if (onIgnoreGroup != null || (ignoreFolder != null && onIgnoreFolder != null)) const PopupMenuDivider(),
        if (onIgnoreGroup != null)
          const PopupMenuItem(
            value: 'ignore-group',
            child: ListTile(
              leading: Icon(Icons.visibility_off_outlined),
              title: Text('Not duplicates'),
              subtitle: Text('Hide this group in every scan'),
            ),
          ),
        if (ignoreFolder != null && onIgnoreFolder != null)
          PopupMenuItem(
            value: 'ignore-folder',
            child: ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: Text('Ignore “${splitPath(ignoreFolder!).lastOrNull ?? ignoreFolder}”'),
              subtitle: const Text('Exclude this folder from scans'),
            ),
          ),
      ],
    );
  }
}

/// One file in the large-files list: what it is, where it lives (from the
/// scanned folder down), how old it is and how big.
class LargeFileTile extends StatelessWidget {
  const LargeFileTile({super.key, required this.file, required this.roots, required this.onSelect});

  final FileEntryDto file;
  final List<String> roots;
  final SelectCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      child: Material(
        color: file.selected ? scheme.errorContainer.withValues(alpha: dark ? 0.28 : 0.4) : Colors.transparent,
        child: InkWell(
          onTap: () => onSelect(file.id, !file.selected),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
            child: Row(
              children: [
                Checkbox(value: file.selected, onChanged: (v) => onSelect(file.id, v ?? false)),
                FileThumbnail(path: file.path, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      PathSegmentsText(segmentsUnderRoot(file.parent, roots), tooltip: file.path, style: small),
                      Text(
                        _modified(file.modifiedMs, compact: context.isCompact),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  formatBytes(file.size),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.primary),
                ),
                _CopyMenu(path: file.path, onKeepOnly: null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Modified 3 days ago" on phones, "Modified Mar 3, 2024 · 3 days ago" on
/// wider screens; older files show only the date.
String _modified(int ms, {required bool compact}) {
  final date = formatDate(ms);
  final relative = formatRelative(ms);
  if (relative == date) return 'Modified $date';
  return compact ? 'Modified $relative' : 'Modified $date · $relative';
}

String junkKindLabel(JunkKind kind) => switch (kind) {
  JunkKind.systemCache => 'System cache',
  JunkKind.partialDownload => 'Unfinished download',
  JunkKind.tempFile => 'Temporary file',
  JunkKind.emptyFile => 'Empty file',
  JunkKind.brokenLink => 'Broken shortcut',
};

IconData junkKindIcon(JunkKind kind) => switch (kind) {
  JunkKind.systemCache => Icons.cached,
  JunkKind.partialDownload => Icons.downloading,
  JunkKind.tempFile => Icons.timelapse,
  JunkKind.emptyFile => Icons.insert_drive_file_outlined,
  JunkKind.brokenLink => Icons.link_off,
};

/// One junk item: what kind it is, where it lives and how big it is.
class JunkTile extends StatelessWidget {
  const JunkTile({super.key, required this.item, required this.roots, required this.onSelect});

  final JunkEntryDto item;
  final List<String> roots;
  final SelectCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      child: Material(
        color: item.selected ? scheme.errorContainer.withValues(alpha: dark ? 0.28 : 0.4) : Colors.transparent,
        child: InkWell(
          onTap: () => onSelect(item.id, !item.selected),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
            child: Row(
              children: [
                Checkbox(value: item.selected, onChanged: (v) => onSelect(item.id, v ?? false)),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Icon(junkKindIcon(item.kind), size: 20, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      PathSegmentsText(segmentsUnderRoot(item.parent, roots), tooltip: item.path, style: small),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: junkKindLabel(item.kind)),
                            if (item.safe)
                              TextSpan(
                                text: ' · safe to remove',
                                style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                              ),
                            TextSpan(text: ' · ${formatRelative(item.modifiedMs)}'),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (item.size > 0)
                  Text(
                    formatBytes(item.size),
                    style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                  ),
                // A broken link cannot be opened.
                _CopyMenu(path: item.path, onKeepOnly: null, isFolder: item.kind == JunkKind.brokenLink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
