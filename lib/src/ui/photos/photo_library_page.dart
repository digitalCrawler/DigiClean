import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/format.dart';
import '../../core/photo_library.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../results/photo_cards.dart';
import '../widgets/common.dart';

/// Similar photos, blurry and dark photos and screenshots in the device
/// photo library (iOS), with deletion through the system.
class PhotoLibraryPage extends ConsumerStatefulWidget {
  const PhotoLibraryPage({super.key});

  @override
  ConsumerState<PhotoLibraryPage> createState() => _PhotoLibraryPageState();
}

enum _Phase { intro, reading, analysing, results, denied }

class _PhotoLibraryPageState extends ConsumerState<PhotoLibraryPage> {
  _Phase _phase = _Phase.intro;
  List<LibraryPhoto> _photos = const [];
  List<ImageGroupDto> _groups = const [];
  Map<int, List<PhotoIssueKind>> _issues = const {};
  final Set<String> _selected = {};
  bool _review = false;
  bool _deleting = false;

  PhotoLibrarySource get _source => ref.read(photoLibrarySourceProvider)!;

  Future<void> _analyse() async {
    setState(() => _phase = _Phase.reading);
    try {
      final access = await _source.requestAccess();
      if (access == LibraryAccess.denied) {
        setState(() => _phase = _Phase.denied);
        return;
      }
      final paths = ref.read(appPathsProvider);
      final photos = await _source.exportPreviews(p.join(paths.cacheDir, 'photo-previews'));
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _phase = _Phase.analysing;
      });
      final analysis = await analyzeImageSet(
        images: [
          for (final ph in photos)
            ImageInputDto(path: ph.preview, width: ph.width, height: ph.height, screenshot: ph.screenshot),
        ],
        cacheDir: paths.cacheDir,
      );
      if (!mounted) return;
      setState(() {
        _groups = analysis.groups;
        _issues = {for (final i in analysis.issues) i.index: i.issues};
        _selected.clear();
        _phase = _Phase.results;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.intro);
      showError(context, e);
    }
  }

  /// Every similar set keeps at least one photo.
  bool _keepsOneOfEach(Set<String> selection) =>
      _groups.every((g) => g.members.any((m) => !selection.contains(_photos[m].id)));

  void _toggle(int index, bool selected) {
    final id = _photos[index].id;
    final next = {..._selected};
    selected ? next.add(id) : next.remove(id);
    if (!_keepsOneOfEach(next)) {
      showMessage(context, 'Keep at least one photo of each set');
      return;
    }
    setState(
      () => _selected
        ..clear()
        ..addAll(next),
    );
  }

  void _keepBest() {
    setState(() {
      for (final g in _groups) {
        for (final m in g.members) {
          final id = _photos[m].id;
          m == g.best ? _selected.remove(id) : _selected.add(id);
        }
      }
    });
  }

  Future<void> _delete() async {
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Delete ${plural(count, 'photo')}?'),
        content: const Text(
          'Your device asks you to confirm. Deleted photos stay in Recently Deleted for 30 days, '
          'where you can recover them.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      final ids = _selected.toList();
      final deleted = await _source.delete(ids);
      if (!mounted) return;
      if (deleted == 0) {
        showMessage(context, 'Nothing was deleted');
        return;
      }
      final gone = ids.toSet();
      final keep = [
        for (var i = 0; i < _photos.length; i++)
          if (!gone.contains(_photos[i].id)) i,
      ];
      final remap = {for (var n = 0; n < keep.length; n++) keep[n]: n};
      setState(() {
        _photos = [for (final i in keep) _photos[i]];
        _groups = [
          for (final g in _groups)
            if (g.members.where(remap.containsKey).length > 1)
              ImageGroupDto(
                members: Uint32List.fromList([
                  for (final m in g.members)
                    if (remap.containsKey(m)) remap[m]!,
                ]),
                best: remap[g.best] ?? remap[g.members.firstWhere(remap.containsKey)]!,
              ),
        ];
        _issues = {
          for (final e in _issues.entries)
            if (remap.containsKey(e.key)) remap[e.key]!: e.value,
        };
        _selected.clear();
      });
      showMessage(context, 'Moved ${plural(deleted, 'photo')} to Recently Deleted');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = switch (_phase) {
      _Phase.intro => EmptyState(
        icon: Icons.photo_library_outlined,
        title: 'Clean up your Photos library',
        message:
            'Finds similar shots (bursts, edits, saved copies) and suggests the best one to keep, '
            'plus blurry and dark photos and screenshots. Only small previews are read; nothing is uploaded.',
        action: FilledButton.icon(
          onPressed: _analyse,
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Analyse my photos'),
        ),
      ),
      _Phase.reading || _Phase.analysing => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_phase == _Phase.reading ? 'Reading your library…' : 'Analysing ${plural(_photos.length, 'photo')}…'),
          ],
        ),
      ),
      _Phase.denied => EmptyState(
        icon: Icons.lock_outline,
        title: 'No access to your photos',
        message: 'Allow DigiClean to access your photos in Settings › Privacy › Photos.',
        action: OutlinedButton(onPressed: _analyse, child: const Text('Try again')),
      ),
      _Phase.results => _results(theme),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Photos library')),
      body: body,
      bottomNavigationBar: _phase == _Phase.results && _selected.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: _deleting ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Delete ${plural(_selected.length, 'photo')}'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _results(ThemeData theme) {
    final reviewIndices = _issues.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Flexible(
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text('Similar (${_groups.length})')),
                  ButtonSegment(value: true, label: Text('To review (${reviewIndices.length})')),
                ],
                selected: {_review},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _review = s.first),
              ),
            ),
            if (!_review && _groups.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _keepBest,
                icon: const Icon(Icons.star_outline),
                label: const Text('Keep best'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (!_review && _groups.isEmpty) const EmptyState(icon: Icons.check_circle_outline, title: 'No similar photos'),
        if (_review && reviewIndices.isEmpty)
          const EmptyState(icon: Icons.check_circle_outline, title: 'Nothing to review'),
        if (!_review)
          for (final g in _groups)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${g.members.length} similar photos', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final m in g.members)
                          _Thumb(
                            photo: _photos[m],
                            best: m == g.best,
                            selected: _selected.contains(_photos[m].id),
                            onChanged: (v) => _toggle(m, v),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        if (_review)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final i in reviewIndices)
                _Thumb(
                  photo: _photos[i],
                  label: _issues[i]!.map(photoIssueLabel).join(', '),
                  selected: _selected.contains(_photos[i].id),
                  onChanged: (v) => _toggle(i, v),
                ),
            ],
          ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.photo, required this.selected, required this.onChanged, this.best = false, this.label});

  final LibraryPhoto photo;
  final bool selected;
  final bool best;
  final String? label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onChanged(!selected),
      child: SizedBox(
        width: 104,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      width: 3,
                      color: selected ? scheme.error : (best ? scheme.primary : Colors.transparent),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.file(File(photo.preview), width: 98, height: 98, fit: BoxFit.cover, cacheWidth: 200),
                  ),
                ),
                Positioned(
                  top: 2,
                  left: 2,
                  child: Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
                ),
                if (best) Positioned(bottom: 6, left: 6, child: TagChip('Best', color: scheme.primary)),
              ],
            ),
            Text(
              label ?? (photo.width > 0 ? '${photo.width}×${photo.height}' : ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
