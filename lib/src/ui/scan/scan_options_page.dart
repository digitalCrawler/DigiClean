import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../rust/api/types.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';

Future<void> openScanOptions(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanOptionsPage(), fullscreenDialog: true));
}

/// Filters and engine options. Changes apply immediately and persist.
class ScanOptionsPage extends ConsumerWidget {
  const ScanOptionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    void set(AppSettings Function(AppSettings) f) => controller.update(f);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Filters & options'),
        actions: [
          TextButton(onPressed: controller.reset, child: const Text('Reset')),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const SectionHeader('File types'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('All'),
                    selected: s.categories.isEmpty,
                    onSelected: (_) => set((s) => s.copyWith(categories: {})),
                  ),
                  for (final c in Category.values)
                    FilterChip(
                      avatar: Icon(categoryIcon(c), size: 18),
                      label: Text(categoryLabel(c)),
                      selected: s.categories.contains(c),
                      onSelected: (on) => set(
                        (s) => s.copyWith(categories: on ? {...s.categories, c} : ({...s.categories}..remove(c))),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _ExtensionsField(
                label: 'Only these extensions',
                hint: 'e.g. jpg, png, mp4',
                values: s.includeExtensions,
                onChanged: (v) => set((s) => s.copyWith(includeExtensions: v)),
              ),
              const SizedBox(height: 12),
              _ExtensionsField(
                label: 'Skip these extensions',
                hint: 'e.g. tmp, log',
                values: s.excludeExtensions,
                onChanged: (v) => set((s) => s.copyWith(excludeExtensions: v)),
              ),
              const SizedBox(height: 16),
              const SectionHeader('File size'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (label, bytes) in const [
                    ('Any', 1),
                    ('≥ 100 KB', 100 << 10),
                    ('≥ 1 MB', 1 << 20),
                    ('≥ 10 MB', 10 << 20),
                    ('≥ 100 MB', 100 << 20),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: s.minSize == bytes,
                      onSelected: (_) => set((s) => s.copyWith(minSize: bytes)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _SizeField(
                      label: 'Minimum',
                      value: s.minSize <= 1 ? null : s.minSize,
                      onChanged: (v) => set((s) => s.copyWith(minSize: v ?? 1)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SizeField(
                      label: 'Maximum',
                      value: s.maxSize,
                      onChanged: (v) => set((s) => s.copyWith(maxSize: () => v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const SectionHeader('Folders'),
              SwitchListTile(
                title: const Text('Include sub-folders'),
                value: s.recursive,
                onChanged: (v) => set((s) => s.copyWith(recursive: v)),
              ),
              if (s.recursive)
                ListTile(
                  title: const Text('Maximum depth'),
                  subtitle: Text(s.maxDepth == null ? 'Unlimited' : '${s.maxDepth} levels below each location'),
                  trailing: SizedBox(
                    width: 200,
                    child: Slider(
                      value: (s.maxDepth ?? 21).toDouble(),
                      min: 1,
                      max: 21,
                      divisions: 20,
                      label: s.maxDepth == null ? '∞' : '${s.maxDepth}',
                      onChanged: (v) => set((s) => s.copyWith(maxDepth: () => v >= 21 ? null : v.round())),
                    ),
                  ),
                ),
              SwitchListTile(
                title: const Text('Include hidden files and folders'),
                value: s.includeHidden,
                onChanged: (v) => set((s) => s.copyWith(includeHidden: v)),
              ),
              SwitchListTile(
                title: const Text('Skip system folders'),
                subtitle: const Text('Operating-system, recycle bin and app-private locations'),
                value: s.skipSystemFolders,
                onChanged: (v) => set((s) => s.copyWith(skipSystemFolders: v)),
              ),
              if (Platform.isWindows)
                SwitchListTile(
                  title: const Text('Skip online-only cloud files'),
                  subtitle: const Text('Avoids downloading OneDrive / Dropbox placeholders'),
                  value: s.skipCloudPlaceholders,
                  onChanged: (v) => set((s) => s.copyWith(skipCloudPlaceholders: v)),
                ),
              if (!Platform.isAndroid && !Platform.isIOS)
                SwitchListTile(
                  title: const Text('Follow symbolic links'),
                  value: s.followSymlinks,
                  onChanged: (v) => set((s) => s.copyWith(followSymlinks: v)),
                ),
              const SizedBox(height: 8),
              _ExcludedFolders(
                paths: s.excludePaths,
                onChanged: (v) => set((s) => s.copyWith(excludePaths: v)),
              ),
              const SizedBox(height: 12),
              _ListEditor(
                title: 'Exclude patterns',
                hint: '**/node_modules or *.tmp',
                values: s.excludeGlobs,
                onChanged: (v) => set((s) => s.copyWith(excludeGlobs: v)),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Detection'),
              ListTile(
                title: const Text('Hash algorithm'),
                subtitle: const Text('BLAKE3 is several times faster; both are cryptographically strong'),
                trailing: SegmentedButton<HashAlgo>(
                  segments: const [
                    ButtonSegment(value: HashAlgo.blake3, label: Text('BLAKE3')),
                    ButtonSegment(value: HashAlgo.sha256, label: Text('SHA-256')),
                  ],
                  selected: {s.hashAlgorithm},
                  onSelectionChanged: (v) => set((s) => s.copyWith(hashAlgorithm: v.first)),
                ),
              ),
              SwitchListTile(
                title: const Text('Verify byte-by-byte'),
                subtitle: const Text('Compares duplicates directly after hashing. Slower, for absolute certainty.'),
                value: s.verifyByteByByte,
                onChanged: (v) => set((s) => s.copyWith(verifyByteByByte: v)),
              ),
              SwitchListTile(
                title: const Text('Find duplicate folders'),
                subtitle: const Text('Folders with identical structure and contents'),
                value: s.detectFolders,
                onChanged: (v) => set((s) => s.copyWith(detectFolders: v)),
              ),
              SwitchListTile(
                title: const Text('Find empty folders'),
                value: s.detectEmptyFolders,
                onChanged: (v) => set((s) => s.copyWith(detectEmptyFolders: v)),
              ),
              SwitchListTile(
                title: const Text('Group empty (0-byte) files'),
                value: s.includeEmptyFiles,
                onChanged: (v) => set((s) => s.copyWith(includeEmptyFiles: v)),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Performance'),
              const PerformancePicker(),
              SwitchListTile(
                title: const Text('Remember file fingerprints'),
                subtitle: const Text('Rescans only read files that changed'),
                value: s.useCache,
                onChanged: (v) => set((s) => s.copyWith(useCache: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PerformancePicker extends ConsumerWidget {
  const PerformancePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final options = <(PerformanceMode?, String, String)>[
      (null, 'Automatic', AppSettings.isMobile ? 'Balanced on this device' : 'Maximum speed on this device'),
      (PerformanceMode.maximum, 'Maximum speed', 'Uses every CPU core'),
      (PerformanceMode.balanced, 'Balanced', 'Leaves headroom for other apps'),
      (PerformanceMode.batterySaver, 'Battery saver', 'One worker; cool and quiet'),
      (PerformanceMode.spinningDisk, 'Hard disk (HDD)', 'Sequential reads, avoids seek thrashing'),
    ];
    return RadioGroup<int>(
      groupValue: options.indexWhere((o) => o.$1 == s.performance),
      onChanged: (i) {
        if (i == null) return;
        ref.read(settingsProvider.notifier).update((s) => s.copyWith(performance: () => options[i].$1));
      },
      child: Column(
        children: [
          for (var i = 0; i < options.length; i++)
            RadioListTile<int>(value: i, title: Text(options[i].$2), subtitle: Text(options[i].$3)),
        ],
      ),
    );
  }
}

class _SizeField extends StatefulWidget {
  const _SizeField({required this.label, required this.value, required this.onChanged});

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  State<_SizeField> createState() => _SizeFieldState();
}

class _SizeFieldState extends State<_SizeField> {
  late final _controller = TextEditingController(text: widget.value == null ? '' : formatBytes(widget.value!));
  String? _error;

  @override
  void didUpdateWidget(covariant _SizeField old) {
    super.didUpdateWidget(old);
    final parsed = parseSize(_controller.text);
    if (parsed != widget.value && !(parsed == null && widget.value == null)) {
      _controller.text = widget.value == null ? '' : formatBytes(widget.value!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(labelText: widget.label, hintText: 'e.g. 500 KB', errorText: _error),
      onChanged: (text) {
        if (text.trim().isEmpty) {
          setState(() => _error = null);
          widget.onChanged(null);
          return;
        }
        final v = parseSize(text);
        setState(() => _error = v == null ? 'Use a size like 10 MB' : null);
        if (v != null) widget.onChanged(v);
      },
    );
  }
}

class _ExtensionsField extends StatefulWidget {
  const _ExtensionsField({required this.label, required this.hint, required this.values, required this.onChanged});

  final String label;
  final String hint;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_ExtensionsField> createState() => _ExtensionsFieldState();
}

class _ExtensionsFieldState extends State<_ExtensionsField> {
  late final _controller = TextEditingController(text: widget.values.join(', '));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(labelText: widget.label, hintText: widget.hint),
      onChanged: (text) => widget.onChanged(
        text
            .split(RegExp(r'[,\s;]+'))
            .map((e) => e.trim().replaceFirst(RegExp(r'^\*?\.'), '').toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList(),
      ),
    );
  }
}

class _ExcludedFolders extends StatelessWidget {
  const _ExcludedFolders({required this.paths, required this.onChanged});

  final List<String> paths;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: const Text('Excluded folders'),
            subtitle: paths.isEmpty ? const Text('None') : null,
            trailing: Platform.isIOS
                ? null
                : IconButton(
                    tooltip: 'Add',
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      final path = await FilePicker.getDirectoryPath(dialogTitle: 'Folder to exclude');
                      if (path != null && !paths.contains(path)) onChanged([...paths, path]);
                    },
                  ),
          ),
          for (final p in paths)
            ListTile(
              dense: true,
              leading: const Icon(Icons.block, size: 20),
              title: Text(p, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => onChanged(paths.where((x) => x != p).toList()),
              ),
            ),
        ],
      ),
    );
  }
}

class _ListEditor extends StatefulWidget {
  const _ListEditor({required this.title, required this.hint, required this.values, required this.onChanged});

  final String title;
  final String hint;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<_ListEditor> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final v = _controller.text.trim();
    if (v.isEmpty || widget.values.contains(v)) return;
    widget.onChanged([...widget.values, v]);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in widget.values)
                  InputChip(
                    label: Text(v),
                    onDeleted: () => widget.onChanged(widget.values.where((x) => x != v).toList()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: widget.hint,
                suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
              ),
              onSubmitted: (_) => _add(),
            ),
          ],
        ),
      ),
    );
  }
}
