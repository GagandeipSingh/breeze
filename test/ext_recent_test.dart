// Any file type, and the recent list.
import 'dart:io';

import 'package:breeze/data/note_store.dart';
import 'package:breeze/data/recent_files.dart';
import 'package:breeze/ui/ext_picker.dart';
import 'package:breeze/ui/new_file_sheet.dart' show mainCodeExts;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('typed extension', () {
    test('takes what a person types', () {
      expect(cleanExt('kt'), '.kt');
      expect(cleanExt('.RS'), '.rs');
      expect(cleanExt('  ..cpp '), '.cpp');
      expect(cleanExt('mp3'), '.mp3');
    });
    test('refuses what cannot be a file type', () {
      for (final bad in [
        '',
        '.',
        '123',
        'c++',
        'a b',
        'toolongext',
        'tar.gz',
      ]) {
        expect(cleanExt(bad), isNull, reason: bad);
      }
    });
    test('suggests by extension first, then by name', () {
      expect(extMatches('k').first.$1, '.kt');
      expect(extMatches('').first.$1, '.json');
      expect(extMatches('kotlin').map((m) => m.$1), contains('.kt'));
      expect(extMatches('').length, knownExts.length);
      expect(extMatches('zzz'), isEmpty);
    });
  });

  group('data or code chips', () {
    test('three common ones, the last used first when it is another', () {
      expect(mainCodeExts(null), ['.json', '.html', '.py']);
      expect(mainCodeExts('.html'), ['.json', '.html', '.py']);
      expect(mainCodeExts('.kt'), ['.kt', '.json', '.html']);
    });
  });

  group('saving with any type', () {
    late Directory base;
    late NoteStore store;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('breeze_ext');
      store = await NoteStore.openIn(base);
    });
    tearDown(() => base.delete(recursive: true));

    test('a chosen type is kept, known or not', () async {
      final a = await store.create(
        'Main.kt',
        content: 'fun main() {}',
        exact: true,
      );
      final b = await store.create('Notes.abc', content: 'x', exact: true);
      expect(a.fullName, 'Main.kt');
      expect(b.fullName, 'Notes.abc');
      expect(await b.file.readAsString(), 'x');
    });
    test('a typed title is still only a title', () async {
      final n = await store.create('Dr.Smith', content: 'x');
      expect(n.fullName, 'Dr.Smith.txt');
    });
    test('a received file keeps its own type', () async {
      expect((await store.openIncoming('main.kt', 'x')).fullName, 'main.kt');
      expect((await store.openIncoming('data.abc', 'y')).fullName, 'data.abc');
      expect(
        (await store.openIncoming('Dr.Smith', 'z')).fullName,
        'Dr.Smith.txt',
      );
      // The same file again opens the one already there.
      final again = await store.openIncoming('data.abc', 'y');
      expect(again.fullName, 'data.abc');
      expect(store.notes.where((n) => n.fullName.startsWith('data')).length, 1);
    });
  });

  group('recent files', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('newest first, one entry per file', () async {
      final r = await RecentFiles.load();
      await r.add('content://a', 'a.txt', at: DateTime(2026, 1, 1));
      await r.add('content://b', 'b.kt', at: DateTime(2026, 1, 2));
      await r.add('content://a', 'a.txt', at: DateTime(2026, 1, 3));
      expect(r.items.map((x) => x.uri), ['content://a', 'content://b']);
      final again = await RecentFiles.load();
      expect(again.items.map((x) => x.name), ['a.txt', 'b.kt']);
      expect(again.items.first.openedAt, DateTime(2026, 1, 3));
    });
    test('the oldest falls off past the limit, and is handed back', () async {
      final r = await RecentFiles.load();
      final dropped = <String>[];
      for (var i = 0; i < RecentFiles.max + 2; i++) {
        dropped.addAll(
          (await r.add('content://$i', '$i.txt')).map((x) => x.uri),
        );
      }
      expect(r.items.length, RecentFiles.max);
      expect(dropped, ['content://0', 'content://1']);
    });
    test('remove and clear', () async {
      final r = await RecentFiles.load();
      await r.add('content://a', 'a.txt');
      await r.add('content://b', 'b.txt');
      await r.remove('content://a');
      expect(r.items.map((x) => x.uri), ['content://b']);
      await r.clear();
      expect((await RecentFiles.load()).items, isEmpty);
    });
    test('a damaged list starts empty instead of breaking', () async {
      SharedPreferences.setMockInitialValues({RecentFiles.key: '{not json'});
      expect((await RecentFiles.load()).items, isEmpty);
      SharedPreferences.setMockInitialValues({
        RecentFiles.key:
            '[{"uri":1},{"uri":"content://x","name":"x.txt","at":5}]',
      });
      expect((await RecentFiles.load()).items.single.uri, 'content://x');
    });
  });
}
