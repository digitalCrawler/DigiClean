import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/native.dart';
import '../../core/path_display.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../../state/results_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import '../widgets/path_text.dart';
import 'photo_cards.dart' show photoIssueLabel;
import 'review_rows.dart' show junkKindExplanation, junkKindLabel;

/// Runs a selection change against the results and refreshes the list row.
typedef ApplySelection = void Function(SelectionSummaryDto Function(ScanResults r) call);

/// Modification times closer than this are treated as equal, so "newest"
/// only appears when it is meaningful.
const _sameTimeMs = 60 * 1000;

Map<int, String> _ageHints(List<({int id, int modifiedMs})> items) {
  if (items.length < 2) return const {};
  final newest = items.reduce((a, b) => a.modifiedMs >= b.modifiedMs ? a : b);
  final oldest = items.reduce((a, b) => a.modifiedMs <= b.modifiedMs ? a : b);
  if (newest.modifiedMs - oldest.modifiedMs < _sameTimeMs) return const {};
  return {newest.id: 'newest', oldest.id: 'oldest'};
}

/// Keep or remove, as two explicit choices.
class DecisionToggle extends StatelessWidget {
  const DecisionToggle({super.key, required this.remove, required this.onChanged});

  final bool remove;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final surface = Theme.of(context).colorScheme.surface;
    Widget segment(
      String label,
      IconData icon, {
      required bool on,
      required Color fill,
      required Color fg,
      required bool value,
    }) {
      return Semantics(
        button: true,
        selected: on,
        child: InkWell(
          onTap: on ? null : () => onChanged(value),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: on ? fill : null,
              border: Border.all(color: on ? fill : ds.ink, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: on ? fg : ds.ink),
                const SizedBox(width: 6),
                Text(
                  label.toUpperCase(),
                  style: capsStyle(on ? fg : ds.ink, size: 11).copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        segment('Keep', Icons.check, on: !remove, fill: ds.accent, fg: ds.onAccent, value: false),
        Transform.translate(
          offset: const Offset(-2, 0),
          child: segment('Remove', Icons.close, on: remove, fill: ds.ink, fg: surface, value: true),
        ),
      ],
    );
  }
}

/// Pane layout: the preview takes a good share of the height, the details
/// scroll underneath.
class _DetailList extends StatelessWidget {
  const _DetailList({required this.builder});

  final List<Widget> Function(double previewHeight) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight.isFinite ? (box.maxHeight * 0.44).clamp(200.0, 520.0) : 300.0;
        return Scrollbar(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 28), children: builder(h)),
        );
      },
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.title, required this.subtitle, this.trailing});

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(title, style: displayStyle(26, color: ds.ink)),
              const SizedBox(height: 6),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ds.muted)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24, bottom: 4),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(border: Border(top: context.ds.rule)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: capsStyle(context.ds.ink, size: 12).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Nothing (left) to decide in this group.
const _resolved = EmptyState(
  icon: Icons.check,
  title: 'Nothing left to decide',
  message: 'This group no longer has duplicates.',
);

// ── Duplicate files ─────────────────────────────────────────────────────

class FileGroupDetail extends ConsumerStatefulWidget {
  const FileGroupDetail({
    super.key,
    required this.groupIndex,
    required this.apply,
    required this.onIgnoreGroup,
    required this.onIgnoreFolder,
  });

  final int groupIndex;
  final ApplySelection apply;
  final VoidCallback onIgnoreGroup;
  final ValueChanged<String> onIgnoreFolder;

  @override
  ConsumerState<FileGroupDetail> createState() => _FileGroupDetailState();
}

class _FileGroupDetailState extends ConsumerState<FileGroupDetail> {
  final Map<int, String?> _verified = {};
  bool _verifying = false;

  Future<void> _verify(FileGroupDto group, HashAlgo algo) async {
    setState(() {
      _verifying = true;
      _verified.clear();
    });
    for (final f in group.files) {
      try {
        _verified[f.id] = await hashFile(path: f.path, algorithm: algo);
      } catch (_) {
        _verified[f.id] = null;
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _verifying = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
    final results = ref.watch(resultsProvider).results;
    FileGroupDto? group;
    var algo = HashAlgo.blake3;
    try {
      group = results?.fileGroup(index: widget.groupIndex);
      algo = results?.hashAlgorithm() ?? algo;
    } catch (_) {}
    if (results == null || group == null || group.files.length < 2) return _resolved;

    final g = group;
    final files = g.files;
    final ds = context.ds;
    final locations = GroupLocations.of([for (final f in files) f.parent]);
    final hints = _ageHints([for (final f in files) (id: f.id, modifiedMs: f.modifiedMs)]);
    final allSameName = files.every((f) => f.name == files.first.name);
    final marked = files.where((f) => f.selected).length;

    return _DetailList(
      builder: (previewHeight) => [
        FilePreview(path: files.first.path, height: hasRichPreview(files.first.path) ? previewHeight : 140),
        const SizedBox(height: 16),
        _Title(
          title: files.first.name,
          subtitle:
              '${files.length} identical copies · ${formatBytes(g.size)} each · ${categoryLabel(g.category)}'
              '${marked > 0 ? ' · $marked to remove' : ''}',
          trailing: OutlinedButton.icon(
            onPressed: () => openFile(context, files.first.path),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open'),
          ),
        ),
        _SectionLabel(
          'Copies — choose what to keep',
          trailing: TextButton.icon(
            onPressed: _verifying ? null : () => _verify(g, algo),
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: Text(_verifying ? 'Checking…' : 'Verify contents'),
          ),
        ),
        if (locations.prefix.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'All inside ${softWrapPath(locations.prefixPath)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (var i = 0; i < files.length; i++)
          _CopyDecision(
            remove: files[i].selected,
            location: locations.segmentsOf(i),
            fullPath: files[i].path,
            details: [
              if (!allSameName) files[i].name,
              'Modified ${formatDateTime(files[i].modifiedMs)}',
              if (files[i].createdMs != null) 'Created ${formatDateTime(files[i].createdMs!)}',
              ?hints[files[i].id],
            ],
            verification: _verified.containsKey(files[i].id) ? _verified[files[i].id] == g.hash : null,
            onChanged: (remove) => widget.apply((r) => r.setFileSelected(fileId: files[i].id, selected: remove)),
            onKeepOnly: () => widget.apply(
              (r) => r.keepOnly(kind: ResultKind.files, groupIndex: widget.groupIndex, keepId: files[i].id),
            ),
            canOpen: true,
            onIgnoreGroup: widget.onIgnoreGroup,
            ignoreFolder: files[i].parent,
            onIgnoreFolder: widget.onIgnoreFolder,
          ),
        const SizedBox(height: 16),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: g.hash));
            showMessage(context, 'Hash copied');
          },
          child: Text(
            '${algo == HashAlgo.blake3 ? 'BLAKE3' : 'SHA-256'}  ${g.hash}',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: ds.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// One copy with its keep/remove decision.
class _CopyDecision extends StatelessWidget {
  const _CopyDecision({
    required this.remove,
    required this.location,
    required this.fullPath,
    required this.details,
    required this.onChanged,
    required this.onKeepOnly,
    required this.canOpen,
    this.verification,
    this.onIgnoreGroup,
    this.ignoreFolder,
    this.onIgnoreFolder,
  });

  final bool remove;
  final List<String> location;
  final String fullPath;
  final List<String> details;
  final ValueChanged<bool> onChanged;
  final VoidCallback onKeepOnly;
  final bool canOpen;
  final bool? verification;
  final VoidCallback? onIgnoreGroup;
  final String? ignoreFolder;
  final ValueChanged<String>? onIgnoreFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ds.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DecisionToggle(remove: remove, onChanged: onChanged),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: PathSegmentsText(
                  location,
                  tooltip: fullPath,
                  style: theme.textTheme.titleSmall?.copyWith(
                    decoration: remove ? TextDecoration.lineThrough : null,
                    decorationColor: ds.muted,
                  ),
                ),
              ),
              if (verification != null)
                TagChip(
                  verification! ? 'Identical' : 'Changed',
                  color: verification! ? ds.ink : theme.colorScheme.error,
                  icon: verification! ? Icons.verified : Icons.error_outline,
                ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(softWrapPath(fullPath), style: theme.textTheme.bodySmall),
          Text(details.join(' · '), style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                onPressed: onKeepOnly,
                icon: const Icon(Icons.push_pin_outlined, size: 18),
                label: const Text('Keep only this'),
              ),
              if (canOpen)
                IconButton(
                  tooltip: 'Open',
                  onPressed: () => openFile(context, fullPath),
                  icon: const Icon(Icons.open_in_new, size: 20),
                ),
              if (NativePlatform.canReveal)
                IconButton(
                  tooltip: 'Show in folder',
                  onPressed: () => NativePlatform.revealInFileManager(fullPath),
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                ),
              PathMenu(
                path: fullPath,
                onIgnoreGroup: onIgnoreGroup,
                ignoreFolder: ignoreFolder,
                onIgnoreFolder: onIgnoreFolder,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Copy path, "Not duplicates" and "Ignore folder".
class PathMenu extends StatelessWidget {
  const PathMenu({super.key, required this.path, this.onIgnoreGroup, this.ignoreFolder, this.onIgnoreFolder});

  final String path;

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
          case 'ignore-group':
            onIgnoreGroup?.call();
          case 'ignore-folder':
            onIgnoreFolder?.call(ignoreFolder!);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: path));
            if (context.mounted) showMessage(context, 'Path copied');
        }
      },
      itemBuilder: (_) => [
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

// ── Duplicate folders ───────────────────────────────────────────────────

class FolderGroupDetail extends ConsumerWidget {
  const FolderGroupDetail({
    super.key,
    required this.groupIndex,
    required this.apply,
    required this.onIgnoreGroup,
    required this.onIgnoreFolder,
  });

  final int groupIndex;
  final ApplySelection apply;
  final VoidCallback onIgnoreGroup;
  final ValueChanged<String> onIgnoreFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
    final results = ref.watch(resultsProvider).results;
    FolderGroupDto? group;
    try {
      group = results?.folderGroup(index: groupIndex);
    } catch (_) {}
    if (results == null || group == null || group.folders.length < 2) return _resolved;
    final g = group;
    final folders = g.folders;
    final locations = GroupLocations.of([for (final f in folders) f.path]);
    final hints = _ageHints([for (final f in folders) (id: f.id, modifiedMs: f.modifiedMs)]);

    return _DetailList(
      builder: (_) => [
        _Title(
          title: folders.every((f) => f.name == folders.first.name)
              ? folders.first.name
              : '${folders.length} identical folders',
          subtitle:
              '${folders.length} identical folders · ${plural(g.fileCount.toInt(), 'file')}'
              '${g.dirCount > 0 ? ' in ${plural(g.dirCount.toInt(), 'sub-folder')}' : ''} · '
              '${formatBytes(g.totalBytes.toInt())} each',
        ),
        const _SectionLabel('Copies — choose what to keep'),
        for (var i = 0; i < folders.length; i++)
          _CopyDecision(
            remove: folders[i].selected,
            location: locations.segmentsOf(i),
            fullPath: folders[i].path,
            details: ['Modified ${formatDateTime(folders[i].modifiedMs)}', ?hints[folders[i].id]],
            onChanged: (remove) => apply((r) => r.setFolderSelected(folderId: folders[i].id, selected: remove)),
            onKeepOnly: () =>
                apply((r) => r.keepOnly(kind: ResultKind.folders, groupIndex: groupIndex, keepId: folders[i].id)),
            canOpen: false,
            onIgnoreGroup: onIgnoreGroup,
            ignoreFolder: folders[i].path,
            onIgnoreFolder: onIgnoreFolder,
          ),
        const _SectionLabel('Contents — the same in every copy'),
        FolderContents(key: ValueKey(folders.first.id), results: results, folderId: folders.first.id),
      ],
    );
  }
}

class FolderContents extends StatefulWidget {
  const FolderContents({super.key, required this.results, required this.folderId});

  final ScanResults results;
  final int folderId;

  @override
  State<FolderContents> createState() => _FolderContentsState();
}

class _FolderContentsState extends State<FolderContents> {
  late final Future<FolderChildren> _children = widget.results.folderChildren(folderId: widget.folderId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<FolderChildren>(
      future: _children,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 48);
        final c = snap.data!;
        const limit = 200;
        return Column(
          children: [
            for (final d in c.folders)
              ListTile(dense: true, leading: const Icon(Icons.folder_outlined, size: 22), title: Text(d.name)),
            for (final f in c.files.take(limit))
              ListTile(
                dense: true,
                leading: FileThumbnail(path: f.path, size: 28),
                title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(formatBytes(f.size), style: theme.textTheme.bodySmall),
              ),
            if (c.files.length > limit)
              Padding(padding: const EdgeInsets.all(12), child: Text('… and ${c.files.length - limit} more files')),
          ],
        );
      },
    );
  }
}

// ── Similar photos ──────────────────────────────────────────────────────

class SimilarPhotosDetail extends ConsumerWidget {
  const SimilarPhotosDetail({super.key, required this.groupIndex, required this.apply});

  final int groupIndex;
  final ApplySelection apply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
    final results = ref.watch(resultsProvider).results;
    SimilarGroupDto? group;
    try {
      group = results?.similarGroup(index: groupIndex);
    } catch (_) {}
    if (results == null || group == null || group.photos.length < 2) return _resolved;
    final photos = group.photos;
    final locations = GroupLocations.of([for (final p in photos) p.parent]);

    void keepBest() => apply((r) {
      late SelectionSummaryDto summary;
      for (final p in photos) {
        summary = r.setSimilarSelected(fileId: p.id, selected: !p.best);
      }
      return summary;
    });

    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 860 ? 3 : (box.maxWidth >= 420 ? 2 : 1);
        return Scrollbar(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              _Title(
                title: '${photos.length} similar photos',
                subtitle:
                    'They look alike: resized, re-saved or taken in a burst. The sharpest, largest one is marked best. '
                    '${formatBytes(group!.reclaimable)} can be freed.',
                trailing: FilledButton.tonalIcon(
                  onPressed: keepBest,
                  icon: const Icon(Icons.star_outline),
                  label: const Text('Keep only the best'),
                ),
              ),
              const SizedBox(height: 16),
              _Grid(
                columns: columns,
                children: [
                  for (var i = 0; i < photos.length; i++)
                    _PhotoChoice(
                      photo: photos[i],
                      location: locations.segmentsOf(i),
                      onChanged: (remove) => apply((r) => r.setSimilarSelected(fileId: photos[i].id, selected: remove)),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: 16),
                Expanded(child: i + c < children.length ? children[i + c] : const SizedBox.shrink()),
              ],
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

class _PhotoChoice extends StatelessWidget {
  const _PhotoChoice({required this.photo, required this.location, required this.onChanged});

  final PhotoDto photo;
  final List<String> location;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final px = (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).clamp(128, 1600).round();
            return Stack(
              children: [
                InkWell(
                  onTap: () => openFile(context, photo.path),
                  child: Container(
                    height: box.maxWidth * 0.75,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: ds.surfaceStrong,
                      border: Border.all(
                        color: photo.best ? ds.accent : (photo.selected ? ds.ink : ds.hairline),
                        width: 3,
                      ),
                    ),
                    child: Opacity(
                      opacity: photo.selected ? 0.45 : 1,
                      child: Image.file(
                        File(photo.path),
                        cacheWidth: px,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => FileThumbnail(path: photo.path, size: box.maxWidth * 0.5),
                      ),
                    ),
                  ),
                ),
                if (photo.best)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: TagChip('Best', color: ds.accent, icon: Icons.star),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        DecisionToggle(remove: photo.selected, onChanged: onChanged),
        const SizedBox(height: 6),
        Text(photo.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
        PathSegmentsText(location, tooltip: photo.path, style: theme.textTheme.bodySmall),
        Text(
          [
            if (photo.width > 0) '${photo.width}×${photo.height}',
            formatBytes(photo.size),
            formatDate(photo.modifiedMs),
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ── Similar songs and videos ────────────────────────────────────────────

class MediaGroupDetail extends ConsumerWidget {
  const MediaGroupDetail({super.key, required this.groupIndex, required this.apply});

  final int groupIndex;
  final ApplySelection apply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
    final results = ref.watch(resultsProvider).results;
    MediaGroupDto? group;
    try {
      group = results?.mediaGroup(index: groupIndex);
    } catch (_) {}
    if (results == null || group == null || group.items.length < 2) return _resolved;
    final items = group.items;
    final video = items.any((m) => m.video);
    final best = items.firstWhere((m) => m.best, orElse: () => items.first);
    final locations = GroupLocations.of([for (final m in items) m.parent]);
    final theme = Theme.of(context);
    final ds = context.ds;

    void keepBest() => apply((r) {
      late SelectionSummaryDto summary;
      for (final m in items) {
        summary = r.setMediaSelected(fileId: m.id, selected: !m.best);
      }
      return summary;
    });

    return _DetailList(
      builder: (previewHeight) => [
        FilePreview(path: best.path, height: previewHeight),
        const SizedBox(height: 16),
        _Title(
          title: '${items.length} copies of the same ${video ? 'video' : 'song'}',
          subtitle:
              'They sound the same, in another format or quality. The best one is marked. '
              '${formatBytes(group!.reclaimable)} can be freed.',
          trailing: FilledButton.tonalIcon(
            onPressed: keepBest,
            icon: const Icon(Icons.star_outline),
            label: const Text('Keep only the best'),
          ),
        ),
        const _SectionLabel('Copies — choose what to keep'),
        for (var i = 0; i < items.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: ds.hairline)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: FileThumbnail(path: items[i].path, size: 64, color: ds.ink),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DecisionToggle(
                            remove: items[i].selected,
                            onChanged: (remove) =>
                                apply((r) => r.setMediaSelected(fileId: items[i].id, selected: remove)),
                          ),
                          if (items[i].best) TagChip('Best', color: ds.accent, icon: Icons.star),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        items[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      PathSegmentsText(
                        locations.segmentsOf(i),
                        tooltip: items[i].path,
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        [
                          if (items[i].durationMs != null) formatClock(items[i].durationMs!),
                          extensionOf(items[i].path).toUpperCase(),
                          formatBytes(items[i].size),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Play',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: () => openFile(context, items[i].path),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Single files: large, old, photos to review, junk ───────────────────

class SingleFileDetail extends StatelessWidget {
  const SingleFileDetail({
    super.key,
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedMs,
    required this.remove,
    required this.onChanged,
    this.createdMs,
    this.kindLabel,
    this.badges = const [],
    this.explanation,
    this.extraFacts = const [],
  });

  final String path;
  final String name;
  final int size;
  final int modifiedMs;
  final int? createdMs;
  final bool remove;
  final ValueChanged<bool> onChanged;

  /// "Large file", "Junk: System cache"…
  final String? kindLabel;
  final List<Widget> badges;

  /// Why this item is listed (junk).
  final String? explanation;
  final List<(String, String)> extraFacts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    final facts = <(String, String)>[
      ('Location', softWrapPath(path)),
      ('Size', formatBytes(size)),
      ('Modified', '${formatDateTime(modifiedMs)} · ${formatRelative(modifiedMs)}'),
      if (createdMs != null) ('Created', formatDateTime(createdMs!)),
      ...extraFacts,
    ];
    return _DetailList(
      builder: (previewHeight) => [
        FilePreview(path: path, height: hasRichPreview(path) ? previewHeight : 140),
        const SizedBox(height: 16),
        _Title(
          title: name,
          subtitle: kindLabel ?? formatBytes(size),
          trailing: OutlinedButton.icon(
            onPressed: () => openFile(context, path),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open'),
          ),
        ),
        if (badges.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(spacing: 6, runSpacing: 6, children: badges),
          ),
        if (explanation != null)
          Container(
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.all(12),
            color: ds.surfaceStrong,
            child: Text(explanation!, style: theme.textTheme.bodyMedium),
          ),
        _SectionLabel(
          'Decision',
          trailing: NativePlatform.canReveal
              ? TextButton.icon(
                  onPressed: () => NativePlatform.revealInFileManager(path),
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Show in folder'),
                )
              : null,
        ),
        const SizedBox(height: 8),
        DecisionToggle(remove: remove, onChanged: onChanged),
        const _SectionLabel('Details'),
        for (final (label, value) in facts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 96, child: Text(label.toUpperCase(), style: capsStyle(ds.muted, size: 10.5))),
                Expanded(child: SelectableText(value, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

SingleFileDetail fileEntryDetail(FileEntryDto f, {required String kindLabel, required ValueChanged<bool> onChanged}) =>
    SingleFileDetail(
      key: ValueKey(f.id),
      path: f.path,
      name: f.name,
      size: f.size,
      modifiedMs: f.modifiedMs,
      createdMs: f.createdMs,
      remove: f.selected,
      onChanged: onChanged,
      kindLabel: kindLabel,
    );

SingleFileDetail photoIssueDetail(BuildContext context, PhotoDto p, {required ValueChanged<bool> onChanged}) =>
    SingleFileDetail(
      key: ValueKey(p.id),
      path: p.path,
      name: p.name,
      size: p.size,
      modifiedMs: p.modifiedMs,
      remove: p.selected,
      onChanged: onChanged,
      kindLabel: 'Photo to review',
      badges: [for (final k in p.issues) TagChip(photoIssueLabel(k), color: context.ds.ink)],
      extraFacts: [if (p.width > 0) ('Resolution', '${p.width} × ${p.height}')],
    );

SingleFileDetail junkDetail(BuildContext context, JunkEntryDto j, {required ValueChanged<bool> onChanged}) =>
    SingleFileDetail(
      key: ValueKey(j.id),
      path: j.path,
      name: j.name,
      size: j.size,
      modifiedMs: j.modifiedMs,
      remove: j.selected,
      onChanged: onChanged,
      kindLabel: 'Junk · ${junkKindLabel(j.kind)}',
      badges: [if (j.safe) TagChip('Safe to remove', color: context.ds.accent, icon: Icons.verified_outlined)],
      explanation: junkKindExplanation(j.kind),
    );

class EmptyFolderDetail extends StatelessWidget {
  const EmptyFolderDetail({super.key, required this.folder, required this.onChanged});

  final FolderEntryDto folder;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return _DetailList(
      builder: (previewHeight) => [
        Container(
          height: previewHeight * 0.6,
          color: ds.surfaceStrong,
          alignment: Alignment.center,
          child: Icon(Icons.folder_off_outlined, size: 64, color: ds.ink),
        ),
        const SizedBox(height: 16),
        _Title(title: folder.name, subtitle: 'Empty folder · nothing inside'),
        const _SectionLabel('Decision'),
        const SizedBox(height: 8),
        DecisionToggle(remove: folder.selected, onChanged: onChanged),
        const _SectionLabel('Details'),
        const SizedBox(height: 6),
        SelectableText(softWrapPath(folder.path), style: Theme.of(context).textTheme.bodyMedium),
        Text('Modified ${formatDateTime(folder.modifiedMs)}', style: Theme.of(context).textTheme.bodySmall),
        if (NativePlatform.canReveal)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => NativePlatform.revealInFileManager(folder.path),
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Show in folder'),
            ),
          ),
      ],
    );
  }
}
