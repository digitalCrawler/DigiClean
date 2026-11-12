import 'package:digiclean/src/core/path_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shows only the differing part of Windows paths', () {
    final l = GroupLocations.of([
      r'C:\Users\me\Pictures\Desktop\Old stuff',
      r'C:\Users\me\Pictures\Documents\Invoices',
      r'C:\Users\me\Pictures\Downloads',
    ]);
    expect(l.prefixPath, r'C:\Users\me\Pictures');
    expect(l.prefixLabel, 'Pictures');
    expect(l.segmentsOf(0), ['Desktop', 'Old stuff']);
    expect(l.segmentsOf(2), ['Downloads']);
  });

  test('a copy directly in the shared folder keeps that folder name', () {
    final l = GroupLocations.of(['/home/me/photos', '/home/me/photos/backup']);
    expect(l.segmentsOf(0), ['photos']);
    expect(l.segmentsOf(1), ['photos', 'backup']);
    expect(l.prefixPath, '/home/me');
  });

  test('copies in the same folder keep the folder name', () {
    final l = GroupLocations.of(['/data/a', '/data/a']);
    expect(l.segmentsOf(0), ['a']);
    expect(l.prefixPath, '/data');
  });

  test('different drives share no prefix', () {
    final l = GroupLocations.of([r'C:\x', r'D:\x']);
    expect(l.prefix, isEmpty);
    expect(joinSegments(l.segmentsOf(0)), 'C: › x');
  });

  test('drive letters compare case-insensitively', () {
    final l = GroupLocations.of([r'c:\Data\a', r'C:\Data\b']);
    expect(l.segmentsOf(1), ['b']);
  });

  test('paths wrap only at separators', () {
    const zw = '\u200B';
    expect(softWrapPath(r'C:\a\b'), 'C:\\${zw}a\\${zw}b');
    expect(softWrapPath('/x/y'), '/${zw}x/${zw}y');
  });

  test('locations are shown from the scanned folder down', () {
    expect(segmentsUnderRoot(r'C:\Users\me\Home\Videos\Family', [r'C:\Users\me\Home']), ['Home', 'Videos', 'Family']);
    expect(segmentsUnderRoot(r'c:\users\me\home', [r'C:\Users\me\Home']), ['Home']);
    expect(segmentsUnderRoot('/a/b/c/d/e', ['/x']), ['c', 'd', 'e']);
  });
}
