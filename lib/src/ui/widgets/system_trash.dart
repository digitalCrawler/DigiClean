import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/history.dart';
import '../theme.dart';
import 'common.dart';

/// What the OS calls its trash.
String get systemTrashName => Platform.isWindows ? 'Recycle Bin' : 'Trash';

/// Contents of the system Recycle Bin / Trash (`null` on Android and iOS).
/// Invalidate after anything is moved to, or emptied from, the trash.
final systemTrashProvider = FutureProvider.autoDispose<TrashInfoDto?>((ref) => systemTrashInfo());

/// Confirms and empties the system trash. Returns true when it was emptied.
Future<bool> emptySystemTrashFlow(BuildContext context, WidgetRef ref) async {
  TrashInfoDto? info;
  try {
    info = await systemTrashInfo();
  } catch (_) {}
  if (!context.mounted) return false;
  final size = info?.bytes;
  final what = info == null || (info.items == 0 && size == null)
      ? 'Everything in the $systemTrashName'
      : '${plural(info.items, 'item')}${size == null ? '' : ' (${formatBytes(size)})'}';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.delete_sweep_outlined),
      title: Text('Empty the $systemTrashName?'),
      content: Text(
        '$what will be deleted permanently, including items other apps put there. This cannot be undone.'
        '${Platform.isMacOS ? '\n\nmacOS may ask you to let DigiClean control Finder.' : ''}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Empty $systemTrashName'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await emptySystemTrash();
    ref.invalidate(systemTrashProvider);
    ref
        .read(historyProvider.notifier)
        .record(
          CleanupEvent(
            kind: CleanupKind.systemTrash,
            atMs: DateTime.now().millisecondsSinceEpoch,
            items: info?.items ?? 0,
            bytesFreed: size ?? 0,
          ),
        );
    if (context.mounted) {
      showMessage(
        context,
        size == null ? '$systemTrashName emptied' : '$systemTrashName emptied · ${formatBytes(size)} freed',
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Card showing what the system trash holds, with an "Empty" action.
/// Renders nothing where there is no system trash.
class SystemTrashCard extends ConsumerWidget {
  const SystemTrashCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(systemTrashProvider);
    final info = async.value;
    if (info == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final empty = info.bytes != null && info.items == 0;
    final summary = info.bytes == null
        ? 'macOS does not let apps measure the Trash.'
        : empty
        ? 'Empty'
        : '${formatBytes(info.bytes!)} in ${plural(info.items, 'item')}';
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('System $systemTrashName', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(summary, style: theme.textTheme.bodyMedium),
        if (!empty)
          Text(
            'Items in the $systemTrashName still use disk space until it is emptied.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
    final actions = [
      IconButton(
        tooltip: 'Refresh',
        onPressed: () => ref.invalidate(systemTrashProvider),
        icon: const Icon(Icons.refresh),
      ),
      if (!empty)
        FilledButton.tonal(onPressed: () => emptySystemTrashFlow(context, ref), child: Text('Empty $systemTrashName')),
    ];
    final icon = Icon(Icons.delete_outline, color: theme.colorScheme.onSurfaceVariant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        // Phones stack the buttons under the text so neither gets squeezed.
        child: context.isCompact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      icon,
                      const SizedBox(width: 14),
                      Expanded(child: details),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                ],
              )
            : Row(
                children: [
                  icon,
                  const SizedBox(width: 14),
                  Expanded(child: details),
                  const SizedBox(width: 12),
                  ...actions,
                ],
              ),
      ),
    );
  }
}
