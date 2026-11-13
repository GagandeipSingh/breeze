import 'dart:io';

import 'package:breeze/data/note_store.dart';
import 'package:breeze/data/samples.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory base;
  setUp(() async {
    base = await Directory.systemTemp.createTemp('breeze_samples');
  });
  tearDown(() => base.delete(recursive: true));

  test('a fresh install starts with every sample, Welcome pinned', () async {
    final store = await NoteStore.openIn(base, samples: true);
    final names = store.notes.map((n) => n.fullName).toSet();
    expect(names, {for (final s in sampleFiles) s.$1});
    final welcome = store.notes.firstWhere((n) => n.fullName == sampleWelcome);
    expect(welcome.pinned, isTrue);
    // Each opens as written, Word and RTF formatted and editable.
    for (final n in store.notes) {
      final t = await store.readText(n);
      expect(t.text.trim(), isNotEmpty, reason: n.fullName);
      final want = sampleFiles.firstWhere((s) => s.$1 == n.fullName).$2;
      expect(t.text, want, reason: n.fullName);
    }
  });

  test('deleted samples never come back; a used folder gets none', () async {
    var store = await NoteStore.openIn(base, samples: true);
    for (final n in [...store.notes]) {
      await store.deletePermanently(n);
    }
    store = await NoteStore.openIn(base, samples: true);
    expect(store.notes, isEmpty);

    final other = await Directory.systemTemp.createTemp('breeze_used');
    try {
      final first = await NoteStore.openIn(other);
      await first.create('Mine.txt', content: 'x');
      final again = await NoteStore.openIn(other, samples: true);
      expect(again.notes.map((n) => n.fullName), ['Mine.txt']);
    } finally {
      await other.delete(recursive: true);
    }
  });
}
