import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/path_display.dart';
import '../../rust/api/types.dart';
import '../../state/ignore_list.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';

/// Marks a duplicate group as "not duplicates": it disappears now and from
/// every later scan of the same content. Offers Undo.
void ignoreGroup(BuildContext context, WidgetRef ref, ResultKind kind, int groupIndex) {
  final results = ref.read(resultsProvider).results;
  if (results == null) return;
  final IgnoredGroupDto? entry;
  try {
    entry = results.ignoreEntry(kind: kind, groupIndex: groupIndex);
  } catch (e) {
    showError(context, e);
    return;
  }
  if (entry == null) return;
  final group = IgnoredGroup.fromDto(entry);
  // The results listen to the ignore list and hide the group.
  ref.read(ignoreListProvider.notifier).add(group);
  showMessage(
    context,
    'Hidden “${group.name}” in every scan',
    action: SnackBarAction(label: 'Undo', onPressed: () => ref.read(ignoreListProvider.notifier).remove(group)),
  );
}

/// Excludes a folder from this and future scans, after confirmation.
Future<void> ignoreFolder(BuildContext context, WidgetRef ref, String folder) async {
  final name = splitPath(folder).lastOrNull ?? folder;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.folder_off_outlined),
      title: Text('Ignore “$name”?'),
      content: Text(
        'Nothing inside this folder will be shown as a duplicate, now or in future scans. '
        'Nothing is deleted.\n\n$folder\n\nYou can undo this in Scan options › Excluded folders.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ignore folder')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  ref.read(settingsProvider.notifier).update((s) {
    if (s.excludePaths.contains(folder)) return s;
    return s.copyWith(excludePaths: [...s.excludePaths, folder]);
  });
  final results = ref.read(resultsProvider).results;
  if (results == null) return;
  try {
    final summary = await results.ignoreFolders(paths: [folder]);
    ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
    if (context.mounted) showMessage(context, 'Ignoring “$name”');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
