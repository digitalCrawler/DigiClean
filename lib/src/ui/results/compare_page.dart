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

/// Every copy in a file group. The copies are byte-identical, so the content
/// is previewed once; what differs — location and dates — is listed below.
class FileCompareView extends ConsumerStatefulWidget {
  const FileCompareView({super.key, required this.groupIndex, this.embedded = false});

  final int groupIndex;

  /// Shown inside the results page's detail pane instead of its own route.
  final bool embedded;

  @override
  ConsumerState<FileCompareView> createState() => _FileCompareViewState();
}

class _FileCompareViewState extends ConsumerState<FileCompareView> {
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

  void _run(SelectionSummaryDto Function() call) {
    try {
      ref.read(resultsProvider.notifier).selectionChanged(call());
    } catch (e) {
      showError(context, e);
    }
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (results == null || group == null || group.files.length < 2) {
      const empty = EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Nothing to compare',
        message: 'This group no longer has duplicates.',
      );
      return widget.embedded ? empty : Scaffold(appBar: AppBar(), body: empty);
    }

    final g = group;
    final files = g.files;
    final locations = GroupLocations.of([for (final f in files) f.parent]);
    final anySelected = files.any((f) => f.selected);
    final kind = previewKindFor(files.first.path);
    final previewable = kind == PreviewKind.image || kind == PreviewKind.text;

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!previewable) ...[
              FileThumbnail(path: files.first.path, size: 44, color: categoryColor(g.category, theme.brightness)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(files.first.name, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${files.length} identical copies · ${formatBytes(g.size)} each · ${categoryLabel(g.category)}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (previewable) ...[
          FilePreview(path: files.first.path, height: 220),
          const SizedBox(height: 4),
          Text(
            'Every copy has exactly this content.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(child: Text('Locations', style: theme.textTheme.titleMedium)),
            TextButton.icon(
              onPressed: _verifying ? null : () => _verify(g, algo),
              icon: _verifying
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.verified_outlined, size: 18),
              label: const Text('Verify contents'),
            ),
          ],
        ),
        if (locations.prefix.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'All inside ${softWrapPath(locations.prefixPath)}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < files.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _LocationTile(
                  location: locations.segmentsOf(i),
                  fullPath: files[i].path,
                  dates: [
                    'Modified ${formatDateTime(files[i].modifiedMs)}',
                    if (files[i].createdMs != null) 'Created ${formatDateTime(files[i].createdMs!)}',
                  ],
                  selected: files[i].selected,
                  showStatus: anySelected,
                  verification: _verified.containsKey(files[i].id) ? _verified[files[i].id] == g.hash : null,
                  checking: _verifying && !_verified.containsKey(files[i].id),
                  onKeep: () => _run(
                    () => results.keepOnly(kind: ResultKind.files, groupIndex: widget.groupIndex, keepId: files[i].id),
                  ),
                  onToggle: () =>
                      _run(() => results.setFileSelected(fileId: files[i].id, selected: !files[i].selected)),
                  onOpen: () => openFile(context, files[i].path),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.zero,
          onTap: () {
            Clipboard.setData(ClipboardData(text: g.hash));
            showMessage(context, 'Hash copied');
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${algo == HashAlgo.blake3 ? 'BLAKE3' : 'SHA-256'}  ${g.hash}',
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('Compare copies')),
      body: content,
    );
  }
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    required this.location,
    required this.fullPath,
    required this.dates,
    required this.selected,
    required this.showStatus,
    required this.onKeep,
    required this.onToggle,
    this.verification,
    this.checking = false,
    this.onOpen,
  });

  final List<String> location;
  final String fullPath;
  final List<String> dates;
  final bool selected;
  final bool showStatus;

  /// `true` identical, `false` changed/unreadable, `null` not checked.
  final bool? verification;
  final bool checking;
  final VoidCallback onKeep;
  final VoidCallback onToggle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final compactButton = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      visualDensity: VisualDensity.compact,
    );
    return Material(
      color: selected ? scheme.errorContainer.withValues(alpha: 0.35) : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
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
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (checking)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else if (verification != null)
                  TagChip(
                    verification! ? 'Identical' : 'Changed',
                    color: verification! ? scheme.primary : scheme.error,
                    icon: verification! ? Icons.verified : Icons.error_outline,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(softWrapPath(fullPath), style: small),
            const SizedBox(height: 2),
            Text(dates.join(' · '), style: small),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  style: compactButton,
                  onPressed: onKeep,
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  label: const Text('Keep only this'),
                ),
                OutlinedButton(
                  style: compactButton,
                  onPressed: onToggle,
                  child: Text(selected ? 'Don’t remove' : 'Remove this'),
                ),
                if (onOpen != null)
                  IconButton(tooltip: 'Open', onPressed: onOpen, icon: const Icon(Icons.open_in_new, size: 20)),
                if (NativePlatform.canReveal)
                  IconButton(
                    tooltip: 'Show in folder',
                    onPressed: () => NativePlatform.revealInFileManager(fullPath),
                    icon: const Icon(Icons.folder_open_outlined, size: 20),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Every copy of a duplicate folder, plus its contents (identical in all).
class FolderCompareView extends ConsumerWidget {
  const FolderCompareView({super.key, required this.groupIndex, this.embedded = false});

  final int groupIndex;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
    final results = ref.watch(resultsProvider).results;
    FolderGroupDto? group;
    try {
      group = results?.folderGroup(index: groupIndex);
    } catch (_) {}
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (results == null || group == null || group.folders.length < 2) {
      const empty = EmptyState(icon: Icons.check_circle_outline, title: 'Nothing to compare');
      return embedded ? empty : Scaffold(appBar: AppBar(), body: empty);
    }
    final g = group;
    final folders = g.folders;
    final locations = GroupLocations.of([for (final f in folders) f.path]);
    final anySelected = folders.any((f) => f.selected);

    void run(SelectionSummaryDto Function() call) {
      try {
        ref.read(resultsProvider.notifier).selectionChanged(call());
      } catch (e) {
        showError(context, e);
      }
    }

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('${folders.length} identical folders', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Same structure and contents · ${plural(g.fileCount.toInt(), 'file')}'
          '${g.dirCount > 0 ? ' in ${plural(g.dirCount.toInt(), 'sub-folder')}' : ''} · '
          '${formatBytes(g.totalBytes.toInt())} each',
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Text('Locations', style: theme.textTheme.titleMedium),
        if (locations.prefix.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
              'All inside ${softWrapPath(locations.prefixPath)}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < folders.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _LocationTile(
                  location: locations.segmentsOf(i),
                  fullPath: folders[i].path,
                  dates: ['Modified ${formatDateTime(folders[i].modifiedMs)}'],
                  selected: folders[i].selected,
                  showStatus: anySelected,
                  onKeep: () => run(
                    () => results.keepOnly(kind: ResultKind.folders, groupIndex: groupIndex, keepId: folders[i].id),
                  ),
                  onToggle: () =>
                      run(() => results.setFolderSelected(folderId: folders[i].id, selected: !folders[i].selected)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('Contents (the same in every copy)', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: _FolderContents(key: ValueKey(folders.first.id), results: results, folderId: folders.first.id),
        ),
      ],
    );
    if (embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('Compare folders')),
      body: content,
    );
  }
}

class _FolderContents extends StatefulWidget {
  const _FolderContents({super.key, required this.results, required this.folderId});

  final ScanResults results;
  final int folderId;

  @override
  State<_FolderContents> createState() => _FolderContentsState();
}

class _FolderContentsState extends State<_FolderContents> {
  late final Future<FolderChildren> _children = widget.results.folderChildren(folderId: widget.folderId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<FolderChildren>(
      future: _children,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
        }
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
