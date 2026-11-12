import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'compare_page.dart';
import 'export_report.dart';
import 'group_cards.dart';
import 'ignore_actions.dart';
import 'photo_cards.dart';
import 'smart_select_sheet.dart';

/// Copy-on-write clones are offered unless a scanned drive is known not to
/// support them (Windows tells; other systems are tried).
final _clonesProvider = Provider<bool>((ref) {
  final roots = ref.watch(resultsProvider.select((r) => r.roots));
  if (Platform.isAndroid || roots.isEmpty) return false;
  return roots.every((r) => cloneSupport(path: r) != false);
});

const _kinds = [
  ResultKind.files,
  ResultKind.folders,
  // The media tab shows similar photos, photo issues or similar audio and
  // video (see _mediaView).
  ResultKind.similarPhotos,
  ResultKind.largeFiles,
  ResultKind.oldFiles,
  ResultKind.junk,
  ResultKind.emptyFolders,
];

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

/// Size thresholds offered on the large-files tab.
const _largeThresholds = [
  (label: 'All', bytes: 0),
  (label: '≥ 10 MB', bytes: 10 << 20),
  (label: '≥ 100 MB', bytes: 100 << 20),
  (label: '≥ 1 GB', bytes: 1 << 30),
];

class ResultsPage extends ConsumerStatefulWidget {
  const ResultsPage({super.key, required this.onStartScan});

  final VoidCallback onStartScan;

  @override
  ConsumerState<ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends ConsumerState<ResultsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchController = TextEditingController();
  Timer? _debounce;

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
  _MediaView _mediaView = _MediaView.photos;
  PagedList<MediaGroupDto>? _mediaGroups;
  PhotoIssueKind? _photoIssueKind;
  List<CategoryStat> _categories = const [];
  int? _focusedFile;
  int? _focusedFolder;

  ResultKind get _kind {
    final kind = _kinds[_tabs.index];
    if (kind != ResultKind.similarPhotos) return kind;
    return switch (_mediaView) {
      _MediaView.photos => ResultKind.similarPhotos,
      _MediaView.issues => ResultKind.photoIssues,
      _MediaView.media => ResultKind.similarMedia,
    };
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _kinds.length, vsync: this)..addListener(_onTab);
  }

  void _onTab() {
    if (!_tabs.indexIsChanging) setState(() {});
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    _debounce?.cancel();
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
    _old = null;
    _similar?.dispose();
    _photoList?.dispose();
    _mediaGroups?.dispose();
    _mediaGroups = null;
    _similar = null;
    _photoList = null;
    _files = _folders = null;
    _empty = null;
    _large = null;
    _junk = null;
  }

  GroupQuery _query(int offset, int limit, {bool category = true}) => GroupQuery(
    offset: offset,
    limit: limit,
    sort: _sort,
    descending: _descending,
    category: category ? _category : null,
    search: _search.isEmpty ? null : _search,
  );

  /// (Re)creates paged lists for a new result set and reloads them when
  /// the results change.
  void _bind(ScanResults results, int generation) {
    if (!identical(results, _bound)) {
      _disposeLists();
      _bound = results;
      _focusedFile = _focusedFolder = null;
      _files = PagedList((o, l) async {
        final page = await results.fileGroups(query: _query(o, l));
        return (page.total, page.groups);
      });
      _folders = PagedList((o, l) async {
        final page = await results.folderGroups(query: _query(o, l, category: false));
        return (page.total, page.groups);
      });
      _large = PagedList((o, l) async {
        final q = _query(o, l, category: false);
        final page = await results.largeFiles(
          query: GroupQuery(
            offset: q.offset,
            limit: q.limit,
            // "Reclaimable" means "size" for single files.
            sort: q.sort == SortBy.wasted || q.sort == SortBy.count ? SortBy.size : q.sort,
            descending: q.descending,
            search: q.search,
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
        final q = _query(o, l, category: false);
        final page = await results.photoIssues(
          query: GroupQuery(
            offset: q.offset,
            limit: q.limit,
            sort: q.sort == SortBy.wasted || q.sort == SortBy.count ? SortBy.size : q.sort,
            descending: q.descending,
            search: q.search,
            photoIssue: _photoIssueKind,
          ),
        );
        return (page.total, page.photos);
      }, pageSize: 60);
      _old = PagedList((o, l) async {
        final q = _query(o, l, category: false);
        final paths = ref.read(appPathsProvider);
        final page = await results.oldFiles(
          query: GroupQuery(
            offset: q.offset,
            limit: q.limit,
            sort: q.sort == SortBy.wasted || q.sort == SortBy.count ? SortBy.size : q.sort,
            descending: q.descending,
            search: q.search,
            modifiedBeforeMs: DateTime.now().subtract(Duration(days: _oldDays)).millisecondsSinceEpoch,
            within: _oldScope == _OldScope.downloads ? paths.downloadDirs : null,
            extensions: _oldScope == _OldScope.installers ? installerExtensions : null,
          ),
        );
        return (page.total, page.files);
      }, pageSize: 60);
      _junk = PagedList((o, l) async {
        final q = _query(o, l, category: false);
        final page = await results.junk(
          query: GroupQuery(
            offset: q.offset,
            limit: q.limit,
            sort: q.sort == SortBy.wasted || q.sort == SortBy.count ? SortBy.size : q.sort,
            descending: q.descending,
            search: q.search,
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

  void _setQuery(VoidCallback change) {
    setState(change);
    _reload();
  }

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

  Future<void> _ignoreFolder(String folder) async {
    await ignoreFolder(context, ref, folder);
    // The open comparison may show copies that are now hidden.
    if (mounted) setState(() => _focusedFile = _focusedFolder = null);
  }

  void _openFileGroup(int index) {
    if (context.isExpanded) {
      setState(() => _focusedFile = index);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FileCompareView(groupIndex: index)));
    }
  }

  void _openFolderGroup(int index) {
    if (context.isExpanded) {
      setState(() => _focusedFolder = index);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FolderCompareView(groupIndex: index)));
    }
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
        final view = switch (kind) {
          ResultKind.similarPhotos => _MediaView.photos,
          ResultKind.photoIssues => _MediaView.issues,
          ResultKind.similarMedia => _MediaView.media,
          _ => null,
        };
        if (view != null) setState(() => _mediaView = view);
        final i = _kinds.indexOf(view != null ? ResultKind.similarPhotos : kind);
        if (i >= 0 && i != _tabs.index) _tabs.animateTo(i);
        ref.read(resultsTabRequestProvider.notifier).state = null;
      });
    }

    final counts = [
      summary?.activeFileGroups ?? stats.duplicateGroups,
      summary?.activeFolderGroups ?? stats.folderGroups,
      summary?.remainingLargeFiles ?? stats.largeFiles,
      summary?.remainingJunk ?? stats.junkItems,
      summary?.remainingEmptyFolders ?? stats.emptyFolders,
    ];

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search by name or path',
                  filled: false,
                  border: InputBorder.none,
                ),
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
      body: Column(
        children: [
          _SummaryHeader(
            stats: stats,
            summary: summary,
            reopenedFrom: state.restored ? state.finishedAt : null,
            categories: _categories,
            selected: _category,
            showCategories: _kind == ResultKind.files,
            onCategory: (c) => _setQuery(() => _category = c),
          ),
          TabBar(
            controller: _tabs,
            // Five tabs do not fit a phone; let them scroll there.
            isScrollable: context.isCompact,
            tabAlignment: context.isCompact ? TabAlignment.start : null,
            tabs: [
              Tab(text: 'Files (${formatCount(counts[0])})'),
              Tab(text: 'Folders (${formatCount(counts[1])})'),
              Tab(
                text: summary?.photosAnalyzed ?? false
                    ? 'Media (${formatCount(summary!.similarGroups + summary.remainingPhotoIssues + summary.mediaGroups)})'
                    : 'Media',
              ),
              Tab(text: '${context.isCompact ? 'Large' : 'Large files'} (${formatCount(counts[2])})'),
              Tab(
                child: ListenableBuilder(
                  listenable: _old!,
                  builder: (context, _) {
                    final n = _old!.total;
                    return Text('${context.isCompact ? 'Old' : 'Old files'}${n == null ? '' : ' (${formatCount(n)})'}');
                  },
                ),
              ),
              Tab(text: 'Junk (${formatCount(counts[3])})'),
              Tab(text: '${context.isCompact ? 'Empty' : 'Empty folders'} (${formatCount(counts[4])})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _withDetail(
                  list: _GroupList<FileGroupDto>(
                    list: _files!,
                    emptyMessage: _category != null || _search.isNotEmpty
                        ? 'No groups match the filter'
                        : 'No duplicate files left',
                    itemBuilder: (g) => FileGroupCard(
                      group: g,
                      focused: g.index == _focusedFile,
                      onSelect: (id, sel) => _apply(
                        (r) => r.setFileSelected(fileId: id, selected: sel),
                        refresh: (r) => _refreshFileGroup(r, g.index),
                      ),
                      onKeepOnly: (id) => _apply(
                        (r) => r.keepOnly(kind: ResultKind.files, groupIndex: g.index, keepId: id),
                        refresh: (r) => _refreshFileGroup(r, g.index),
                      ),
                      onOpenGroup: () => _openFileGroup(g.index),
                      onIgnoreGroup: () {
                        if (_focusedFile == g.index) setState(() => _focusedFile = null);
                        ignoreGroup(context, ref, ResultKind.files, g.index);
                      },
                      onIgnoreFolder: (folder) => _ignoreFolder(folder),
                    ),
                  ),
                  detail: _focusedFile == null
                      ? null
                      : FileCompareView(key: ValueKey(_focusedFile), groupIndex: _focusedFile!, embedded: true),
                  onClose: () => setState(() => _focusedFile = null),
                ),
                _withDetail(
                  list: _GroupList<FolderGroupDto>(
                    list: _folders!,
                    emptyMessage: 'No duplicate folders',
                    itemBuilder: (g) => FolderGroupCard(
                      group: g,
                      focused: g.index == _focusedFolder,
                      onSelect: (id, sel) => _apply(
                        (r) => r.setFolderSelected(folderId: id, selected: sel),
                        refresh: (r) => _refreshFolderGroup(r, g.index),
                      ),
                      onKeepOnly: (id) => _apply(
                        (r) => r.keepOnly(kind: ResultKind.folders, groupIndex: g.index, keepId: id),
                        refresh: (r) => _refreshFolderGroup(r, g.index),
                      ),
                      onOpenGroup: () => _openFolderGroup(g.index),
                      onIgnoreGroup: () {
                        if (_focusedFolder == g.index) setState(() => _focusedFolder = null);
                        ignoreGroup(context, ref, ResultKind.folders, g.index);
                      },
                      onIgnoreFolder: (folder) => _ignoreFolder(folder),
                    ),
                  ),
                  detail: _focusedFolder == null
                      ? null
                      : FolderCompareView(key: ValueKey(_focusedFolder), groupIndex: _focusedFolder!, embedded: true),
                  onClose: () => setState(() => _focusedFolder = null),
                ),
                if (!(summary?.photosAnalyzed ?? false))
                  const PhotoAnalyzeCard()
                else if (_mediaView == _MediaView.photos)
                  _GroupList<SimilarGroupDto>(
                    list: _similar!,
                    emptyMessage: 'No similar photos',
                    header: _MediaHeader(
                      view: _mediaView,
                      issueKind: _photoIssueKind,
                      onView: (v) => setState(() => _mediaView = v),
                      onIssueKind: (k) => _setQuery(() => _photoIssueKind = k),
                      onReanalyze: () => analyzePhotosFlow(context, ref),
                    ),
                    itemBuilder: (g) => SimilarGroupCard(
                      group: g,
                      onSelect: (id, sel) => _apply(
                        (r) => r.setSimilarSelected(fileId: id, selected: sel),
                        refresh: (r) {
                          final updated = r.similarGroup(index: g.index);
                          if (updated != null) _similar?.replaceWhere((x) => x.index == g.index, (_) => updated);
                        },
                      ),
                    ),
                  )
                else if (_mediaView == _MediaView.issues)
                  _GroupList<PhotoDto>(
                    list: _photoList!,
                    emptyMessage: 'No blurry or dark photos or screenshots',
                    header: _MediaHeader(
                      view: _mediaView,
                      issueKind: _photoIssueKind,
                      onView: (v) => setState(() => _mediaView = v),
                      onIssueKind: (k) => _setQuery(() => _photoIssueKind = k),
                      onReanalyze: () => analyzePhotosFlow(context, ref),
                    ),
                    itemBuilder: (p) => PhotoIssueTile(
                      photo: p,
                      roots: state.roots,
                      onSelect: (id, sel) => _apply(
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
                      ),
                    ),
                  )
                else
                  _GroupList<MediaGroupDto>(
                    list: _mediaGroups!,
                    emptyMessage: 'No songs or videos that sound the same',
                    header: _MediaHeader(
                      view: _mediaView,
                      issueKind: _photoIssueKind,
                      onView: (v) => setState(() => _mediaView = v),
                      onIssueKind: (k) => _setQuery(() => _photoIssueKind = k),
                      onReanalyze: () => analyzePhotosFlow(context, ref),
                    ),
                    itemBuilder: (g) => MediaGroupCard(
                      group: g,
                      onSelect: (id, sel) => _apply(
                        (r) => r.setMediaSelected(fileId: id, selected: sel),
                        refresh: (r) {
                          final updated = r.mediaGroup(index: g.index);
                          if (updated != null) _mediaGroups?.replaceWhere((x) => x.index == g.index, (_) => updated);
                        },
                      ),
                    ),
                  ),
                _GroupList<FileEntryDto>(
                  list: _large!,
                  emptyMessage: _largeMin > 0 ? 'No files this large' : 'No large files found',
                  header: _LargeFilesHeader(
                    selected: _largeMin,
                    onChanged: (bytes) => _setQuery(() => _largeMin = bytes),
                  ),
                  itemBuilder: (f) => LargeFileTile(
                    file: f,
                    roots: state.roots,
                    onSelect: (id, sel) => _apply(
                      (r) => r.setLargeFileSelected(fileId: id, selected: sel),
                      refresh: (_) => _large?.replaceWhere(
                        (x) => x.id == id,
                        (x) => FileEntryDto(
                          id: x.id,
                          path: x.path,
                          name: x.name,
                          parent: x.parent,
                          size: x.size,
                          modifiedMs: x.modifiedMs,
                          createdMs: x.createdMs,
                          hidden: x.hidden,
                          selected: sel,
                        ),
                      ),
                    ),
                  ),
                ),
                _GroupList<FileEntryDto>(
                  list: _old!,
                  emptyMessage: 'Nothing this old here',
                  header: _OldFilesHeader(
                    days: _oldDays,
                    scope: _oldScope,
                    hasDownloads: ref.read(appPathsProvider).downloadDirs.isNotEmpty,
                    onDays: (d) => _setQuery(() => _oldDays = d),
                    onScope: (s) => _setQuery(() => _oldScope = s),
                  ),
                  itemBuilder: (f) => LargeFileTile(
                    file: f,
                    roots: state.roots,
                    onSelect: (id, sel) => _apply(
                      (r) => r.setOldFileSelected(fileId: id, selected: sel),
                      refresh: (_) {
                        FileEntryDto flip(FileEntryDto x) => FileEntryDto(
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
                        _old?.replaceWhere((x) => x.id == id, flip);
                      },
                    ),
                  ),
                ),
                _GroupList<JunkEntryDto>(
                  list: _junk!,
                  emptyMessage: _junkKind != null ? 'Nothing of this kind' : 'No junk found',
                  header: _JunkHeader(selected: _junkKind, onChanged: (k) => _setQuery(() => _junkKind = k)),
                  itemBuilder: (j) => JunkTile(
                    item: j,
                    roots: state.roots,
                    onSelect: (id, sel) => _apply(
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
                    ),
                  ),
                ),
                _GroupList<FolderEntryDto>(
                  list: _empty!,
                  emptyMessage: 'No empty folders',
                  header: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _selectAllEmpty,
                      icon: const Icon(Icons.select_all),
                      label: const Text('Select all'),
                    ),
                  ),
                  itemBuilder: (f) => EmptyFolderTile(
                    folder: f,
                    onSelect: (id, sel) => _apply(
                      (r) => r.setFolderSelected(folderId: id, selected: sel),
                      refresh: (r) => _empty?.replaceWhere(
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
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      // No selection bar on the photos tab until the photos are analysed.
      bottomNavigationBar:
          summary == null || (_kinds[_tabs.index] == ResultKind.similarPhotos && !summary.photosAnalyzed)
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

  /// On wide screens an opened group is shown next to the list; otherwise
  /// the list uses the full width.
  Widget _withDetail({required Widget list, required Widget? detail, required VoidCallback onClose}) {
    if (!context.isExpanded || detail == null) return list;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(flex: 5, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 4,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('Group details', style: theme.textTheme.labelLarge)),
                    IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: onClose),
                  ],
                ),
              ),
              Expanded(child: detail),
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupList<T> extends StatelessWidget {
  const _GroupList({required this.list, required this.itemBuilder, required this.emptyMessage, this.header});

  final PagedList<T> list;
  final Widget Function(T item) itemBuilder;
  final String emptyMessage;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
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
        if (total == null) return const Center(child: CircularProgressIndicator());
        if (total == 0) {
          final empty = EmptyState(icon: Icons.check_circle_outline, title: emptyMessage);
          if (header == null) return empty;
          // Keep filters reachable when they match nothing.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(context.isCompact ? 12 : 20, 12, context.isCompact ? 12 : 20, 0),
                child: header,
              ),
              Expanded(child: empty),
            ],
          );
        }
        final offset = header == null ? 0 : 1;
        return Scrollbar(
          child: ListView.separated(
            padding: EdgeInsets.fromLTRB(context.isCompact ? 12 : 20, 12, context.isCompact ? 12 : 20, 24),
            itemCount: total + offset,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (i < offset) return header!;
              final item = list.itemAt(i - offset);
              if (item == null) return const _Placeholder();
              return itemBuilder(item);
            },
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        height: 120,
        child: Center(
          child: LinearProgressIndicator(minHeight: 2, color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.stats,
    required this.summary,
    required this.categories,
    required this.selected,
    required this.showCategories,
    required this.onCategory,
    this.reopenedFrom,
  });

  /// When the reopened (saved) results were scanned; `null` for a new scan.
  final DateTime? reopenedFrom;
  final ScanStatsDto stats;
  final SelectionSummaryDto? summary;
  final List<CategoryStat> categories;
  final Category? selected;
  final bool showCategories;
  final ValueChanged<Category?> onCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reclaimable = summary?.fileWasted ?? stats.wastedBytes;
    final groups = summary?.activeFileGroups ?? stats.duplicateGroups;
    final compact = context.isCompact;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 0, compact ? 16 : 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: formatBytes(reclaimable),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                TextSpan(text: '  can be freed', style: theme.textTheme.titleSmall),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${plural(groups, 'duplicate group')} · '
            '${formatCount(stats.filesSeen)} files scanned in ${formatDuration(Duration(milliseconds: stats.elapsedMs))}',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (showCategories && categories.length > 1) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All types'),
                    selected: selected == null,
                    onSelected: (_) => onCategory(null),
                  ),
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        avatar: Icon(
                          categoryIcon(c.category),
                          size: 18,
                          color: categoryColor(c.category, theme.brightness),
                        ),
                        label: Text('${categoryLabel(c.category)} · ${formatBytes(c.wasted)}'),
                        selected: selected == c.category,
                        onSelected: (on) => onCategory(on ? c.category : null),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (reopenedFrom != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.history, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Saved results from ${formatRelative(reopenedFrom!.millisecondsSinceEpoch)}. '
                      'Files changed since then are skipped when cleaning.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          if (stats.errors > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${plural(stats.errors, 'item')} could not be read (permissions or in use) — see ⋮ › Unreadable items.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
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
      color: scheme.surfaceContainer,
      elevation: 3,
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

enum _MediaView { photos, issues, media }

/// Switches the media tab between similar photos, photos to review and
/// similar songs and videos.
class _MediaHeader extends StatelessWidget {
  const _MediaHeader({
    required this.view,
    required this.issueKind,
    required this.onView,
    required this.onIssueKind,
    required this.onReanalyze,
  });

  final _MediaView view;
  final PhotoIssueKind? issueKind;
  final ValueChanged<_MediaView> onView;
  final ValueChanged<PhotoIssueKind?> onIssueKind;
  final VoidCallback onReanalyze;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<_MediaView>(
                  segments: const [
                    ButtonSegment(value: _MediaView.photos, label: Text('Photos')),
                    ButtonSegment(value: _MediaView.issues, label: Text('To review')),
                    ButtonSegment(value: _MediaView.media, label: Text('Music & video')),
                  ],
                  selected: {view},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => onView(s.first),
                ),
              ),
            ),
            IconButton(tooltip: 'Analyse again', onPressed: onReanalyze, icon: const Icon(Icons.refresh)),
          ],
        ),
        if (view == _MediaView.issues) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 8,
              children: [
                ChoiceChip(label: const Text('All'), selected: issueKind == null, onSelected: (_) => onIssueKind(null)),
                for (final k in PhotoIssueKind.values)
                  ChoiceChip(
                    avatar: Icon(photoIssueIcon(k), size: 18),
                    label: Text(photoIssueLabel(k)),
                    selected: issueKind == k,
                    onSelected: (on) => onIssueKind(on ? k : null),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
