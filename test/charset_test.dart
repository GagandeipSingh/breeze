// A Windows file's curly quotes and euro sign (bytes 0x80-0x9F) must read
// as themselves and survive a save, even once the user types something
// Windows-1252 cannot hold and the file has to become UTF-8.
import 'dart:convert';

import 'package:breeze/data/note_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // "It’s €5 – ok" in Windows-1252.
  final win = [
    0x49, 0x74, 0x92, 0x73, 0x20, 0x80, 0x35, 0x20, 0x96, 0x20, 0x6F, 0x6B, //
  ];

  test('a Windows-1252 file reads as its real characters', () {
    final (text, cs) = decodeText(win);
    expect(cs, 'windows-1252');
    expect(text, 'It’s €5 – ok');
  });

  test('saved unchanged, it keeps its exact bytes', () {
    final (text, cs) = decodeText(win);
    expect(encodeText(text, cs), win);
  });

  test('an emoji turns it into correct UTF-8, quotes intact', () {
    final (text, cs) = decodeText(win);
    final out = encodeText('$text \u{1F600}', cs);
    expect(utf8.decode(out), 'It’s €5 – ok \u{1F600}');
  });

  test('bytes Windows-1252 leaves undefined stay Latin-1, byte for byte', () {
    final odd = [0x41, 0x81, 0xE9];
    final (text, cs) = decodeText(odd);
    expect(cs, 'ISO-8859-1');
    expect(encodeText(text, cs), odd);
  });

  test('plain Latin-1 (no 0x80-0x9F bytes) is still Latin-1', () {
    final (text, cs) = decodeText([0x63, 0x61, 0x66, 0xE9]);
    expect(cs, 'ISO-8859-1');
    expect(text, 'café');
  });

  test('a UTF-8 byte-order mark survives a save', () {
    final bom = [0xEF, 0xBB, 0xBF, 0x41];
    final (text, cs) = decodeText(bom);
    expect(cs, 'UTF-8');
    expect(encodeText(text, cs), bom);
  });

  test('an odd-length "UTF-16" file keeps every byte', () {
    final odd = [0xFF, 0xFE, 0x41, 0x00, 0x42];
    final (text, cs) = decodeText(odd);
    expect(encodeText(text, cs), odd);
  });
}
