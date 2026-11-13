// The toast's Undo restores what moveToTrash returned: the same name, the
// same text, and the pin, tags and lock it left with.
import 'dart:io';

import 'package:breeze/data/note_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('undo puts a trashed file back exactly as it was', () async {
    final base = await Directory.systemTemp.createTemp('breeze_undo');
    addTearDown(() => base.delete(recursive: true));
    final store = await NoteStore.openIn(base);
    await store.create('Plan.md', content: '# Plan\nstep one');
    var n = store.notes.single;
    await store.setPinned(n, true);
    n = store.notes.single;
    await store.setTags(n, ['work']);
    n = store.notes.single;
    await store.setLocked(n, true);
    n = store.notes.single;

    final t = await store.moveToTrash(n);
    expect(t, isNotNull);
    expect(store.notes, isEmpty);
    expect(await t!.file.exists(), isTrue);
    expect(t.originalName, 'Plan.md');

    await store.restore(t);
    final back = store.notes.single;
    expect(back.fullName, 'Plan.md');
    expect(await back.file.readAsString(), '# Plan\nstep one');
    expect(back.pinned, isTrue);
    expect(back.tags, ['work']);
    expect(back.locked, isTrue);
    expect(await store.trash(), isEmpty);
  });

  test('a file already gone has nothing to undo', () async {
    final base = await Directory.systemTemp.createTemp('breeze_undo2');
    addTearDown(() => base.delete(recursive: true));
    final store = await NoteStore.openIn(base);
    await store.create('Gone.txt', content: 'x');
    final n = store.notes.single;
    await n.file.delete();
    expect(await store.moveToTrash(n), isNull);
  });
}
