import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/native.dart';
import '../../core/treemap.dart';
import '../../rust/api/types.dart';
import '../../state/results_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import 'space_actions.dart';

Future<void> openSpaceMap(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SpaceMapPage()));

/// Most tiles drawn per level; the rest are summed into one "other" tile.
const _maxTiles = 40;

/// Where space goes in the scanned folders: a treemap to drill into, and
/// the same folders as a list with actions.
class SpaceMapPage extends ConsumerStatefulWidget {
  const SpaceMapPage({super.key});

  @override
  ConsumerState<SpaceMapPage> createState() => _SpaceMapPageState();
}

class _SpaceMapPageState extends ConsumerState<SpaceMapPage> {
  /// Open folders, outermost first (empty = the scanned roots).
  final List<SpaceNodeDto> _trail = [];
  List<SpaceNodeDto>? _nodes;
  int _generation = -1;

  int? get _folderId => _trail.isEmpty ? null : _trail.last.folderId;

  Future<void> _load() async {
    final results = ref.read(resultsProvider).results;
    if (results == null) return;
    final nodes = await results.spaceChildren(folderId: _folderId);
    if (!mounted) return;
    // A single scanned root opens straight away.
    if (_trail.isEmpty && nodes.length == 1 && nodes.first.folderId != null) {
      _trail.add(nodes.first);
      return _load();
    }
    setState(() => _nodes = nodes);
  }

  void _open(SpaceNodeDto node) {
    if (node.folderId == null) {
      _showFiles(_trail.isEmpty ? null : _trail.last);
      return;
    }
    setState(() {
      _trail.add(node);
      _nodes = null;
    });
    _load();
  }

  void _goTo(int depth) {
    setState(() {
      _trail.removeRange(depth, _trail.length);
      _nodes = null;
    });
    _load();
  }

  Future<void> _showFiles(SpaceNodeDto? folder) async {
    final results = ref.read(resultsProvider).results;
    final id = folder?.folderId;
    if (results == null || id == null) return;
    final files = await results.filesIn(folderId: id, limit: 200);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Files in ${folder!.name}', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final f in files)
              ListTile(
                leading: FileThumbnail(path: f.path, size: 36),
                title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(formatRelative(f.modifiedMs)),
                trailing: Text(formatBytes(f.size)),
                onTap: () => openFile(context, f.path),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(resultsProvider);
    if (state.generation != _generation) {
      _generation = state.generation;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final nodes = _nodes;
    final total = nodes?.fold<int>(0, (s, n) => s + n.bytes) ?? 0;
    final wide = !context.isCompact;

    final map = nodes == null
        ? const Center(child: CircularProgressIndicator())
        : nodes.isEmpty
        ? const EmptyState(
            icon: Icons.folder_open,
            title: 'Nothing here',
            message: 'This folder holds no scanned files.',
          )
        : _Treemap(nodes: nodes, total: total, onOpen: _open);
    final list = nodes == null || nodes.isEmpty
        ? const SizedBox.shrink()
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            itemCount: nodes.length,
            itemBuilder: (context, i) => _NodeTile(
              node: nodes[i],
              total: total,
              parentName: _trail.isEmpty ? '' : _trail.last.name,
              onOpen: () => _open(nodes[i]),
            ),
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Space map'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: _Breadcrumbs(trail: _trail, total: total, onTap: _goTo),
        ),
      ),
      body: state.results == null
          ? const EmptyState(
              icon: Icons.manage_search,
              title: 'No scan yet',
              message: 'Scan folders to see where space goes.',
            )
          : wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: Padding(padding: const EdgeInsets.all(12), child: map),
                ),
                SizedBox(width: 380, child: list),
              ],
            )
          : Column(
              children: [
                SizedBox(
                  height: 280,
                  child: Padding(padding: const EdgeInsets.all(12), child: map),
                ),
                Expanded(child: list),
              ],
            ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.trail, required this.total, required this.onTap});

  final List<SpaceNodeDto> trail;
  final int total;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            TextButton(onPressed: trail.isEmpty ? null : () => onTap(0), child: const Text('Scanned folders')),
            for (var i = 0; i < trail.length; i++) ...[
              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
              TextButton(onPressed: i == trail.length - 1 ? null : () => onTap(i + 1), child: Text(trail[i].name)),
            ],
            if (total > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(formatBytes(total), style: theme.textTheme.labelLarge),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tiles sized by bytes; folders open on tap.
class _Treemap extends StatelessWidget {
  const _Treemap({required this.nodes, required this.total, required this.onOpen});

  final List<SpaceNodeDto> nodes;
  final int total;
  final ValueChanged<SpaceNodeDto> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = nodes.take(_maxTiles).toList();
    final rest = nodes.skip(_maxTiles).fold<int>(0, (s, n) => s + n.bytes);
    final values = [for (final n in shown) n.bytes.toDouble(), if (rest > 0) rest.toDouble()];
    final palette = _palette(theme.colorScheme, theme.brightness);
    return LayoutBuilder(
      builder: (context, box) {
        final rects = squarify(values, Offset.zero & box.biggest);
        return Stack(
          children: [
            for (var i = 0; i < values.length; i++)
              Positioned.fromRect(
                rect: rects[i].deflate(1.5),
                child: i < shown.length
                    ? _Tile(
                        node: shown[i],
                        share: total == 0 ? 0 : shown[i].bytes / total,
                        color: palette[i % palette.length],
                        onTap: () => onOpen(shown[i]),
                      )
                    : _OtherTile(count: nodes.length - shown.length, bytes: rest),
              ),
          ],
        );
      },
    );
  }

  static List<Color> _palette(ColorScheme scheme, Brightness b) {
    final dark = b == Brightness.dark;
    final bases = [scheme.primary, scheme.tertiary, scheme.secondary, const Color(0xFF3B82B8), const Color(0xFF8E6BBF)];
    return [
      for (final c in bases)
        for (final t in [0.0, 0.25]) Color.lerp(c, dark ? Colors.black : Colors.white, t + (dark ? 0.15 : 0.1))!,
    ];
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.node, required this.share, required this.color, required this.onTap});

  final SpaceNodeDto node;
  final double share;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onColor = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black87;
    final label = node.folderId == null ? 'Files here' : node.name;
    return Tooltip(
      message: '$label · ${formatBytes(node.bytes)} · ${(share * 100).toStringAsFixed(1)}%',
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < 56 || box.maxHeight < 30) return const SizedBox.expand();
              return Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: box.maxHeight > 70 ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: onColor, fontWeight: FontWeight.w600, fontSize: 12.5),
                    ),
                    if (box.maxHeight > 46)
                      Text(
                        formatBytes(node.bytes),
                        style: TextStyle(color: onColor.withValues(alpha: 0.85), fontSize: 11.5),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OtherTile extends StatelessWidget {
  const _OtherTile({required this.count, required this.bytes});

  final int count;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '${plural(count, 'smaller item')} · ${formatBytes(bytes)}',
      child: Container(
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

class _NodeTile extends ConsumerWidget {
  const _NodeTile({required this.node, required this.total, required this.parentName, required this.onOpen});

  final SpaceNodeDto node;
  final int total;
  final String parentName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final share = total == 0 ? 0.0 : node.bytes / total;
    final isFolder = node.folderId != null;
    return ListTile(
      leading: Icon(isFolder ? Icons.folder_outlined : Icons.description_outlined),
      title: Text(
        isFolder ? node.name : 'Files in ${parentName.isEmpty ? 'this folder' : parentName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: share, minHeight: 5, backgroundColor: scheme.surfaceContainerHighest),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '${(share * 100).toStringAsFixed(share < 0.1 ? 1 : 0)}%',
              plural(node.files, 'file'),
              if (node.folders > 0) plural(node.folders, 'folder'),
            ].join(' · '),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatBytes(node.bytes), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          if (isFolder) _NodeMenu(node: node),
        ],
      ),
      onTap: onOpen,
    );
  }
}

class _NodeMenu extends ConsumerWidget {
  const _NodeMenu({required this.node});

  final SpaceNodeDto node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) async {
        switch (v) {
          case 'reveal':
            await NativePlatform.revealInFileManager(node.path);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: node.path));
            if (context.mounted) showMessage(context, 'Path copied');
          case 'zip':
            await compressFlow(context, ref, node.path, node.bytes);
          case 'move':
            await moveToDriveFlow(context, ref, node.path, node.bytes);
        }
      },
      itemBuilder: (_) => [
        if (NativePlatform.canReveal)
          const PopupMenuItem(
            value: 'reveal',
            child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Show in folder')),
          ),
        const PopupMenuItem(
          value: 'zip',
          child: ListTile(
            leading: Icon(Icons.folder_zip_outlined),
            title: Text('Compress to .zip…'),
            subtitle: Text('For folders you rarely open'),
          ),
        ),
        const PopupMenuItem(
          value: 'move',
          child: ListTile(
            leading: Icon(Icons.drive_file_move_outline),
            title: Text('Move to another drive…'),
            subtitle: Text('Frees space here without deleting'),
          ),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(leading: Icon(Icons.copy), title: Text('Copy full path')),
        ),
      ],
    );
  }
}
