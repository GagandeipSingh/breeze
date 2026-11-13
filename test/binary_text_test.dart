// Breeze opens anything; a binary file must be seen as one so it is never
// saved back, and text in any language must never be mistaken for one.
import 'dart:convert';

import 'package:breeze/logic/binary_text.dart';
import 'package:breeze/logic/list_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text in any language is text', () {
    for (final t in [
      '',
      'Hello world\nsecond line\twith a tab\r\n',
      'नमस्ते दोस्त, कैसे हो?',
      'مرحبا بالعالم',
      '你好世界 😀 👨‍👩‍👧',
      'Ünïcödé façade café',
      '\u001b[31mred log line\u001b[0m\n' * 20,
      'page one\fpage two',
      'fun main() {\n  println("hi")\n}\n',
    ]) {
      expect(looksBinary(t), isFalse, reason: t);
    }
  });

  test('a binary file read as text is binary', () {
    // A PNG's opening bytes, as Breeze reads a non-UTF-8 file (one
    // character per byte).
    final png = latin1.decode([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, //
      0x49, 0x48, 0x44, 0x52, 0, 0, 1, 0, 0, 0, 1, 0, 8, 6, 0, 0, 0,
    ]);
    expect(looksBinary(png), isTrue);
    // No NUL, but full of control bytes.
    final noisy = latin1.decode(List.generate(400, (i) => (i * 37) % 256 | 1));
    expect(looksBinary(noisy), isTrue);
  });

  test('the home list says Binary file, not strange characters', () {
    final zip = latin1.decode([0x50, 0x4B, 3, 4, 20, 0, 0, 0, 8, 0]);
    expect(previewText(zip, '.zip', 'archive'), 'Binary file');
    expect(previewText('plain words', '.abc', 'x'), 'plain words');
  });

  test('a binary file shows dots for bytes no font can draw', () {
    expect(binaryForDisplay('a\u0000b\u0001\n\tc\u0085�'), 'a·b·\n\tc··');
    expect(binaryForDisplay('héllo नमस्ते'), 'héllo नमस्ते');
  });
}
