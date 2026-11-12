import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';

/// Top-level destinations of the app shell.
enum AppTab { storage, results, recovery, settings }

/// The shell's selected destination; pages switch it to link to each other.
final appTabProvider = StateProvider<AppTab>((ref) => AppTab.storage);

/// A results list to show next; the results page consumes it.
final resultsTabRequestProvider = StateProvider<ResultKind?>((ref) => null);

/// Opens the results on a given list (duplicates, large files, junk…).
void openResults(WidgetRef ref, [ResultKind? kind]) {
  if (kind != null) ref.read(resultsTabRequestProvider.notifier).state = kind;
  ref.read(appTabProvider.notifier).state = AppTab.results;
}
