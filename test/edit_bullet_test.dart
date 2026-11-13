import 'package:breeze/ui/format_text.dart';
import 'package:breeze/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('editing draws a bullet as •, one character for one', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    const text = '- one\n  * two\n+ three\n1. four\n-not a bullet\na - b';
    final c = FormatController()
      ..formatting = true
      ..pal = Pal.test()
      ..text = text;
    final shown = c
        .buildTextSpan(
          context: ctx,
          style: const TextStyle(fontSize: 16),
          withComposing: false,
        )
        .toPlainText(includeSemanticsLabels: false);
    // Same length: every cursor position means the same character.
    expect(shown.length, text.length);
    expect(shown, '• one\n  • two\n• three\n1. four\n-not a bullet\na - b');
    // The text itself, which is saved, is untouched.
    expect(c.text, text);
  });
}
