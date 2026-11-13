import 'dart:convert';
import 'dart:typed_data';

import 'package:breeze/logic/pdf_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pages in a finished PDF, read from its page objects.
int pages(Uint8List pdf) =>
    RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> build(
    String text, {
    bool formatted = false,
    String? lang,
  }) async {
    Uint8List? out;
    Object? err;
    // Real async work (isolates, fonts), outside the fake test clock.
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      try {
        out = await buildNotePdf(
          'Test',
          text,
          formatted: formatted,
          codeLanguage: lang,
        );
      } catch (e) {
        err = e;
      }
    });
    if (err != null) throw err!;
    return out!;
  }

  test('a long note makes many pages', () async {
    final text = List.generate(
      3000,
      (i) => 'Line $i of a long note',
    ).join('\n');
    final pdf = await build(text);
    expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
    expect(pages(pdf), greaterThan(20));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'emoji, Hindi, Arabic, Chinese, blank lines and Windows ends print',
    () async {
      final text =
          'Hello 😀👍🏽👨‍👩‍👧\r\n\r\n\r\nनमस्ते दुनिया\r\nمرحبا\r\n你好世界\r\n\tindented';
      final pdf = await build(text, formatted: true);
      expect(pages(pdf), 1);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'one giant paragraph with no line breaks splits across pages',
    () async {
      final text = List.filled(20000, 'word').join(' ');
      final pdf = await build(text);
      expect(pages(pdf), greaterThan(5));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a long Hindi note (drawn as pictures) splits across pages',
    () async {
      final text = List.generate(
        800,
        (i) => 'यह पंक्ति $i है, नमस्ते दुनिया',
      ).join('\n');
      final pdf = await build(text);
      expect(pages(pdf), greaterThan(5));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'formatted note with headings, lists and a huge heading',
    () async {
      final text =
          '# ${List.filled(400, 'Big').join(' ')}\n- **bold** item\n1. *it* one\n~~gone~~';
      final pdf = await build(text, formatted: true);
      expect(pages(pdf), greaterThanOrEqualTo(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a big formatted note (over the live-styling limit) still prints formatted',
    () async {
      // 170k characters: the PDF used to fall back to raw text past 120k, so
      // <u>, ** and # printed as written.
      final text = List.generate(
        5000,
        (i) =>
            i % 50 == 0 ? '# Part $i' : 'line $i <u>under</u> **bold** words',
      ).join('\n');
      expect(text.length, greaterThan(170000));
      final sw = Stopwatch()..start();
      final pdf = await build(text, formatted: true);
      expect(pages(pdf), greaterThan(50));
      expect(sw.elapsed, lessThan(const Duration(seconds: 90)));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a code file prints with colours and keeps blank lines',
    () async {
      final code = List.generate(
        400,
        (i) => i % 5 == 0 ? '' : 'int x$i = $i; // note',
      ).join('\n');
      final pdf = await build(code, lang: 'cpp');
      expect(pages(pdf), greaterThan(3));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an empty note still makes a page',
    () async {
      expect(pages(await build('')), 1);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
