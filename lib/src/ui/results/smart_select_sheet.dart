import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../rust/api/types.dart';

class SmartSelection {
  const SmartSelection({
    required this.keep,
    required this.preferKeepIn,
    required this.onlySelectIn,
    required this.onlyFiltered,
  });

  final KeepRule keep;
  final List<String> preferKeepIn;
  final List<String> onlySelectIn;

  /// Apply only to groups matching the current category/search filter.
  final bool onlyFiltered;
}

/// Bottom sheet for rule-based selection: which copy to keep in every group.
Future<SmartSelection?> showSmartSelectSheet(
  BuildContext context, {
  required bool folders,
  required bool hasFilter,
  required List<String> roots,
}) {
  return showModalBottomSheet<SmartSelection>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _SmartSelectSheet(folders: folders, hasFilter: hasFilter, roots: roots),
  );
}

class _SmartSelectSheet extends StatefulWidget {
  const _SmartSelectSheet({required this.folders, required this.hasFilter, required this.roots});

  final bool folders;
  final bool hasFilter;
  final List<String> roots;

  @override
  State<_SmartSelectSheet> createState() => _SmartSelectSheetState();
}

class _SmartSelectSheetState extends State<_SmartSelectSheet> {
  KeepRule _keep = KeepRule.newest;
  final List<String> _prefer = [];
  final List<String> _only = [];
  late bool _onlyFiltered = widget.hasFilter;

  static const _rules = [
    (KeepRule.newest, 'Newest', 'Keep the most recently modified copy'),
    (KeepRule.oldest, 'Oldest', 'Keep the original, earliest copy'),
    (KeepRule.shallowestPath, 'Closest to the top', 'Keep the copy with the fewest sub-folders'),
    (KeepRule.shortestPath, 'Shortest path', 'Keep the copy with the shortest full path'),
    (KeepRule.longestPath, 'Longest path', 'Keep the most deeply organised copy'),
    (KeepRule.firstAlphabetical, 'Alphabetical', 'Keep the first copy by path name'),
  ];

  Future<void> _addFolder(List<String> target) async {
    final path = await FilePicker.getDirectoryPath(dialogTitle: 'Choose folder');
    if (path != null && !target.contains(path)) setState(() => target.add(path));
  }

  Widget _folderList(String title, String hint, List<String> target) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in target)
              InputChip(
                label: Text(p, overflow: TextOverflow.ellipsis),
                onDeleted: () => setState(() => target.remove(p)),
              ),
            for (final r in widget.roots.where((r) => !target.contains(r)))
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(r),
                onPressed: () => setState(() => target.add(r)),
              ),
            if (!Platform.isIOS)
              ActionChip(
                avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Other folder…'),
                onPressed: () => _addFolder(target),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Options scroll; the Apply button stays visible below them.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Smart select', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Selects every copy except the one to keep in each group. You can adjust individual groups afterwards.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                RadioGroup<KeepRule>(
                  groupValue: _keep,
                  onChanged: (v) => setState(() => _keep = v ?? _keep),
                  child: Column(
                    children: [
                      for (final (rule, title, subtitle) in _rules)
                        RadioListTile<KeepRule>(
                          contentPadding: EdgeInsets.zero,
                          value: rule,
                          title: Text('Keep: $title'),
                          subtitle: Text(subtitle),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                _folderList('Always keep copies in', 'Copies in these folders win over the rule above', _prefer),
                const SizedBox(height: 16),
                _folderList(
                  'Only remove copies in',
                  'Leave everything else untouched (e.g. clean up Downloads only)',
                  _only,
                ),
                if (widget.hasFilter) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _onlyFiltered,
                    onChanged: (v) => setState(() => _onlyFiltered = v),
                    title: const Text('Only groups matching the current filter'),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: FilledButton.icon(
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Apply'),
            onPressed: () => Navigator.pop(
              context,
              SmartSelection(keep: _keep, preferKeepIn: _prefer, onlySelectIn: _only, onlyFiltered: _onlyFiltered),
            ),
          ),
        ),
      ],
    );
  }
}
