import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/native.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/navigation.dart';
import '../../state/results_controller.dart';
import '../widgets/common.dart';
import '../../core/photo_library.dart';
import '../photos/photo_library_page.dart';
import 'recommendations_page.dart';
import 'space_map_page.dart';

/// A drive or storage volume with its capacity.
class DriveInfo {
  const DriveInfo({
    required this.path,
    required this.label,
    required this.kind,
    required this.total,
    required this.free,
  });

  final String path;
  final String label;
  final VolumeKind kind;
  final int total;
  final int free;

  int get used => total - free;
  double get fraction => total == 0 ? 0 : used / total;
}

/// Drives and their capacity. Reloads after cleanups (results change).
final drivesProvider = FutureProvider.autoDispose<List<DriveInfo>>((ref) async {
  ref.watch(resultsProvider.select((r) => r.generation));
  if (Platform.isAndroid) {
    final out = <DriveInfo>[];
    for (final v in await NativePlatform.storageVolumes()) {
      final usage = await diskUsage(path: v.path);
      if (usage == null) continue;
      out.add(
        DriveInfo(
          path: v.path,
          label: v.label,
          kind: v.isRemovable ? VolumeKind.removable : VolumeKind.fixed,
          total: usage.total,
          free: usage.free,
        ),
      );
    }
    return out;
  }
  if (Platform.isIOS) {
    final docs = await getApplicationDocumentsDirectory();
    final usage = await diskUsage(path: docs.path);
    return [
      if (usage != null)
        DriveInfo(path: docs.path, label: 'This iPhone', kind: VolumeKind.fixed, total: usage.total, free: usage.free),
    ];
  }
  return [
    for (final v in await storageVolumes())
      DriveInfo(path: v.path, label: v.label, kind: v.kind, total: v.total, free: v.free),
  ];
});

/// Space used per category in the scanned folders (after a scan).
final categoryUsageProvider = FutureProvider.autoDispose<List<CategoryUsageDto>>((ref) async {
  final results = ref.watch(resultsProvider.select((r) => r.results));
  ref.watch(resultsProvider.select((r) => r.generation));
  return results == null ? const [] : results.categoryUsage();
});

/// Files not changed for a year (the old-files list's default).
final oldFilesCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final results = ref.watch(resultsProvider.select((r) => r.results));
  ref.watch(resultsProvider.select((r) => r.generation));
  if (results == null) return 0;
  final page = await results.oldFiles(
    query: GroupQuery(
      offset: 0,
      limit: 0,
      sort: SortBy.size,
      descending: true,
      modifiedBeforeMs: DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch,
    ),
  );
  return page.total;
});

class DrivesCard extends ConsumerWidget {
  const DrivesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drives = ref.watch(drivesProvider).value ?? const [];
    if (drives.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              drives.length == 1 ? 'This device' : 'Drives',
              padding: EdgeInsets.zero,
              trailing: IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: () => ref.invalidate(drivesProvider),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ),
            for (final d in drives) _DriveRow(drive: d),
          ],
        ),
      ),
    );
  }
}

class _DriveRow extends StatelessWidget {
  const _DriveRow({required this.drive});

  final DriveInfo drive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final low = drive.free < drive.total * 0.1;
    final icon = switch (drive.kind) {
      VolumeKind.fixed => Icons.storage_outlined,
      VolumeKind.removable => Icons.usb,
      VolumeKind.network => Icons.lan_outlined,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        drive.label,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${formatBytes(drive.free)} free of ${formatBytes(drive.total)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: low ? scheme.error : scheme.onSurfaceVariant,
                        fontWeight: low ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: drive.fraction.clamp(0, 1),
                    minHeight: 8,
                    color: low ? scheme.error : scheme.primary,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the last scan found, each line opening its list.
class FindingsCard extends ConsumerWidget {
  const FindingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(resultsProvider);
    final stats = state.stats;
    if (stats == null) return const SizedBox.shrink();
    final s = state.summary;
    final theme = Theme.of(context);
    final rows = [
      (
        icon: Icons.file_copy_outlined,
        label: 'Duplicate files',
        value: formatBytes(s?.fileWasted ?? stats.wastedBytes),
        detail: plural(s?.activeFileGroups ?? stats.duplicateGroups, 'group'),
        kind: ResultKind.files,
      ),
      (
        icon: Icons.folder_copy_outlined,
        label: 'Duplicate folders',
        value: formatBytes(s?.folderWasted ?? stats.folderWastedBytes),
        detail: plural(s?.activeFolderGroups ?? stats.folderGroups, 'group'),
        kind: ResultKind.folders,
      ),
      (
        icon: Icons.cleaning_services_outlined,
        label: 'Junk',
        value: formatBytes(s?.remainingJunkBytes ?? stats.junkBytes),
        detail: plural(s?.remainingJunk ?? stats.junkItems, 'item'),
        kind: ResultKind.junk,
      ),
      (
        icon: Icons.photo_size_select_large,
        label: 'Large files',
        value: formatCount(s?.remainingLargeFiles ?? stats.largeFiles),
        detail: 'biggest first',
        kind: ResultKind.largeFiles,
      ),
      (
        icon: Icons.history_toggle_off,
        label: 'Old files',
        value: formatCount(ref.watch(oldFilesCountProvider).value ?? 0),
        detail: 'not changed for a year or more',
        kind: ResultKind.oldFiles,
      ),
      (
        icon: Icons.folder_off_outlined,
        label: 'Empty folders',
        value: formatCount(s?.remainingEmptyFolders ?? stats.emptyFolders),
        detail: '',
        kind: ResultKind.emptyFolders,
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Last scan',
              padding: EdgeInsets.zero,
              trailing: state.finishedAt == null
                  ? null
                  : Text(formatRelative(state.finishedAt!.millisecondsSinceEpoch), style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 4),
            for (final r in rows)
              if (r.value != '0' && r.value != '0 B')
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(r.icon),
                  title: Text(r.label),
                  subtitle: r.detail.isEmpty ? null : Text(r.detail),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        r.value,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => openResults(ref, r.kind),
                ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecommendationsPage())),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('Recommended cleanup'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openSpaceMap(context),
                  icon: const Icon(Icons.dashboard_outlined),
                  label: const Text('Space map'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What takes up space in the scanned folders, by kind of file.
class SpaceUsageCard extends ConsumerWidget {
  const SpaceUsageCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(categoryUsageProvider).value ?? const [];
    final total = usage.fold<int>(0, (s, u) => s + u.bytes);
    if (total == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'What uses space in the scanned folders',
              padding: EdgeInsets.zero,
              trailing: Text(formatBytes(total), style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: [
                    for (final u in usage)
                      if (u.bytes * 1000 ~/ total > 0)
                        Expanded(
                          flex: u.bytes * 1000 ~/ total,
                          child: Tooltip(
                            message: '${categoryLabel(u.category)}: ${formatBytes(u.bytes)}',
                            child: ColoredBox(color: categoryColor(u.category, theme.brightness)),
                          ),
                        ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final u in usage)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: categoryColor(u.category, theme.brightness),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('${categoryLabel(u.category)} ', style: theme.textTheme.bodySmall),
                      Text(
                        formatBytes(u.bytes),
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry to the device photo library (iOS), whose photos are not files.
class PhotoLibraryCard extends ConsumerWidget {
  const PhotoLibraryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(photoLibrarySourceProvider) == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Photos library'),
          subtitle: const Text('Similar shots, blurry photos and screenshots'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhotoLibraryPage())),
        ),
      ),
    );
  }
}
