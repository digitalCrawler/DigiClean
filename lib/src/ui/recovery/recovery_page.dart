import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/recovery_controller.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import '../widgets/system_trash.dart';

/// Items DigiClean moved to its own recovery bin, grouped by operation.
class RecoveryPage extends ConsumerStatefulWidget {
  const RecoveryPage({super.key});

  @override
  ConsumerState<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends ConsumerState<RecoveryPage> {
  final Set<String> _selected = {};
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(List<RecoveryItemDto> items) => _run(() async {
    final report = await ref.read(recoveryProvider.notifier).restore(items.map((i) => i.id).toList());
    // Bring restored items back into the current results, if any.
    final results = ref.read(resultsProvider).results;
    if (results != null) {
      final summary = await results.markRestored(paths: items.map((i) => i.originalPath).toList());
      ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
    }
    _selected.removeAll(items.map((i) => i.id));
    if (!mounted) return;
    var message = 'Restored ${plural(report.restored, 'item')}';
    if (report.failed > 0) message += ' · ${report.failed} failed: ${report.errors.first.message}';
    showMessage(context, message);
  });

  Future<void> _purge(List<RecoveryItemDto> items, {bool all = false}) async {
    final size = items.fold<int>(0, (s, i) => s + i.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: Text(all ? 'Empty the Recovery Bin?' : 'Delete permanently?'),
        content: Text('${plural(items.length, 'item')} (${formatBytes(size)}) will be deleted for good.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final notifier = ref.read(recoveryProvider.notifier);
      final freed = all ? await notifier.purgeAll() : await notifier.purge(items.map((i) => i.id).toList());
      _selected.removeAll(items.map((i) => i.id));
      if (mounted) showMessage(context, '${formatBytes(freed)} freed');
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recoveryProvider);
    final retention = ref.watch(settingsProvider.select((s) => s.recoveryRetentionDays));
    final systemTrash = platformCapabilities().systemTrash;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recovery Bin'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : () => ref.read(recoveryProvider.notifier).refresh(),
          ),
          if ((async.value ?? const []).isNotEmpty)
            TextButton(onPressed: _busy ? null : () => _purge(async.value!, all: true), child: const Text('Empty')),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(12, 8, 12, 4), child: SystemTrashCard()),
          Expanded(child: _bin(async, retention, systemTrash, theme)),
        ],
      ),
    );
  }

  Widget _bin(AsyncValue<List<RecoveryItemDto>> async, int retention, bool systemTrash, ThemeData theme) {
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(icon: Icons.error_outline, title: 'Could not read the Recovery Bin', message: errorMessage(e)),
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.restore_from_trash_outlined,
            title: 'Recovery Bin is empty',
            message: systemTrash
                ? 'Items moved to the ${Platform.isWindows ? 'Recycle Bin' : 'Trash'} can be restored from there. '
                      'Items you send to DigiClean’s Recovery Bin appear here.'
                : 'Removed duplicates are kept here for $retention days so you can restore them.',
          );
        }
        final total = items.fold<int>(0, (s, i) => s + i.size);
        final batches = groupBy(items, (RecoveryItemDto i) => i.batchId).entries.toList();
        final selectedItems = items.where((i) => _selected.contains(i.id)).toList();
        return Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${plural(items.length, 'item')} · ${formatBytes(total)}'
                      '${retention > 0 ? ' · kept for $retention days' : ''}'
                      ' · uses disk space until deleted or expired',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  if (selectedItems.isNotEmpty) ...[
                    TextButton(onPressed: _busy ? null : () => _purge(selectedItems), child: const Text('Delete')),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _busy ? null : () => _restore(selectedItems),
                      child: Text('Restore ${selectedItems.length}'),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: batches.length,
                itemBuilder: (context, i) {
                  final batch = batches[i].value;
                  final when = batch.map((b) => b.deletedAtMs).reduce((a, b) => a > b ? a : b);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: Column(
                        children: [
                          ListTile(
                            title: Text(formatDateTime(when)),
                            subtitle: Text(
                              '${plural(batch.length, 'item')} · ${formatBytes(batch.fold(0, (s, x) => s + x.size))}',
                            ),
                            trailing: TextButton.icon(
                              onPressed: _busy ? null : () => _restore(batch),
                              icon: const Icon(Icons.restore),
                              label: const Text('Restore all'),
                            ),
                          ),
                          const Divider(height: 1),
                          for (final item in batch)
                            CheckboxListTile(
                              value: _selected.contains(item.id),
                              onChanged: (v) =>
                                  setState(() => v == true ? _selected.add(item.id) : _selected.remove(item.id)),
                              secondary: item.isDir
                                  ? const Icon(Icons.folder_outlined)
                                  : FileThumbnail(path: item.originalPath, size: 36),
                              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${formatBytes(item.size)} · ${File(item.originalPath).parent.path}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
