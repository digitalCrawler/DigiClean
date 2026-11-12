import 'package:flutter/foundation.dart';

typedef PageFetcher<T> = Future<(int total, List<T> items)> Function(int offset, int limit);

/// Random-access lazy list backed by paged queries to the engine. Only the
/// pages that are scrolled into view are fetched, so result sets with
/// hundreds of thousands of groups stay responsive.
class PagedList<T> extends ChangeNotifier {
  PagedList(this._fetch, {this.pageSize = 40});

  final PageFetcher<T> _fetch;
  final int pageSize;

  final Map<int, List<T>> _pages = {};
  final Set<int> _loading = {};
  int? _total;
  Object? _error;
  int _epoch = 0;
  bool _disposed = false;

  /// `null` until the first page arrives.
  int? get total => _total;
  Object? get error => _error;
  bool get isLoading => _loading.isNotEmpty;

  /// Returns the item, or `null` while its page is loading.
  T? itemAt(int index) {
    final page = index ~/ pageSize;
    final items = _pages[page];
    if (items == null) {
      _load(page);
      return null;
    }
    final offset = index % pageSize;
    return offset < items.length ? items[offset] : null;
  }

  Future<void> _load(int page) async {
    if (!_loading.add(page)) return;
    final epoch = _epoch;
    try {
      final (total, items) = await _fetch(page * pageSize, pageSize);
      if (epoch != _epoch || _disposed) return;
      _total = total;
      _pages[page] = items;
      _error = null;
    } catch (e) {
      if (epoch == _epoch) _error = e;
    } finally {
      if (epoch == _epoch) _loading.remove(page);
      if (!_disposed) notifyListeners();
    }
  }

  /// Drops cached pages and reloads from the first page.
  Future<void> reset() {
    _epoch++;
    _pages.clear();
    _loading.clear();
    _error = null;
    return _load(0);
  }

  /// Replaces cached items matching [test] (after a selection change).
  void replaceWhere(bool Function(T item) test, T Function(T item) replacement) {
    var changed = false;
    for (final items in _pages.values) {
      for (var i = 0; i < items.length; i++) {
        if (test(items[i])) {
          items[i] = replacement(items[i]);
          changed = true;
        }
      }
    }
    if (changed) notifyListeners();
  }

  /// All currently cached items (used for "select visible").
  Iterable<T> get loadedItems => _pages.values.expand((p) => p);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
