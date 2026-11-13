import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../../state/navigation.dart';
import '../../state/paged_list.dart';
import '../../state/results_controller.dart';
import '../../state/scan_controller.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'action_flow.dart';
import 'export_report.dart';
import 'ignore_actions.dart';
import 'photo_cards.dart';
import 'review_detail.dart';
import 'review_rows.dart';
import 'smart_select_sheet.dart';

/// Copy-on-write clones are offered unless a scanned drive is known not to
/// support them (Windows tells; other systems are tried).
final _clonesProvider = Provider<bool>((ref) {
  final roots = ref.watch(resultsProvider.select((r) => r.roots));
  if (Platform.isAndroid || roots.isEmpty) return false;
  return roots.every((r) => cloneSupport(path: r) != false);
});

/// Ages offered on the old-files list.
const _oldAges = [
  (label: '6 months', days: 182),
  (label: '1 year', days: 365),
  (label: '2 years', days: 730),
  (label: '5 years', days: 1826),
];

enum _OldScope { everywhere, downloads, installers }

/// Installer and disk-image formats.
const installerExtensions = [
  'exe',
  'msi',
  'msix',
  'appx',
  'dmg',
  'pkg',
  'apk',
  'xapk',
  'deb',
  'rpm',
  'appimage',
  'iso',
];

/// Size thresholds offered on the large-files list.
const _largeThresholds = [
  (label: 'All', bytes: 0),
  (label: '≥ 10 MB', bytes: 10 << 20),
  (label: '≥ 100 MB', bytes: 100 << 20),
  (label: '≥ 1 GB', bytes: 1 << 30),
];

/// Kinds that exist only after the media analysis.
const _analysedKinds = {ResultKind.similarPhotos, ResultKind.photoIssues, ResultKind.similarMedia};

/// One entry of the sections list.
class _Section {
  const _Section(this.kind, this.label, this.icon, this.description, {required this.group, this.count, this.bytes});

  final ResultKind kind;
  final String label;
  final IconData icon;
  final String description;
  final String group;

  /// `null` while unknown (old files loading, media not analysed).
  final int? count;
  final int? bytes;
}

/// Results as a review workspace: sections on the left, the items of the
/// chosen section in the middle and a large preview with the decisions on
/// the right. Phones show the list and open the preview full screen.
class ResultsPage extends ConsumerStatefulWidget {
  const ResultsPage({super.key, required this.onStartScan});

  final VoidCallback onStartScan;

  @override
  ConsumerState<ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends ConsumerState<ResultsPage> {
  final _searchController = TextEditingController();
  final _listFocus = FocusNode(debugLabel: 'review list');
  Timer? _debounce;

  ResultKind _section = ResultKind.files;
  final Map<ResultKind, int> _focus = {};
  final Map<ResultKind, ScrollController> _scroll = {};

  SortBy _sort = SortBy.wasted;
  bool _descending = true;
  Category? _category;
  String _search = '';
  bool _searching = false;

  ScanResults? _bound;
  int _boundGeneration = -1;
  PagedList<FileGroupDto>? _files;
  PagedList<FolderGroupDto>? _folders;
  PagedList<FolderEntryDto>? _empty;
  PagedList<FileEntryDto>? _large;
  int _largeMin = 0;
  PagedList<JunkEntryDto>? _junk;
  JunkKind? _junkKind;
  PagedList<FileEntryDto>? _old;
  int _oldDays = 365;
  _OldScope _oldScope = _OldScope.everywhere;
  PagedList<SimilarGroupDto>? _similar;
  PagedList<PhotoDto>? _photoList;
  PagedList<MediaGroupDto>? _mediaGroups;
  PhotoIssueKind? _photoIssueKind;
  List<CategoryStat> _categories = const [];

  ResultKind get _kind => _section;

  @override
  void dispose() {
    _searchController.dispose();
    _listFocus.dispose();
    _debounce?.cancel();
    for (final c in _scroll.values) {
      c.dispose();
    }
    _disposeLists();
    super.dispose();
  }

  void _disposeLists() {
    _files?.dispose();
    _folders?.dispose();
    _empty?.dispose();
    _large?.dispose();
    _junk?.dispose();
    _old?.dispose();
    _similar?.dispose();
    _photoList?.dispose();
    _mediaGroups?.dispose();
    _files = _folders = null;
    _empty = null;
    _large = _old = null;
    _junk = null;
    _similar = null;
    _photoList = null;
    _mediaGroups = null;
  }

  GroupQuery _query(int offset, int limit, {bool category = true}) => GroupQuery(
    offset: offset,
    limit: limit,
    sort: _sort,
    descending: _descending,
    category: category ? _category : null,
    search: _search.isEmpty ? null : _search,
  );

  /// Lists of single files are sorted by size where groups use "space to free".
  SortBy get _fileSort => _sort == SortBy.wasted || _sort == SortBy.count ? SortBy.size : _sort;

  /// (Re)creates paged lists for a new result set and reloads them when
  /// the results change.
  void _bind(ScanResults results, int generation) {
    if (!identical(results, _bound)) {
      _disposeLists();
      _bound = results;
      _focus.clear();
      _files = PagedList((o, l) async {
        final page = await results.fileGroups(query: _query(o, l));
        return (page.total, page.groups);
      });
      _folders = PagedList((o, l) async {
        final page = await results.folderGroups(query: _query(o, l, category: false));
        return (page.total, page.groups);
      });
      _large = PagedList((o, l) async {
        final page = await results.largeFiles(
          query: GroupQuery(
            offset: o,
            limit: l,
            sort: _fileSort,
            descending: _descending,
            search: _search.isEmpty ? null : _search,
            minSize: _largeMin > 0 ? _largeMin : null,
          ),
        );
        return (page.total, page.files);
      }, pageSize: 60);
      _similar = PagedList((o, l) async {
        final page = await results.similarGroups(query: _query(o, l, category: false));
        return (page.total, page.groups);
      }, pageSize: 20);
      _mediaGroups = PagedList((o, l) async {
        final page = await results.mediaGroups(query: _query(o, l, category: false));
        return (page.total, page.groups);
      }, pageSize: 30);
      _photoList = PagedList((o, l) async {
        final page = await results.photoIssues(
          query: GroupQuery(
            offset: o,
            limit: l,
            sort: _fileSort,
            descending: _descending,
            search: _search.isEmpty ? null : _search,
            photoIssue: _photoIssueKind,
          ),
        );
        return (page.total, page.photos);
      }, pageSize: 60);
      _old = PagedList((o, l) async {
        final paths = ref.read(appPathsProvider);
        final page = await results.oldFiles(
          query: GroupQuery(
            offset: o,
            limit: l,
            sort: _fileSort,
            descending: _descending,
            search: _search.isEmpty ? null : _search,
            modifiedBeforeMs: DateTime.now().subtract(Duration(days: _oldDays)).millisecondsSinceEpoch,
            within: _oldScope == _OldScope.downloads ? paths.downloadDirs : null,
            extensions: _oldScope == _OldScope.installers ? installerExtensions : null,
          ),
        );
        return (page.total, page.files);
      }, pageSize: 60);
      _junk = PagedList((o, l) async {
        final page = await results.junk(
          query: GroupQuery(
            offset: o,
            limit: l,
            sort: _fileSort,
            descending: _descending,
            search: _search.isEmpty ? null : _search,
            junkKind: _junkKind,
          ),
        );
        return (page.total, page.items);
      }, pageSize: 80);
      _empty = PagedList((o, l) async {
        final page = await results.emptyFolders(query: _query(o, l, category: false));
        return (page.total, page.folders);
      }, pageSize: 100);
      _boundGeneration = -1;
    }
    if (generation != _boundGeneration) {
      _boundGeneration = generation;
      _reload();
    }
  }

  void _reload() {
    _files?.reset();
    _folders?.reset();
    _empty?.reset();
    _large?.reset();
    _junk?.reset();
    _old?.reset();
    _similar?.reset();
    _photoList?.reset();
    _mediaGroups?.reset();
    final results = _bound;
    if (results != null) {
      results.categoryBreakdown().then((c) {
        if (mounted && identical(results, _bound)) setState(() => _categories = c);
      });
    }
  }

  /// A filter, sort or search changed: reload and start from the top.
  void _setQuery(VoidCallback change) {
    setState(() {
      change();
      _focus.clear();
    });
    for (final c in _scroll.values) {
      if (c.hasClients) c.jumpTo(0);
    }
    _reload();
  }

  PagedList<Object?>? _listFor(ResultKind kind) => switch (kind) {
    ResultKind.files => _files,
    ResultKind.folders => _folders,
    ResultKind.similarPhotos => _similar,
    ResultKind.photoIssues => _photoList,
    ResultKind.similarMedia => _mediaGroups,
    ResultKind.largeFiles => _large,
    ResultKind.oldFiles => _old,
    ResultKind.junk => _junk,
    ResultKind.emptyFolders => _empty,
  };

  ScrollController _scrollFor(ResultKind kind) => _scroll.putIfAbsent(kind, ScrollController.new);

  // ── Selection ──────────────────────────────────────────────────────

  void _apply(SelectionSummaryDto Function(ScanResults r) call, {void Function(ScanResults r)? refresh}) {
    final results = _bound;
    if (results == null) return;
    try {
      final summary = call(results);
      ref.read(resultsProvider.notifier).selectionChanged(summary);
      refresh?.call(results);
    } catch (e) {
      showError(context, e);
    }
  }

  void _refreshFileGroup(ScanResults r, int index) {
    final g = r.fileGroup(index: index);
    if (g != null) _files?.replaceWhere((x) => x.index == index, (_) => g);
  }

  void _refreshFolderGroup(ScanResults r, int index) {
    final g = r.folderGroup(index: index);
    if (g != null) _folders?.replaceWhere((x) => x.index == index, (_) => g);
  }

  void _refreshSimilar(ScanResults r, int index) {
    final g = r.similarGroup(index: index);
    if (g != null) _similar?.replaceWhere((x) => x.index == index, (_) => g);
  }

  void _refreshMedia(ScanResults r, int index) {
    final g = r.mediaGroup(index: index);
    if (g != null) _mediaGroups?.replaceWhere((x) => x.index == index, (_) => g);
  }

  static FileEntryDto _fileWith(FileEntryDto x, bool sel) => FileEntryDto(
    id: x.id,
    path: x.path,
    name: x.name,
    parent: x.parent,
    size: x.size,
    modifiedMs: x.modifiedMs,
    createdMs: x.createdMs,
    hidden: x.hidden,
    selected: sel,
  );

  void _selectLarge(int id, bool sel) => _apply(
    (r) => r.setLargeFileSelected(fileId: id, selected: sel),
    refresh: (_) => _large?.replaceWhere((x) => x.id == id, (x) => _fileWith(x, sel)),
  );

  void _selectOld(int id, bool sel) => _apply(
    (r) => r.setOldFileSelected(fileId: id, selected: sel),
    refresh: (_) => _old?.replaceWhere((x) => x.id == id, (x) => _fileWith(x, sel)),
  );

  void _selectJunk(int id, bool sel) => _apply(
    (r) => r.setJunkSelected(junkId: id, selected: sel),
    refresh: (_) => _junk?.replaceWhere(
      (x) => x.id == id,
      (x) => JunkEntryDto(
        id: x.id,
        path: x.path,
        name: x.name,
        parent: x.parent,
        size: x.size,
        modifiedMs: x.modifiedMs,
        kind: x.kind,
        safe: x.safe,
        selected: sel,
      ),
    ),
  );

  void _selectPhoto(int id, bool sel) => _apply(
    (r) => r.setPhotoSelected(fileId: id, selected: sel),
    refresh: (_) => _photoList?.replaceWhere(
      (x) => x.id == id,
      (x) => PhotoDto(
        id: x.id,
        path: x.path,
        name: x.name,
        parent: x.parent,
        size: x.size,
        modifiedMs: x.modifiedMs,
        width: x.width,
        height: x.height,
        issues: x.issues,
        best: x.best,
        selected: sel,
      ),
    ),
  );

  void _selectEmpty(int id, bool sel) => _apply(
    (r) => r.setFolderSelected(folderId: id, selected: sel),
    refresh: (_) => _empty?.replaceWhere(
      (x) => x.id == id,
      (x) => FolderEntryDto(
        id: x.id,
        path: x.path,
        name: x.name,
        parent: x.parent,
        modifiedMs: x.modifiedMs,
        selected: sel,
      ),
    ),
  );

  Future<void> _smartSelect() async {
    final results = _bound;
    if (results == null || _kind == ResultKind.emptyFolders) return;
    final choice = await showSmartSelectSheet(
      context,
      folders: _kind == ResultKind.folders,
      hasFilter: _category != null || _search.isNotEmpty,
      roots: ref.read(resultsProvider).roots,
    );
    if (choice == null || !mounted) return;
    await results.applyRule(
      kind: _kind,
      rule: SelectionRuleDto(
        keep: choice.keep,
        preferKeepIn: choice.preferKeepIn,
        onlySelectIn: choice.onlySelectIn,
        category: choice.onlyFiltered && _kind == ResultKind.files ? _category : null,
        search: choice.onlyFiltered && _search.isNotEmpty ? _search : null,
      ),
    );
    ref.read(resultsProvider.notifier).refresh();
  }

  Future<void> _keepBestMedia() async {
    final results = _bound;
    if (results == null) return;
    final summary = await results.selectAllButBestMedia(search: _search.isEmpty ? null : _search);
    ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
  }

  Future<void> _keepBestPhotos() async {
    final results = _bound;
    if (results == null) return;
    final summary = await results.selectAllButBest(search: _search.isEmpty ? null : _search);
    ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
  }

  Future<void> _selectSafeJunk() async {
    final results = _bound;
    if (results == null) return;
    final summary = await results.selectSafeJunk(search: _search.isEmpty ? null : _search, kind: _junkKind);
    ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
  }

  Future<void> _selectAllEmpty() async {
    final results = _bound;
    if (results == null) return;
    final summary = await results.selectAllEmptyFolders(search: _search.isEmpty ? null : _search);
    ref.read(resultsProvider.notifier).selectionChanged(summary, reloadLists: true);
  }

  Future<void> _ignoreFolder(String folder) => ignoreFolder(context, ref, folder);

  // ── Focus and keyboard ─────────────────────────────────────────────

  int _focusOf(ResultKind kind) => _focus[kind] ?? 0;

  void _setFocus(int pos, {bool scroll = true}) {
    final total = _listFor(_section)?.total ?? 0;
    if (total == 0) return;
    final p = pos.clamp(0, total - 1);
    setState(() => _focus[_section] = p);
    if (scroll) _ensureVisible(p);
  }

  void _ensureVisible(int pos) {
    final c = _scrollFor(_section);
    if (!c.hasClients) return;
    final top = pos * reviewRowExtent;
    final view = c.position.viewportDimension;
    double? to;
    if (top < c.offset) {
      to = top;
    } else if (top + reviewRowExtent > c.offset + view) {
      to = top + reviewRowExtent - view;
    }
    if (to != null) {
      c.animateTo(
        to.clamp(0, c.position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final pos = _focusOf(_section);
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.keyJ:
        _setFocus(pos + 1);
      case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.keyK:
        _setFocus(pos - 1);
      case LogicalKeyboardKey.pageDown:
        _setFocus(pos + 8);
      case LogicalKeyboardKey.pageUp:
        _setFocus(pos - 8);
      case LogicalKeyboardKey.home:
        _setFocus(0);
      case LogicalKeyboardKey.end:
        _setFocus(1 << 30);
      case LogicalKeyboardKey.space:
        _toggleFocused();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Space marks or unmarks a single item (large files, junk…).
  void _toggleFocused() {
    final item = _listFor(_section)?.itemAt(_focusOf(_section));
    switch (item) {
      case FileEntryDto f when _section == ResultKind.largeFiles:
        _selectLarge(f.id, !f.selected);
      case FileEntryDto f when _section == ResultKind.oldFiles:
        _selectOld(f.id, !f.selected);
      case JunkEntryDto j:
        _selectJunk(j.id, !j.selected);
      case PhotoDto p:
        _selectPhoto(p.id, !p.selected);
      case FolderEntryDto f:
        _selectEmpty(f.id, !f.selected);
      default:
    }
  }

  void _openRow(int pos) {
    _listFocus.requestFocus();
    if (context.isCompact) {
      setState(() => _focus[_section] = pos);
      final kind = _section;
      final section = _sectionsFor(ref.read(resultsProvider)).firstWhere((s) => s.kind == kind);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _DetailPage(
            title: section.label,
            total: () => _listFor(kind)?.total ?? 0,
            initial: pos,
            listenable: _listFor(kind)!,
            builder: (p) => _detailAt(kind, p),
            onPosition: (p) => _focus[kind] = p,
          ),
        ),
      );
    } else {
      _setFocus(pos, scroll: false);
    }
  }

  // ── Sections ───────────────────────────────────────────────────────

  List<_Section> _sectionsFor(ResultsState state) {
    final s = state.summary;
    final stats = state.stats!;
    final analysed = s?.photosAnalyzed ?? false;
    return [
      _Section(
        ResultKind.files,
        'Duplicate files',
        Icons.file_copy_outlined,
        'Identical contents under any name. Keep one copy of each.',
        group: 'Duplicates',
        count: s?.activeFileGroups ?? stats.duplicateGroups,
        bytes: s?.fileWasted ?? stats.wastedBytes,
      ),
      _Section(
        ResultKind.folders,
        'Duplicate folders',
        Icons.folder_copy_outlined,
        'Whole folders that match file for file.',
        group: 'Duplicates',
        count: s?.activeFolderGroups ?? stats.folderGroups,
        bytes: s?.folderWasted ?? stats.folderWastedBytes,
      ),
      _Section(
        ResultKind.similarPhotos,
        'Similar photos',
        Icons.photo_library_outlined,
        'Photos that look alike: resized, re-saved or burst shots. The best one is marked.',
        group: 'Look-alikes',
        count: analysed ? s!.similarGroups : null,
        bytes: analysed ? s!.similarReclaimable : null,
      ),
      _Section(
        ResultKind.photoIssues,
        'Photos to review',
        Icons.hide_image_outlined,
        'Blurry and dark photos, and screenshots you may not need.',
        group: 'Look-alikes',
        count: analysed ? s!.remainingPhotoIssues : null,
      ),
      _Section(
        ResultKind.similarMedia,
        'Music & video',
        Icons.library_music_outlined,
        'Songs and videos that sound the same, in another format or quality.',
        group: 'Look-alikes',
        count: analysed ? s!.mediaGroups : null,
        bytes: analysed ? s!.mediaReclaimable : null,
      ),
      _Section(
        ResultKind.largeFiles,
        'Large files',
        Icons.photo_size_select_large,
        'Your biggest files. Not duplicates: remove only what you no longer need.',
        group: 'Clean up',
        count: s?.remainingLargeFiles ?? stats.largeFiles,
      ),
      _Section(
        ResultKind.oldFiles,
        'Old files',
        Icons.history_toggle_off,
        'Files nobody has changed for a long time.',
        group: 'Clean up',
        count: _old?.total,
      ),
      _Section(
        ResultKind.junk,
        'Junk',
        Icons.cleaning_services_outlined,
        'Caches, unfinished downloads and temporary files.',
        group: 'Clean up',
        count: s?.remainingJunk ?? stats.junkItems,
        bytes: s?.remainingJunkBytes ?? stats.junkBytes,
      ),
      _Section(
        ResultKind.emptyFolders,
        'Empty folders',
        Icons.folder_off_outlined,
        'Folders with nothing inside.',
        group: 'Clean up',
        count: s?.remainingEmptyFolders ?? stats.emptyFolders,
      ),
    ];
  }

  void _selectSection(ResultKind kind) {
    if (kind == _section) return;
    setState(() => _section = kind);
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(resultsProvider);
    final results = state.results;
    final scanning = ref.watch(scanProvider.select((s) => s.isRunning));

    if (results == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: EmptyState(
          icon: scanning ? Icons.hourglass_top : Icons.manage_search,
          title: scanning ? 'Scan in progress' : 'No results yet',
          message: scanning
              ? 'Results appear here as soon as the scan finishes.'
              : 'Scan your folders to find files and folders with identical contents.',
          action: scanning
              ? null
              : FilledButton.icon(
                  onPressed: widget.onStartScan,
                  icon: const Icon(Icons.search),
                  label: const Text('Start a scan'),
                ),
        ),
      );
    }
    _bind(results, state.generation);

    final summary = state.summary;
    final stats = state.stats!;
    final nothing =
        stats.duplicateGroups == 0 &&
        stats.folderGroups == 0 &&
        stats.emptyFolders == 0 &&
        stats.largeFiles == 0 &&
        stats.junkItems == 0 &&
        stats.photos == 0;
    if (nothing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: EmptyState(
          icon: Icons.celebration_outlined,
          title: 'No duplicates found',
          message:
              'Scanned ${plural(stats.filesSeen, 'file')} (${formatBytes(stats.bytesSeen)}) in '
              '${formatDuration(Duration(milliseconds: stats.elapsedMs))}. Every file is unique.',
          action: OutlinedButton(onPressed: widget.onStartScan, child: const Text('Scan other folders')),
        ),
      );
    }

    // Another page asked for a specific list.
    if (ref.watch(resultsTabRequestProvider) case final kind?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectSection(kind);
        ref.read(resultsTabRequestProvider.notifier).state = null;
      });
    }

    final needsAnalysis = _analysedKinds.contains(_kind) && !(summary?.photosAnalyzed ?? false);
    final sections = ListenableBuilder(
      listenable: _old!,
      builder: (context, _) {
        final all = _sectionsFor(state);
        return context.isExpanded
            ? _SectionsPanel(
                sections: all,
                selected: _section,
                onSelect: _selectSection,
                header: _Summary(state: state, large: true),
              )
            : _SectionChips(sections: all, selected: _section, onSelect: _selectSection);
      },
    );
    final current = _sectionsFor(state).firstWhere((s) => s.kind == _kind);
    final list = _ListPane(
      section: current,
      filters: _filtersFor(_kind),
      showKeys: !context.isCompact,
      child: needsAnalysis ? const PhotoAnalyzeCard() : _listBody(_kind, state),
    );
    final showDetail = !context.isCompact && !needsAnalysis;

    final Widget body;
    if (context.isExpanded) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 248, child: sections),
          VerticalDivider(width: Tokens.rule, thickness: Tokens.rule, color: context.ds.ink),
          Expanded(flex: 5, child: list),
          if (showDetail) ...[
            VerticalDivider(width: 1, thickness: 1, color: context.ds.hairline),
            Expanded(flex: 6, child: _detailPane(_kind)),
          ],
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Summary(state: state, large: false),
          sections,
          Expanded(
            child: showDetail
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: list),
                      VerticalDivider(width: 1, thickness: 1, color: context.ds.hairline),
                      Expanded(flex: 6, child: _detailPane(_kind)),
                    ],
                  )
                : list,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search by name or path', border: InputBorder.none),
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () => _setQuery(() => _search = v.trim()));
                },
              )
            : const Text('Results'),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              if (_searching) {
                _searchController.clear();
                _setQuery(() {
                  _search = '';
                  _searching = false;
                });
              } else {
                setState(() => _searching = true);
              }
            },
          ),
          _SortMenu(
            sort: _sort,
            descending: _descending,
            onChanged: (sort, desc) => _setQuery(() {
              _sort = sort;
              _descending = desc;
            }),
          ),
          _MoreMenu(
            results: results,
            onClear: () => _apply(
              (r) => r.clearSelection(kind: _kind),
              refresh: (_) => ref.read(resultsProvider.notifier).refresh(),
            ),
            onRescan: () async {
              try {
                await ref.read(scanProvider.notifier).start();
                widget.onStartScan();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Focus(focusNode: _listFocus, onKeyEvent: _onKey, child: body),
      // No selection bar for the media sections until the media is analysed.
      bottomNavigationBar: summary == null || needsAnalysis
          ? null
          : _SelectionBar(
              kind: _kind,
              summary: summary,
              onSmartSelect: switch (_kind) {
                ResultKind.emptyFolders => _selectAllEmpty,
                ResultKind.junk => _selectSafeJunk,
                ResultKind.similarPhotos => _keepBestPhotos,
                ResultKind.similarMedia => _keepBestMedia,
                _ => _smartSelect,
              },
              onClear: () => _apply(
                (r) => r.clearSelection(kind: _kind),
                refresh: (_) => ref.read(resultsProvider.notifier).refresh(),
              ),
              onAction: (action) => runAction(context, ref, kind: _kind, action: action),
            ),
    );
  }

  /// Filter chips shown above a section's list.
  Widget? _filtersFor(ResultKind kind) => switch (kind) {
    ResultKind.files when _categories.length > 1 => _CategoryChips(
      categories: _categories,
      selected: _category,
      onChanged: (c) => _setQuery(() => _category = c),
    ),
    ResultKind.largeFiles => _LargeFilesHeader(selected: _largeMin, onChanged: (b) => _setQuery(() => _largeMin = b)),
    ResultKind.oldFiles => _OldFilesHeader(
      days: _oldDays,
      scope: _oldScope,
      hasDownloads: ref.read(appPathsProvider).downloadDirs.isNotEmpty,
      onDays: (d) => _setQuery(() => _oldDays = d),
      onScope: (s) => _setQuery(() => _oldScope = s),
    ),
    ResultKind.junk => _JunkHeader(selected: _junkKind, onChanged: (k) => _setQuery(() => _junkKind = k)),
    ResultKind.photoIssues when ref.read(resultsProvider).summary?.photosAnalyzed ?? false => _PhotoIssueChips(
      selected: _photoIssueKind,
      onChanged: (k) => _setQuery(() => _photoIssueKind = k),
      onReanalyze: () => analyzePhotosFlow(context, ref),
    ),
    ResultKind.similarPhotos ||
    ResultKind.similarMedia when ref.read(resultsProvider).summary?.photosAnalyzed ?? false => Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => analyzePhotosFlow(context, ref),
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Analyse again'),
      ),
    ),
    _ => null,
  };

  String _emptyMessage(ResultKind kind) => switch (kind) {
    ResultKind.files =>
      _category != null || _search.isNotEmpty ? 'No groups match the filter' : 'No duplicate files left',
    ResultKind.folders => 'No duplicate folders',
    ResultKind.similarPhotos => 'No similar photos',
    ResultKind.photoIssues => 'No blurry or dark photos or screenshots',
    ResultKind.similarMedia => 'No songs or videos that sound the same',
    ResultKind.largeFiles => _largeMin > 0 ? 'No files this large' : 'No large files found',
    ResultKind.oldFiles => 'Nothing this old here',
    ResultKind.junk => _junkKind != null ? 'Nothing of this kind' : 'No junk found',
    ResultKind.emptyFolders => 'No empty folders',
  };

  Widget _listBody(ResultKind kind, ResultsState state) {
    final list = _listFor(kind)!;
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final total = list.total;
        if (list.error != null && total == null) {
          return EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load results',
            message: errorMessage(list.error!),
          );
        }
        if (total == null) return const SizedBox.shrink();
        if (total == 0) return EmptyState(icon: Icons.check, title: _emptyMessage(kind));
        final focus = _focusOf(kind).clamp(0, total - 1);
        return Scrollbar(
          controller: _scrollFor(kind),
          child: ListView.builder(
            controller: _scrollFor(kind),
            itemExtent: reviewRowExtent,
            itemCount: total,
            itemBuilder: (context, i) {
              final item = list.itemAt(i);
              if (item == null) return const _RowPlaceholder();
              return _row(kind, item, i, focused: !context.isCompact && i == focus, roots: state.roots);
            },
          ),
        );
      },
    );
  }

  Widget _row(ResultKind kind, Object? item, int pos, {required bool focused, required List<String> roots}) {
    void open() => _openRow(pos);
    return switch (item) {
      FileGroupDto g => fileGroupRow(context, g, focused: focused, onTap: open),
      FolderGroupDto g => folderGroupRow(context, g, focused: focused, onTap: open),
      SimilarGroupDto g => similarGroupRow(context, g, focused: focused, onTap: open),
      MediaGroupDto g => mediaGroupRow(context, g, focused: focused, onTap: open),
      PhotoDto p => photoIssueRow(context, p, roots, focused: focused, onTap: open, onSelect: _selectPhoto),
      JunkEntryDto j => junkRow(context, j, roots, focused: focused, onTap: open, onSelect: _selectJunk),
      FolderEntryDto f => emptyFolderRow(context, f, focused: focused, onTap: open, onSelect: _selectEmpty),
      FileEntryDto f => fileEntryRow(
        context,
        f,
        roots,
        focused: focused,
        onTap: open,
        onSelect: kind == ResultKind.oldFiles ? _selectOld : _selectLarge,
      ),
      _ => const _RowPlaceholder(),
    };
  }

  /// The preview pane for the focused row.
  Widget _detailPane(ResultKind kind) {
    final list = _listFor(kind)!;
    return ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final total = list.total;
        if (total == null || total == 0) return const SizedBox.shrink();
        return _detailAt(kind, _focusOf(kind).clamp(0, total - 1));
      },
    );
  }

  Widget _detailAt(ResultKind kind, int pos) {
    final item = _listFor(kind)?.itemAt(pos);
    if (item == null) return const SizedBox.shrink();
    return switch (item) {
      FileGroupDto g => FileGroupDetail(
        key: ValueKey('files-${g.index}'),
        groupIndex: g.index,
        apply: (call) => _apply(call, refresh: (r) => _refreshFileGroup(r, g.index)),
        onIgnoreGroup: () => ignoreGroup(context, ref, ResultKind.files, g.index),
        onIgnoreFolder: _ignoreFolder,
      ),
      FolderGroupDto g => FolderGroupDetail(
        key: ValueKey('folders-${g.index}'),
        groupIndex: g.index,
        apply: (call) => _apply(call, refresh: (r) => _refreshFolderGroup(r, g.index)),
        onIgnoreGroup: () => ignoreGroup(context, ref, ResultKind.folders, g.index),
        onIgnoreFolder: _ignoreFolder,
      ),
      SimilarGroupDto g => SimilarPhotosDetail(
        key: ValueKey('similar-${g.index}'),
        groupIndex: g.index,
        apply: (call) => _apply(call, refresh: (r) => _refreshSimilar(r, g.index)),
      ),
      MediaGroupDto g => MediaGroupDetail(
        key: ValueKey('media-${g.index}'),
        groupIndex: g.index,
        apply: (call) => _apply(call, refresh: (r) => _refreshMedia(r, g.index)),
      ),
      PhotoDto p => photoIssueDetail(context, p, onChanged: (v) => _selectPhoto(p.id, v)),
      JunkEntryDto j => junkDetail(context, j, onChanged: (v) => _selectJunk(j.id, v)),
      FolderEntryDto f => EmptyFolderDetail(key: ValueKey(f.id), folder: f, onChanged: (v) => _selectEmpty(f.id, v)),
      FileEntryDto f when kind == ResultKind.oldFiles => fileEntryDetail(
        f,
        kindLabel: 'Not changed for ${formatRelative(f.modifiedMs).replaceAll(' ago', '')}',
        onChanged: (v) => _selectOld(f.id, v),
      ),
      FileEntryDto f => fileEntryDetail(
        f,
        kindLabel: 'Large file · ${formatBytes(f.size)}',
        onChanged: (v) => _selectLarge(f.id, v),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _RowPlaceholder extends StatelessWidget {
  const _RowPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
    height: reviewRowExtent,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      border: Border(bottom: BorderSide(color: context.ds.hairline)),
    ),
  );
}

/// "30.9 MB can be freed" and what the scan covered.
class _Summary extends StatelessWidget {
  const _Summary({required this.state, required this.large});

  final ResultsState state;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    final summary = state.summary;
    final stats = state.stats!;
    final reclaimable = summary?.fileWasted ?? stats.wastedBytes;
    final groups = summary?.activeFileGroups ?? stats.duplicateGroups;
    final restored = state.restored ? state.finishedAt : null;
    return Padding(
      padding: large ? const EdgeInsets.fromLTRB(20, 20, 20, 16) : const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: formatBytes(reclaimable),
                  style: displayStyle(
                    large ? 44 : 30,
                    color: ds.ink,
                  ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                TextSpan(
                  text: large ? '\ncan be freed' : '  can be freed',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${plural(groups, 'duplicate group')} · ${formatCount(stats.filesSeen)} files scanned in '
            '${formatDuration(Duration(milliseconds: stats.elapsedMs))}',
            style: theme.textTheme.bodySmall,
          ),
          if (restored != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Saved results from ${formatRelative(restored.millisecondsSinceEpoch)}. '
                'Files changed since then are skipped when cleaning.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (stats.errors > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${plural(stats.errors, 'item')} could not be read — see ⋮ › Unreadable items.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// Wide screens: the summary and every section, grouped.
class _SectionsPanel extends StatelessWidget {
  const _SectionsPanel({required this.sections, required this.selected, required this.onSelect, required this.header});

  final List<_Section> sections;
  final ResultKind selected;
  final ValueChanged<ResultKind> onSelect;
  final Widget header;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<_Section>>{};
    for (final s in sections) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          header,
          for (final MapEntry(key: name, value: items) in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text(name.toUpperCase(), style: capsStyle(context.ds.muted)),
            ),
            for (final s in items)
              _SectionTile(section: s, selected: s.kind == selected, onTap: () => onSelect(s.kind)),
          ],
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section, required this.selected, required this.onTap});

  final _Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    final empty = section.count == 0;
    final fg = selected ? theme.colorScheme.surface : (empty ? ds.muted : ds.ink);
    return Material(
      key: ValueKey('section-${section.kind.name}'),
      color: selected ? ds.ink : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 9, 16, 9),
          child: Row(
            children: [
              Icon(section.icon, size: 20, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    section.count == null ? '–' : formatCount(section.count!),
                    key: ValueKey('count-${section.kind.name}'),
                    style: displayStyle(18, color: fg).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  if (section.bytes != null && section.bytes! > 0)
                    Text(
                      formatBytes(section.bytes!),
                      style: theme.textTheme.labelSmall?.copyWith(color: selected ? fg : ds.muted),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phones and medium widths: sections as a scrollable row of chips.
class _SectionChips extends StatelessWidget {
  const _SectionChips({required this.sections, required this.selected, required this.onSelect});

  final List<_Section> sections;
  final ResultKind selected;
  final ValueChanged<ResultKind> onSelect;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: ds.rule)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Row(
          spacing: 8,
          children: [
            for (final s in sections)
              if (s.count != 0 || s.kind == selected)
                ChoiceChip(
                  key: ValueKey('section-${s.kind.name}'),
                  showCheckmark: false,
                  selected: s.kind == selected,
                  onSelected: (_) => onSelect(s.kind),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(s.label),
                      const SizedBox(width: 8),
                      Text(
                        s.count == null ? '–' : formatCount(s.count!),
                        key: ValueKey('count-${s.kind.name}'),
                        style: TextStyle(fontWeight: FontWeight.w800, color: s.kind == selected ? surface : ds.accent),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The middle column: what this section is, its filters and its rows.
class _ListPane extends StatelessWidget {
  const _ListPane({required this.section, required this.child, required this.showKeys, this.filters});

  final _Section section;
  final Widget? filters;
  final Widget child;
  final bool showKeys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(section.label, style: displayStyle(context.isCompact ? 22 : 26, color: ds.ink)),
                  ),
                  if (showKeys) Text('↑ ↓ TO MOVE', style: capsStyle(ds.muted, size: 10)),
                ],
              ),
              const SizedBox(height: 4),
              Text(section.description, style: theme.textTheme.bodySmall),
              if (filters != null) ...[const SizedBox(height: 10), filters!],
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: ds.hairline),
        Expanded(child: child),
      ],
    );
  }
}

/// Full-screen preview on phones, with previous/next.
class _DetailPage extends StatefulWidget {
  const _DetailPage({
    required this.title,
    required this.total,
    required this.initial,
    required this.listenable,
    required this.builder,
    required this.onPosition,
  });

  final String title;
  final int Function() total;
  final int initial;
  final Listenable listenable;
  final Widget Function(int pos) builder;
  final ValueChanged<int> onPosition;

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  late int _pos = widget.initial;

  void _go(int delta) {
    final total = widget.total();
    if (total == 0) return;
    setState(() => _pos = (_pos + delta).clamp(0, total - 1));
    widget.onPosition(_pos);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        // Rebuild on any selection change.
        ref.watch(resultsProvider.select((r) => (r.generation, r.selectionVersion)));
        return ListenableBuilder(
          listenable: widget.listenable,
          builder: (context, _) {
            final total = widget.total();
            return Scaffold(
              appBar: AppBar(
                title: Text(widget.title),
                actions: [
                  if (total > 0) Center(child: Text('${_pos + 1} / $total', style: capsStyle(context.ds.muted))),
                  IconButton(
                    tooltip: 'Previous',
                    onPressed: _pos > 0 ? () => _go(-1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: _pos < total - 1 ? () => _go(1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              body: total == 0 ? const SizedBox.shrink() : widget.builder(_pos.clamp(0, total - 1)),
            );
          },
        );
      },
    );
  }
}

/// File-type filter for duplicate files.
class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.categories, required this.selected, required this.onChanged});

  final List<CategoryStat> categories;
  final Category? selected;
  final ValueChanged<Category?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          ChoiceChip(label: const Text('All types'), selected: selected == null, onSelected: (_) => onChanged(null)),
          for (final c in categories)
            ChoiceChip(
              avatar: Icon(categoryIcon(c.category), size: 18, color: categoryColor(c.category, theme.brightness)),
              label: Text('${categoryLabel(c.category)} · ${formatBytes(c.wasted)}'),
              selected: selected == c.category,
              onSelected: (on) => onChanged(on ? c.category : null),
            ),
        ],
      ),
    );
  }
}

/// Issue filter for photos to review.
class _PhotoIssueChips extends StatelessWidget {
  const _PhotoIssueChips({required this.selected, required this.onChanged, required this.onReanalyze});

  final PhotoIssueKind? selected;
  final ValueChanged<PhotoIssueKind?> onChanged;
  final VoidCallback onReanalyze;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          ChoiceChip(label: const Text('All'), selected: selected == null, onSelected: (_) => onChanged(null)),
          for (final k in PhotoIssueKind.values)
            ChoiceChip(
              avatar: Icon(photoIssueIcon(k), size: 18),
              label: Text(photoIssueLabel(k)),
              selected: selected == k,
              onSelected: (on) => onChanged(on ? k : null),
            ),
          IconButton(tooltip: 'Analyse again', onPressed: onReanalyze, icon: const Icon(Icons.refresh)),
        ],
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.descending, required this.onChanged});

  final SortBy sort;
  final bool descending;
  final void Function(SortBy, bool) onChanged;

  static const _labels = {
    SortBy.wasted: 'Reclaimable space',
    SortBy.size: 'File size',
    SortBy.count: 'Number of copies',
    SortBy.name: 'Name',
    SortBy.path: 'Location',
    SortBy.modified: 'Date modified',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: 'Sort',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v is SortBy) {
          // Sensible default direction per key.
          onChanged(v, v != SortBy.name && v != SortBy.path);
        } else {
          onChanged(sort, !descending);
        }
      },
      itemBuilder: (_) => [
        for (final e in _labels.entries)
          CheckedPopupMenuItem<Object>(value: e.key, checked: e.key == sort, child: Text(e.value)),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: 'direction',
          child: ListTile(
            leading: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
            title: Text(descending ? 'Descending' : 'Ascending'),
          ),
        ),
      ],
    );
  }
}

class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.results, required this.onClear, required this.onRescan});

  final ScanResults results;
  final VoidCallback onClear;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) {
        switch (v) {
          case 'clear':
            onClear();
          case 'issues':
            final issues = results.issues().map((i) => (i.path, i.message)).toList();
            showIssuesDialog(context, 'Unreadable items', issues);
          case 'rescan':
            onRescan();
          case 'export':
            exportReportFlow(context, results);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'clear',
          child: ListTile(leading: Icon(Icons.deselect), title: Text('Clear selection')),
        ),
        PopupMenuItem(
          value: 'export',
          child: ListTile(leading: Icon(Icons.ios_share), title: Text('Export report…')),
        ),
        PopupMenuItem(
          value: 'issues',
          child: ListTile(leading: Icon(Icons.report_outlined), title: Text('Unreadable items')),
        ),
        PopupMenuItem(
          value: 'rescan',
          child: ListTile(leading: Icon(Icons.refresh), title: Text('Scan again')),
        ),
      ],
    );
  }
}

class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({
    required this.kind,
    required this.summary,
    required this.onSmartSelect,
    required this.onClear,
    required this.onAction,
  });

  final ResultKind kind;
  final SelectionSummaryDto summary;
  final VoidCallback onSmartSelect;
  final VoidCallback onClear;
  final ValueChanged<ActionType> onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = selectedCount(kind, summary);
    final bytes = switch (kind) {
      ResultKind.files => summary.fileBytes,
      ResultKind.folders => summary.folderBytes,
      ResultKind.largeFiles => summary.largeFileBytes,
      ResultKind.oldFiles => summary.oldFileBytes,
      ResultKind.similarPhotos => summary.similarBytes,
      ResultKind.photoIssues => summary.photoIssueBytes,
      ResultKind.similarMedia => summary.mediaBytes,
      ResultKind.junk => summary.junkBytes,
      ResultKind.emptyFolders => 0,
    };
    final caps = platformCapabilities();
    final defaultAction = ref.watch(settingsProvider.select((s) => s.deleteAction));
    final trashLabel = caps.systemTrash
        ? (Platform.isWindows ? 'Move to Recycle Bin' : 'Move to Trash')
        : 'Move to Recovery Bin';

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: Border(top: context.ds.rule),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: count == 0
                ? Row(
                    key: const ValueKey('idle'),
                    children: [
                      Expanded(
                        child: Text(switch (kind) {
                          ResultKind.emptyFolders => 'Select empty folders to remove them.',
                          ResultKind.largeFiles ||
                          ResultKind.oldFiles => 'Tick files you no longer need. These are not duplicates.',
                          ResultKind.similarPhotos => 'Tick photos to remove, or keep only the best of each set.',
                          ResultKind.photoIssues => 'Tick photos you no longer need.',
                          ResultKind.similarMedia => 'Tick copies to remove, or keep only the best of each set.',
                          ResultKind.junk => 'Tick what to remove. System caches are always safe.',
                          _ => 'Tick copies to remove, or let Smart select choose.',
                        }, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                      if (kind != ResultKind.largeFiles &&
                          kind != ResultKind.oldFiles &&
                          kind != ResultKind.photoIssues)
                        FilledButton.tonalIcon(
                          onPressed: onSmartSelect,
                          icon: Icon(switch (kind) {
                            ResultKind.emptyFolders => Icons.select_all,
                            ResultKind.junk => Icons.verified_outlined,
                            ResultKind.similarPhotos || ResultKind.similarMedia => Icons.star_outline,
                            _ => Icons.auto_fix_high,
                          }),
                          label: Text(switch (kind) {
                            ResultKind.emptyFolders => 'Select all',
                            ResultKind.junk => 'Select safe',
                            ResultKind.similarPhotos || ResultKind.similarMedia => 'Keep best',
                            _ => 'Smart select',
                          }),
                        ),
                    ],
                  )
                : Row(
                    key: const ValueKey('active'),
                    children: [
                      IconButton(tooltip: 'Clear selection', onPressed: onClear, icon: const Icon(Icons.close)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${formatCount(count)} selected',
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (bytes > 0)
                              Text(
                                '${formatBytes(bytes)} selected',
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                      if (kind != ResultKind.emptyFolders && kind != ResultKind.junk && !context.isCompact) ...[
                        OutlinedButton.icon(
                          onPressed: () => onAction(ActionType.moveTo),
                          icon: const Icon(Icons.drive_file_move_outline),
                          label: const Text('Move'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      FilledButton.icon(
                        onPressed: () => onAction(defaultAction),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                      ),
                      PopupMenuButton<ActionType>(
                        tooltip: 'More actions',
                        onSelected: onAction,
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: ActionType.trash,
                            child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(trashLabel)),
                          ),
                          if (caps.systemTrash)
                            const PopupMenuItem(
                              value: ActionType.recoveryBin,
                              child: ListTile(
                                leading: Icon(Icons.restore_from_trash_outlined),
                                title: Text('Move to Recovery Bin'),
                              ),
                            ),
                          if (kind != ResultKind.emptyFolders && kind != ResultKind.junk)
                            const PopupMenuItem(
                              value: ActionType.moveTo,
                              child: ListTile(
                                leading: Icon(Icons.drive_file_move_outline),
                                title: Text('Move to folder…'),
                              ),
                            ),
                          if (kind == ResultKind.files && caps.hardlinks)
                            const PopupMenuItem(
                              value: ActionType.replaceWithHardlink,
                              child: ListTile(leading: Icon(Icons.link), title: Text('Replace with hard links')),
                            ),
                          if (kind == ResultKind.files && ref.watch(_clonesProvider))
                            const PopupMenuItem(
                              value: ActionType.replaceWithClone,
                              child: ListTile(
                                leading: Icon(Icons.copy_all),
                                title: Text('Replace with clones'),
                                subtitle: Text('Separate files that share their data'),
                              ),
                            ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: ActionType.deletePermanently,
                            child: ListTile(
                              leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
                              title: Text('Delete permanently', style: TextStyle(color: scheme.error)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Size threshold chips above the large-files list.
class _LargeFilesHeader extends StatelessWidget {
  const _LargeFilesHeader({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final t in _largeThresholds)
          ChoiceChip(label: Text(t.label), selected: selected == t.bytes, onSelected: (_) => onChanged(t.bytes)),
      ],
    );
  }
}

/// Junk kind chips above the junk list.
class _JunkHeader extends StatelessWidget {
  const _JunkHeader({required this.selected, required this.onChanged});

  final JunkKind? selected;
  final ValueChanged<JunkKind?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          ChoiceChip(label: const Text('All'), selected: selected == null, onSelected: (_) => onChanged(null)),
          for (final k in JunkKind.values)
            ChoiceChip(
              avatar: Icon(junkKindIcon(k), size: 18),
              label: Text(junkKindLabel(k)),
              selected: selected == k,
              onSelected: (on) => onChanged(on ? k : null),
            ),
        ],
      ),
    );
  }
}

/// Age and place chips above the old-files list.
class _OldFilesHeader extends StatelessWidget {
  const _OldFilesHeader({
    required this.days,
    required this.scope,
    required this.hasDownloads,
    required this.onDays,
    required this.onScope,
  });

  final int days;
  final _OldScope scope;
  final bool hasDownloads;
  final ValueChanged<int> onDays;
  final ValueChanged<_OldScope> onScope;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 8,
            children: [
              Text('Not changed for', style: small),
              for (final a in _oldAges)
                ChoiceChip(label: Text(a.label), selected: days == a.days, onSelected: (_) => onDays(a.days)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Everywhere'),
                selected: scope == _OldScope.everywhere,
                onSelected: (_) => onScope(_OldScope.everywhere),
              ),
              if (hasDownloads)
                ChoiceChip(
                  avatar: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Downloads'),
                  selected: scope == _OldScope.downloads,
                  onSelected: (_) => onScope(_OldScope.downloads),
                ),
              ChoiceChip(
                avatar: const Icon(Icons.install_desktop_outlined, size: 18),
                label: const Text('Installers'),
                selected: scope == _OldScope.installers,
                onSelected: (_) => onScope(_OldScope.installers),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
