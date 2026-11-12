import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/native.dart';
import '../../rust/api/maintenance.dart';
import '../../state/history.dart';
import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../../state/recovery_controller.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/system_trash.dart';

String _what(ResultKind kind, SelectionSummaryDto s) => switch (kind) {
  ResultKind.files => plural(s.files.toInt(), 'file'),
  ResultKind.folders => plural(s.folders.toInt(), 'folder'),
  ResultKind.emptyFolders => plural(s.emptyFolders.toInt(), 'empty folder'),
  ResultKind.largeFiles => plural(s.largeFiles.toInt(), 'file'),
  ResultKind.oldFiles => plural(s.oldFiles.toInt(), 'file'),
  ResultKind.similarPhotos => plural(s.similar.toInt(), 'photo'),
  ResultKind.photoIssues => plural(s.photoIssues.toInt(), 'photo'),
  ResultKind.similarMedia => plural(s.media.toInt(), 'file'),
  ResultKind.junk => plural(s.junk.toInt(), 'junk item'),
};

int _bytes(ResultKind kind, SelectionSummaryDto s) => switch (kind) {
  ResultKind.files => s.fileBytes.toInt(),
  ResultKind.folders => s.folderBytes.toInt(),
  ResultKind.emptyFolders => 0,
  ResultKind.largeFiles => s.largeFileBytes.toInt(),
  ResultKind.oldFiles => s.oldFileBytes.toInt(),
  ResultKind.similarPhotos => s.similarBytes.toInt(),
  ResultKind.photoIssues => s.photoIssueBytes.toInt(),
  ResultKind.similarMedia => s.mediaBytes.toInt(),
  ResultKind.junk => s.junkBytes.toInt(),
};

int selectedCount(ResultKind kind, SelectionSummaryDto s) => switch (kind) {
  ResultKind.files => s.files.toInt(),
  ResultKind.folders => s.folders.toInt(),
  ResultKind.emptyFolders => s.emptyFolders.toInt(),
  ResultKind.largeFiles => s.largeFiles.toInt(),
  ResultKind.oldFiles => s.oldFiles.toInt(),
  ResultKind.similarPhotos => s.similar.toInt(),
  ResultKind.photoIssues => s.photoIssues.toInt(),
  ResultKind.similarMedia => s.media.toInt(),
  ResultKind.junk => s.junk.toInt(),
};

/// Runs a delete / move / link action on the current selection: confirm,
/// execute with progress, then report with undo where possible.
Future<void> runAction(
  BuildContext context,
  WidgetRef ref, {
  required ResultKind kind,
  required ActionType action,
}) async {
  final results = ref.read(resultsProvider).results;
  if (results == null) return;
  final SelectionSummaryDto summary;
  try {
    summary = results.selectionSummary();
  } catch (e) {
    showError(context, e);
    return;
  }
  if (selectedCount(kind, summary) == 0) return;

  String? destination;
  var keepStructure = true;
  if (action == ActionType.moveTo) {
    destination = await FilePicker.getDirectoryPath(dialogTitle: 'Move selected items to…');
    if (destination == null || !context.mounted) return;
  }

  final settings = ref.read(settingsProvider);
  final caps = platformCapabilities();
  final confirmed = await showDialog<_Confirmation>(
    context: context,
    builder: (_) => _ConfirmDialog(
      kind: kind,
      action: action,
      summary: summary,
      systemTrash: caps.systemTrash,
      destination: destination,
      verifyDefault: settings.verifyBeforeDelete,
    ),
  );
  if (confirmed == null || !context.mounted) return;
  keepStructure = confirmed.keepStructure;

  final request = ActionRequestDto(
    action: action,
    target: kind,
    destination: destination,
    keepStructure: keepStructure,
    verifyContent: confirmed.verify,
  );
  final report = await performAction(context, ref, request);
  if (report == null || !context.mounted) return;
  _showReport(context, ref, report, action, kind);
}

/// Executes an already confirmed action with a progress dialog, records it
/// in the history and refreshes everything it affects. Returns `null` when
/// there are no results.
Future<ActionReportDto?> performAction(BuildContext context, WidgetRef ref, ActionRequestDto request) async {
  final results = ref.read(resultsProvider).results;
  if (results == null) return null;
  final roots = ref.read(appPathsProvider).recoveryRoots;
  final report = await showDialog<ActionReportDto>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(results: results, request: request, recoveryRoots: roots),
  );
  if (report == null) return null;
  ref.read(historyProvider.notifier).record(CleanupEvent.fromReport(report, request.action));
  ref.read(resultsProvider.notifier).refresh();
  if (report.batchId != null) ref.read(recoveryProvider.notifier).refresh();
  if (report.usedSystemTrash) ref.invalidate(systemTrashProvider);
  if (request.action != ActionType.replaceWithHardlink && request.action != ActionType.replaceWithClone) {
    NativePlatform.notifyMediaRemoved(report.affectedPaths);
  }
  return report;
}

class _Confirmation {
  const _Confirmation(this.verify, this.keepStructure);
  final bool verify;
  final bool keepStructure;
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.kind,
    required this.action,
    required this.summary,
    required this.systemTrash,
    required this.destination,
    required this.verifyDefault,
  });

  final ResultKind kind;
  final ActionType action;
  final SelectionSummaryDto summary;
  final bool systemTrash;
  final String? destination;
  final bool verifyDefault;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  late bool _verify = widget.verifyDefault;
  bool _keepStructure = true;
  bool _understood = false;

  bool get _permanent => widget.action == ActionType.deletePermanently;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = _what(widget.kind, widget.summary);
    final bytes = _bytes(widget.kind, widget.summary);
    final size = bytes > 0 ? ' (${formatBytes(bytes)})' : '';
    final trashName = Platform.isWindows ? 'Recycle Bin' : 'Trash';

    final (title, body, icon) = switch (widget.action) {
      ActionType.trash when widget.systemTrash => (
        'Move to $trashName?',
        '$what$size will be moved to the $trashName. You can restore them from there.',
        Icons.delete_outline,
      ),
      ActionType.trash || ActionType.recoveryBin => (
        'Move to Recovery Bin?',
        '$what$size will be moved to DigiClean’s Recovery Bin. You can restore them at any time until the bin is emptied.',
        Icons.restore_from_trash_outlined,
      ),
      ActionType.deletePermanently => (
        'Delete permanently?',
        '$what$size will be deleted immediately. This cannot be undone.',
        Icons.delete_forever_outlined,
      ),
      ActionType.moveTo => (
        'Move $what?',
        '$what$size will be moved to ${widget.destination}.',
        Icons.drive_file_move_outline,
      ),
      ActionType.replaceWithHardlink => (
        'Replace with hard links?',
        'Each selected duplicate will be replaced by a hard link to the copy you keep. '
            'Paths keep working, but the data is stored only once. Changing one linked file changes all of them.',
        Icons.link,
      ),
      ActionType.replaceWithClone => (
        'Replace with clones?',
        'Each selected duplicate will be replaced by a copy-on-write clone of the copy you keep. '
            'Both stay separate files, but share their data until one of them is changed.',
        Icons.copy_all,
      ),
    };

    return AlertDialog(
      icon: Icon(icon, color: _permanent ? theme.colorScheme.error : null),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 12),
            if (widget.kind == ResultKind.largeFiles ||
                widget.kind == ResultKind.oldFiles ||
                widget.kind == ResultKind.photoIssues)
              Text(
                'These files are not duplicates: this removes the only copy. Items that changed since the scan are skipped.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error, fontWeight: FontWeight.w600),
              )
            else if (widget.kind == ResultKind.similarMedia)
              Text(
                'These sound the same but are different files: play them first if unsure. '
                'At least one copy of each set stays, and files that changed since the scan are skipped.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else if (widget.kind == ResultKind.similarPhotos)
              Text(
                'Similar is not identical: look at the photos first. At least one photo of each set stays, '
                'and photos that changed since the scan are skipped.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else if (widget.kind == ResultKind.junk)
              Text(
                'Only the ticked items are removed. Items that changed since the scan are skipped.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              Text(
                'At least one copy of everything stays in place. Items that changed since the scan are skipped.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(height: 8),
            if (widget.kind == ResultKind.files)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _verify,
                onChanged: (v) => setState(() => _verify = v ?? true),
                title: const Text('Re-check contents first'),
                subtitle: const Text('Hashes each file again before removing it'),
              ),
            if (widget.action == ActionType.moveTo)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _keepStructure,
                onChanged: (v) => setState(() => _keepStructure = v ?? true),
                title: const Text('Keep folder structure'),
                subtitle: const Text('Avoids name clashes between copies'),
              ),
            if (_permanent)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _understood,
                onChanged: (v) => setState(() => _understood = v ?? false),
                title: const Text('I understand this cannot be undone'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: _permanent
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          onPressed: _permanent && !_understood
              ? null
              : () => Navigator.pop(context, _Confirmation(_verify, _keepStructure)),
          child: Text(switch (widget.action) {
            ActionType.deletePermanently => 'Delete',
            ActionType.moveTo => 'Move',
            ActionType.replaceWithHardlink || ActionType.replaceWithClone => 'Replace',
            _ => 'Move to bin',
          }),
        ),
      ],
    );
  }
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.results, required this.request, required this.recoveryRoots});

  final ScanResults results;
  final ActionRequestDto request;
  final List<String> recoveryRoots;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  Timer? _timer;
  ActionProgressDto? _progress;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted) setState(() => _progress = widget.results.actionProgress());
    });
    widget.results
        .executeAction(request: widget.request, recoveryRoots: widget.recoveryRoots)
        .then((report) {
          if (mounted) Navigator.pop(context, report);
        })
        .catchError((Object e) {
          if (!mounted) return;
          Navigator.pop(context);
          showError(context, e);
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final total = p?.total.toInt() ?? 0;
    final done = p?.done.toInt() ?? 0;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Working…'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: total > 0 ? done / total : null),
            const SizedBox(height: 12),
            Text(total > 0 ? '${formatCount(done)} of ${formatCount(total)}' : 'Preparing…'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.results.cancelAction();
                  },
            child: Text(_cancelling ? 'Stopping…' : 'Stop'),
          ),
        ],
      ),
    );
  }
}

void _showReport(BuildContext context, WidgetRef ref, ActionReportDto report, ActionType action, ResultKind kind) {
  final done = report.succeeded.toInt();
  final noun = switch (kind) {
    ResultKind.folders => 'folder',
    ResultKind.emptyFolders => 'empty folder',
    ResultKind.junk => 'item',
    _ => 'file',
  };
  final what = plural(done, noun);
  String withSize(int bytes) => bytes > 0 ? '$what (${formatBytes(bytes)})' : what;
  final inBin = report.bytesInBin.toInt();
  final message = StringBuffer(switch (action) {
    ActionType.deletePermanently =>
      'Deleted $what${report.bytesFreed > 0 ? ' · ${formatBytes(report.bytesFreed.toInt())} freed' : ''}',
    ActionType.replaceWithHardlink => 'Linked $what · ${formatBytes(report.bytesFreed.toInt())} freed',
    ActionType.replaceWithClone => 'Cloned $what · ${formatBytes(report.bytesFreed.toInt())} freed',
    ActionType.moveTo => 'Moved ${withSize(report.bytesMoved.toInt())} to the chosen folder',
    _ when report.usedSystemTrash =>
      'Moved ${withSize(inBin)} to the $systemTrashName. The space is freed when the $systemTrashName is emptied.',
    _ => 'Moved ${withSize(inBin)} to the Recovery Bin. The space is freed when the bin is emptied.',
  });
  final problems = report.failed.toInt() + report.skipped.toInt();
  if (problems > 0) message.write(' ${formatCount(problems)} not processed.');

  SnackBarAction? snackAction;
  if (report.batchId != null && done > 0) {
    snackAction = SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        final restore = await ref.read(recoveryProvider.notifier).restoreBatch(report.batchId!);
        final results = ref.read(resultsProvider).results;
        if (results != null) {
          final summary = await results.markRestored(paths: report.affectedPaths);
          ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
        }
        if (context.mounted) {
          showMessage(context, 'Restored ${plural(restore.restored, 'item')}');
        }
      },
    );
  } else if (report.usedSystemTrash && done > 0) {
    snackAction = SnackBarAction(label: 'Empty now', onPressed: () => emptySystemTrashFlow(context, ref));
  } else if (problems > 0) {
    snackAction = SnackBarAction(
      label: 'Details',
      onPressed: () =>
          showIssuesDialog(context, 'Not processed', report.issues.map((i) => (i.path, i.message)).toList()),
    );
  }
  showMessage(context, message.toString(), action: snackAction);
}

Future<void> showIssuesDialog(BuildContext context, String title, List<(String, String)> issues) {
  return showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        height: 420,
        child: issues.isEmpty
            ? const Center(child: Text('No problems'))
            : ListView.separated(
                itemCount: issues.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  title: Text(issues[i].$1, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(issues[i].$2),
                ),
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}
