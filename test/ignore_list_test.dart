import 'package:digiclean/src/rust/api/types.dart';
import 'package:digiclean/src/state/ignore_list.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

IgnoredGroup group(String digest, {ResultKind kind = ResultKind.files}) => IgnoredGroup(
  kind: kind,
  algorithm: HashAlgo.blake3,
  digest: digest,
  name: 'beach.jpg',
  path: '/home/me/Pictures/beach.jpg',
  copies: 3,
  size: 120000,
  addedMs: 1,
);

void main() {
  test('the ignore list is saved, newest first, without duplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);

    final first = open();
    final list = first.read(ignoreListProvider.notifier);
    list.add(group('aa'));
    list.add(group('bb', kind: ResultKind.folders));
    list.add(group('aa'));
    expect(first.read(ignoreListProvider).map((g) => g.digest), ['aa', 'bb']);
    first.dispose();

    final reopened = open();
    addTearDown(reopened.dispose);
    final saved = reopened.read(ignoreListProvider);
    expect(saved.map((g) => g.id), ['files:blake3:aa', 'folders:blake3:bb']);
    expect(saved.first.copies, 3);
    expect(saved.first.key.kind, ResultKind.files);
    reopened.read(ignoreListProvider.notifier).remove(saved.first);
    expect(reopened.read(ignoreListProvider).single.kind, ResultKind.folders);
  });

  test('a damaged ignore list is treated as empty', () async {
    SharedPreferences.setMockInitialValues({'ignored.v1': '{not json'});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    expect(c.read(ignoreListProvider), isEmpty);
  });
}
