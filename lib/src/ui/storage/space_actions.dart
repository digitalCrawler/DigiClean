import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/history.dart';
import '../../state/locations.dart';
import '../../state/recovery_controller.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/system_trash.dart';
import 'storage_overview.dart';

/// Runs [work] behind a modal progress dialog.
Future<T> _busy<T>(BuildContext context, String title, Future<T> Function() work) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 20),
            Expanded(child: Text(title)),
          ],
        ),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// The removal the user chose in settings (never a move or a link here).
ActionType _removal(WidgetRef ref) => switch (ref.read(settingsProvider).deleteAction) {
  ActionType.deletePermanently => ActionType.deletePermanently,
  ActionType.recoveryBin => ActionType.recoveryBin,
  _ => ActionType.trash,
};

/// Stops listing paths that left the scanned folders and reloads views.
Future<void> _forget(WidgetRef ref, List<String> paths) async {
  final results = ref.read(resultsProvider).results;
  if (results == null || paths.isEmpty) return;
  final summary = await results.markRemoved(paths: paths);
  ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
}

/// Compresses a folder into a verified .zip, shows what it saves, then lets
/// the user keep both, remove the original, or drop the archive.
Future<void> compressFlow(BuildContext context, WidgetRef ref, String path, int bytes) async {
  final name = p.basename(path);
  var here = true;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        icon: const Icon(Icons.folder_zip_outlined),
        title: Text('Compress “$name”?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Creates $name.zip from ${formatBytes(bytes)} and checks it after writing. '
              'You decide what happens to the original once you see how much it saves.',
            ),
            const SizedBox(height: 8),
            RadioGroup<bool>(
              groupValue: here,
              onChanged: (v) => setState(() => here = v ?? true),
              child: const Column(
                children: [
                  RadioListTile<bool>(value: true, title: Text('Save next to the folder')),
                  RadioListTile<bool>(value: false, title: Text('Choose where to save…')),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Compress')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  var destDir = p.dirname(path);
  if (!here) {
    final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Save $name.zip in…');
    if (picked == null || !context.mounted) return;
    destDir = picked;
  }

  final ArchiveReportDto report;
  try {
    report = await _busy(
      context,
      'Compressing $name…',
      () => createArchive(sources: [path], dest: p.join(destDir, '$name.zip')),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;

  final saved = report.originalBytes - report.archiveBytes;
  final percent = report.originalBytes == 0 ? 0 : saved * 100 ~/ report.originalBytes;
  final removal = _removal(ref);
  final where = switch (removal) {
    ActionType.deletePermanently => 'deleted permanently',
    ActionType.recoveryBin => 'moved to the Recovery Bin',
    _ => 'moved to the $systemTrashName',
  };
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('Archive created and checked'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${p.basename(report.archive)} is ${formatBytes(report.archiveBytes)}; '
              'the folder is ${formatBytes(report.originalBytes)} '
              '(${plural(report.files, 'file')}).',
            ),
            const SizedBox(height: 8),
            Text(
              saved > 0
                  ? 'Saves ${formatBytes(saved)} ($percent%) once the original is removed.'
                  : 'It saves no space.',
              style: theme.textTheme.titleSmall,
            ),
            if (percent < 5) ...[
              const SizedBox(height: 8),
              Text(
                'These files barely compress: photos, videos and archives already are. '
                'Moving them to another drive frees more space.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Removing the original: it is $where.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'drop'), child: const Text('Delete archive')),
          TextButton(onPressed: () => Navigator.pop(context, 'keep'), child: const Text('Keep both')),
          FilledButton(onPressed: () => Navigator.pop(context, 'remove'), child: const Text('Remove original')),
        ],
      );
    },
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'drop':
      try {
        File(report.archive).deleteSync();
        showMessage(context, 'Archive deleted');
      } catch (e) {
        showError(context, e);
      }
    case 'remove':
      await _removeOriginal(context, ref, path, removal);
    default:
      showMessage(context, 'Saved ${p.basename(report.archive)}');
  }
}

Future<void> _removeOriginal(BuildContext context, WidgetRef ref, String path, ActionType removal) async {
  final PathsReportDto report;
  try {
    report = await removePaths(paths: [path], action: removal, recoveryRoots: ref.read(appPathsProvider).recoveryRoots);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (report.issues.isNotEmpty && context.mounted) {
    showError(context, report.issues.first.message);
  }
  if (report.done.isEmpty) return;
  final permanent = removal == ActionType.deletePermanently;
  ref
      .read(historyProvider.notifier)
      .record(
        CleanupEvent(
          kind: CleanupKind.cleanup,
          atMs: DateTime.now().millisecondsSinceEpoch,
          items: report.done.length,
          action: removal,
          bytesFreed: permanent ? report.bytes : 0,
          bytesInBin: permanent ? 0 : report.bytes,
          systemTrash: report.usedSystemTrash,
        ),
      );
  await _forget(ref, report.done);
  if (report.batchId != null) ref.read(recoveryProvider.notifier).refresh();
  if (report.usedSystemTrash) ref.invalidate(systemTrashProvider);
  if (!context.mounted) return;
  showMessage(
    context,
    permanent
        ? 'Original deleted · ${formatBytes(report.bytes)} freed'
        : 'Original moved to the ${report.usedSystemTrash ? systemTrashName : 'Recovery Bin'}. '
              'The space is freed when it is emptied.',
    action: report.batchId == null
        ? null
        : SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await ref.read(recoveryProvider.notifier).restoreBatch(report.batchId!);
              final results = ref.read(resultsProvider).results;
              if (results != null) {
                final summary = await results.markRestored(paths: report.done);
                ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
              }
            },
          ),
  );
}

/// The drive holding [path], from the known drives (longest match).
DriveInfo? _driveOf(List<DriveInfo> drives, String path) {
  final lower = Platform.isWindows ? path.toLowerCase() : path;
  DriveInfo? best;
  for (final d in drives) {
    final root = Platform.isWindows ? d.path.toLowerCase() : d.path;
    if (lower.startsWith(root) && (best == null || root.length > best.path.length)) best = d;
  }
  return best;
}

/// Moves a folder to another drive (copied and checked, then removed here).
Future<void> moveToDriveFlow(BuildContext context, WidgetRef ref, String path, int bytes) async {
  final name = p.basename(path);
  final dest = await FilePicker.getDirectoryPath(dialogTitle: 'Move “$name” to…');
  if (dest == null || !context.mounted) return;
  final drives = await ref.read(drivesProvider.future);
  final from = _driveOf(drives, path);
  final to = _driveOf(drives, dest);
  if (!context.mounted) return;
  if (from != null && to != null && from.path == to.path) {
    showMessage(context, 'That folder is on the same drive; moving there would not free any space.');
    return;
  }
  if (to != null && to.free < bytes) {
    showMessage(context, '${to.label} has only ${formatBytes(to.free)} free; “$name” needs ${formatBytes(bytes)}.');
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.drive_file_move_outline),
      title: Text('Move “$name”?'),
      content: Text(
        '${formatBytes(bytes)} will be moved to $dest. Files are copied and checked before they are '
        'removed here${from == null ? '' : ', freeing that space on ${from.label}'}.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final report = await _busy(context, 'Moving $name…', () => movePaths(paths: [path], destDir: dest));
  if (report.done.isNotEmpty) {
    ref
        .read(historyProvider.notifier)
        .record(
          CleanupEvent(
            kind: CleanupKind.cleanup,
            atMs: DateTime.now().millisecondsSinceEpoch,
            items: report.done.length,
            action: ActionType.moveTo,
            bytesMoved: report.bytes,
          ),
        );
    await _forget(ref, report.done);
  }
  if (!context.mounted) return;
  if (report.issues.isNotEmpty) {
    showIssues(context, report.issues);
  } else {
    showMessage(
      context,
      'Moved “$name” · ${formatBytes(report.bytes)} freed${from == null ? '' : ' on ${from.label}'}',
    );
  }
}

void showIssues(BuildContext context, List<IssueDto> issues) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Not everything could be done'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final i in issues)
              ListTile(contentPadding: EdgeInsets.zero, title: Text(i.path), subtitle: Text(i.message)),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}
