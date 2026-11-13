import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:breeze/data/note_store.dart';
import 'package:breeze/logic/code_highlight.dart';
import 'package:breeze/logic/text_stats.dart';
import 'package:breeze/ui/format_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodings round-trip byte for byte', () {
    final cases = <String, List<int>>{
      'UTF-8': utf8.encode('café ✓ नमस्ते 😀\r\nline'),
      'ISO-8859-1': latin1.encode('café über ÿ\r\n'),
      'UTF-16LE': [0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE],
      'UTF-16BE': [0xFE, 0xFF, 0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x00],
    };
    cases.forEach((name, bytes) {
      test(name, () {
        final (text, cs) = decodeText(bytes);
        expect(cs, name);
        expect(encodeText(text, cs), bytes);
      });
    });

    test('Latin-1 text gaining an emoji is saved as UTF-8, not lost', () {
      final (text, cs) = decodeText(latin1.encode('café'));
      final out = encodeText('$text 😀', cs);
      expect(utf8.decode(out), 'café 😀');
    });

    test('binary bytes survive unchanged', () {
      final bytes = List<int>.generate(256, (i) => i);
      final (text, cs) = decodeText(bytes);
      expect(encodeText(text, cs), bytes);
    });
  });

  test(
    'editing a big file colours only near the cursor, spelling it exactly',
    () {
      final code = File('test/big_sample.c').readAsStringSync();
      final pieces = highlightCode(code, 'c')!;
      for (final at in [0, code.length ~/ 2, code.length]) {
        final span = codeSpan(pieces, const TextStyle(), false, around: at);
        final b = StringBuffer();
        span.visitChildren((s) {
          b.write((s as TextSpan).text ?? '');
          return true;
        });
        expect(b.toString(), code);
        expect(span.children!.length, lessThan(1500));
      }
      // Reading: the whole file coloured.
      expect(
        codeSpan(pieces, const TextStyle(), false).children!.length,
        greaterThan(5000),
      );
    },
  );

  test(
    'the colour worker drops stale editor jobs and still answers a PDF',
    () async {
      final w = CodeColourer.instance;
      final code = File('test/big_sample.c').readAsStringSync();
      final editor = [
        for (var i = 0; i < 6; i++)
          w.colour('$code//$i', 'c', latestOnly: true),
      ];
      final pdf = w.colour('int x = 1;', 'c');
      final got = await Future.wait(editor);
      // At most the one already running and the newest are coloured.
      expect(got.where((g) => g != null).length, lessThanOrEqualTo(2));
      expect(got.last, isNotNull);
      expect(await pdf, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('note names', () {
    late Directory base;
    late NoteStore store;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('breeze_names');
      store = await NoteStore.openIn(base);
    });
    tearDown(() => base.delete(recursive: true));

    test('a title past the 255-byte limit still saves, shortened', () async {
      final long = 'नमस्ते ' * 60; // ~1,100 bytes
      final n = await store.create(long, content: 'body');
      expect(utf8.encode(n.fullName).length, lessThanOrEqualTo(210));
      expect(n.fullName, endsWith('.txt'));
      expect(await n.file.readAsString(), 'body');
      // A second note with the same title is numbered, and still fits.
      final m = await store.create(long, content: 'two');
      expect(m.path, isNot(n.path));
      expect(utf8.encode(m.fullName).length, lessThan(255));
    });

    test('a dotted title is a title, not an extension', () async {
      final n = await store.create('Dr.Smith', content: 'a');
      expect(n.fullName, 'Dr.Smith.txt');
      expect(n.name, 'Dr.Smith');
      // Saving with the title unchanged keeps the file and its .txt.
      final saved = await store.save(n, 'b', newName: 'Dr.Smith');
      expect(saved.path, n.path);
      final renamed = await store.rename(saved, 'Dr.Smith');
      expect(renamed.path, n.path);
      // A real type typed on purpose still changes it.
      final md = await store.rename(renamed, 'Dr.Smith.md');
      expect(md.fullName, 'Dr.Smith.md');
    });

    test('opening the same file again reuses its copy', () async {
      final a = await store.openIncoming('settings.json', '{"a":1}');
      final b = await store.openIncoming('settings.json', '{"a":1}');
      expect(b.path, a.path);
      // Different text is a different file: a new copy.
      final c = await store.openIncoming('settings.json', '{"a":2}');
      expect(c.path, isNot(a.path));
      expect(c.fullName, 'settings 2.json');
      // And that one is reused too.
      final d = await store.openIncoming('settings.json', '{"a":2}');
      expect(d.path, c.path);
    });

    test('trashing a note already gone from disk is not an error', () async {
      final n = await store.create('Gone', content: 'x');
      await n.file.delete();
      await store.moveToTrash(n);
      expect(store.notes.where((e) => e.path == n.path), isEmpty);
    });

    test('a copy of a locked note is locked', () async {
      final n = await store.create('Secret', content: 'x');
      await store.setLocked(n, true);
      final locked = store.notes.firstWhere((e) => e.path == n.path);
      final c = await store.duplicate(locked);
      expect(c.locked, isTrue);
    });

    test('a save leaves no temporary file behind', () async {
      final n = await store.create('Plain', content: 'one');
      await store.save(n, 'two');
      expect(await n.file.readAsString(), 'two');
      final left = base
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('.saving'));
      expect(left, isEmpty);
    });
  });

  test('find offsets stay on the original text (Turkish dotted I)', () {
    const text = 'İstanbul and İzmir';
    for (final (_, b)
        in findRanges(text, 'stanbul') + findRanges(text, 'zmir')) {
      expect(b, lessThanOrEqualTo(text.length));
    }
    expect(findRanges(text, 'stanbul').map((r) => text.substring(r.$1, r.$2)), [
      'stanbul',
    ]);
    expect(findRanges(text, 'izmir').length, 1);
    expect(findRanges('Hello HELLO', 'hello').length, 2);
  });

  test('a huge file is cut into pieces that spell it exactly', () {
    final one = List.generate(60000, (i) => '{"id":$i,"e":"😀"},').join();
    final lines = List.generate(
      20000,
      (i) => 'line $i',
    ).join(String.fromCharCode(10));
    for (final text in [one, lines, 'x' * 9001, 'short']) {
      final parts = readChunks(text);
      final b = StringBuffer();
      var prev = 0;
      for (final (a, e) in parts) {
        expect(a, prev);
        expect(e - a, lessThanOrEqualTo(4000));
        expect(e, greaterThan(a));
        if (e < text.length) {
          final c = text.codeUnitAt(e - 1);
          expect(c >= 0xD800 && c <= 0xDBFF, isFalse); // emoji not split
        }
        b.write(text.substring(a, e));
        prev = e;
      }
      expect(b.toString(), text);
    }
  });

  test('editing pieces of a huge file keeps every other piece intact', () {
    final rnd = Random(7);
    var text = List.generate(30000, (i) => 'w$i 😀,').join();
    var chunks = readChunks(text);
    // The truth: each piece's text, edited directly.
    final pieces = [for (final (a, b) in chunks) text.substring(a, b)];
    const inserts = ['', 'x', 'ZZ', 'नमस्ते', '😀'];
    for (var step = 0; step < 3000; step++) {
      final i = rnd.nextInt(chunks.length);
      final old = pieces[i];
      final at = rnd.nextInt(old.length + 1);
      final cut = rnd.nextInt(4).clamp(0, old.length - at);
      final ins = inserts[rnd.nextInt(inserts.length)];
      final part = old.substring(0, at) + ins + old.substring(at + cut);
      pieces[i] = part;
      (text, chunks) = replaceChunk(text, chunks, i, part);
      if (step % 300 == 0 || step == 2999) {
        expect(text, pieces.join());
        for (var k = 0; k < chunks.length; k++) {
          expect(text.substring(chunks[k].$1, chunks[k].$2), pieces[k]);
        }
      }
    }
  });
}
