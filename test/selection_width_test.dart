import 'dart:ui' show BoxWidthStyle;
// Flutter's text fields default to BoxWidthStyle.max: a selection's box is
// stretched to the widest line of the text, so selecting up to the end of a
// short line lit the row to the edge of the screen. Read mode is tight, and
// so must every field be.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every text field draws its selection tight', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final s = f.readAsStringSync();
      for (final m in RegExp(r'\bTextField\(').allMatches(s)) {
        final head = s.substring(m.end, (m.end + 200).clamp(0, s.length));
        if (!head.contains('selectionWidthStyle: BoxWidthStyle.tight')) {
          missing.add(
            '${f.path}:${s.substring(0, m.start).split('\n').length}',
          );
        }
      }
    }
    expect(missing, isEmpty);
  });

  testWidgets('a selection ending a short line stops at its last letter', (
    t,
  ) async {
    final c = TextEditingController(
      text: 'short\na much longer line of text here',
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: TextField(
              selectionWidthStyle: BoxWidthStyle.tight,
              controller: c,
              maxLines: null,
            ),
          ),
        ),
      ),
    );
    final re = t
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final boxes = re.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    final long = re.getBoxesForSelection(
      TextSelection(baseOffset: 6, extentOffset: c.text.length),
    );
    final right = boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b);
    // "short" is far narrower than the long line below it.
    expect(right, lessThan(long.last.right / 2));
  });
}
