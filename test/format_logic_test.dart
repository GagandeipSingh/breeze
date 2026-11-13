import 'package:breeze/logic/code_highlight.dart';
import 'package:breeze/logic/markdown_lite.dart';
import 'package:breeze/ui/format_text.dart';
import 'package:breeze/ui/kit.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue sel(String t, int a, [int? b]) => TextEditingValue(
  text: t,
  selection: TextSelection(baseOffset: a, extentOffset: b ?? a),
);

/// Types Enter at [at] the way the keyboard does, through the formatter.
TextEditingValue enter(String t, int at) {
  final old = sel(t, at);
  final nw = sel(t.replaceRange(at, at, '\n'), at + 1);
  return ListContinuation(() => true).formatEditUpdate(old, nw);
}

void main() {
  group('bold', () {
    test('tapped twice on a selection turns it on, then off', () {
      final v0 = sel('hello world', 0, 5);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.bold);
      expect(v1.text, '**hello** world');
      final v2 = toggleInline(v1, parseMd(v1.text), Md.bold);
      expect(v2.text, 'hello world');
      expect(v2.selection.textInside(v2.text), 'hello');
    });

    test('the bar shows bold on right after bolding', () {
      final v0 = sel('hello world', 6, 11);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.bold);
      expect(
        parseMd(
          v1.text,
        ).regionAround(Md.bold, v1.selection.start, v1.selection.end),
        isNotNull,
      );
    });

    test('a bullet stays a bullet when its line is bolded', () {
      final v0 = sel('- milk\n- eggs', 0, 13);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.bold);
      expect(v1.text, '- **milk**\n- **eggs**');
      expect(
        parseMd(v1.text).lines.every((l) => l.kind == MdLineKind.bullet),
        isTrue,
      );
    });

    test('a second tap on an empty pair removes it', () {
      final v1 = toggleInline(sel('ab', 1), parseMd('ab'), Md.bold);
      expect(v1.text, 'a****b');
      final v2 = toggleInline(v1, parseMd(v1.text), Md.bold);
      expect(v2.text, 'ab');
      expect(v2.selection.baseOffset, 1);
    });

    test('bold inside bold-italic leaves the italic', () {
      final v0 = sel('***hi***', 3, 5);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.bold);
      expect(v1.text, '*hi*');
    });
  });

  group('underline', () {
    test('on, then off, around the words (markers differ: <u> and </u>)', () {
      final v0 = sel('hello world', 6, 11);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.underline);
      expect(v1.text, 'hello <u>world</u>');
      expect(v1.selection.textInside(v1.text), 'world');
      final d = parseMd(v1.text);
      expect(
        d.regionAround(Md.underline, v1.selection.start, v1.selection.end),
        isNotNull,
      );
      final v2 = toggleInline(v1, d, Md.underline);
      expect(v2.text, 'hello world');
      expect(v2.selection.textInside(v2.text), 'world');
    });

    test('the tags are hidden when reading, the words underlined', () {
      final d = parseMd('a <u>b c</u> d');
      final shown = d.runs.where((r) => r.flags & Md.marker == 0);
      expect(
        shown.map((r) => d.text.substring(r.start, r.end)).join(),
        'a b c d',
      );
      expect(
        shown.any(
          (r) =>
              r.flags & Md.underline != 0 &&
              d.text.substring(r.start, r.end) == 'b c',
        ),
        isTrue,
      );
    });

    test(
      'a cursor gets an empty pair to type into, and a second tap removes it',
      () {
        final v1 = toggleInline(sel('ab', 1), parseMd('ab'), Md.underline);
        expect(v1.text, 'a<u></u>b');
        expect(v1.selection.baseOffset, 4);
        final v2 = toggleInline(v1, parseMd(v1.text), Md.underline);
        expect(v2.text, 'ab');
        expect(v2.selection.baseOffset, 1);
      },
    );

    test('two lines each get their own pair, and bold inside still works', () {
      final v0 = sel('- one\n- two', 0, 11);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.underline);
      expect(v1.text, '- <u>one</u>\n- <u>two</u>');
      // Inside the first and last markers, so the bar shows it on.
      expect(v1.selection.textInside(v1.text), 'one</u>\n- <u>two');
      final d = parseMd('<u>**x**</u>');
      final x = d.runs.firstWhere(
        (r) => d.text.substring(r.start, r.end) == 'x',
      );
      expect(x.flags & (Md.bold | Md.underline), Md.bold | Md.underline);
    });

    test('a second tap on two underlined lines takes it off both', () {
      for (final kind in [Md.underline, Md.bold]) {
        final v0 = sel('- one\n- two', 0, 11);
        final v1 = toggleInline(v0, parseMd(v0.text), kind);
        final v2 = toggleInline(v1, parseMd(v1.text), kind);
        expect(v2.text, '- one\n- two', reason: '$kind');
        expect(v2.selection.textInside(v2.text), 'one\n- two');
      }
    });

    test('a line already on is not wrapped twice when others are not', () {
      final v0 = sel('**x**\ny', 0, 7);
      expect(toggleInline(v0, parseMd(v0.text), Md.bold).text, '**x**\n**y**');
      final w0 = sel('**ab** cd', 0, 9);
      expect(toggleInline(w0, parseMd(w0.text), Md.bold).text, '**ab cd**');
    });

    String shown(String t) {
      final d = parseMd(t);
      return d.runs
          .where((r) => r.flags & Md.marker == 0)
          .map((r) => t.substring(r.start, r.end))
          .join();
    }

    test('stars that are not formatting stay as written', () {
      for (final t in [
        'x ** 2 + y ** 2',
        'a ** b',
        'src/**/*.dart',
        '****',
        '~~~~~~',
        '2**3 and a*b',
      ]) {
        expect(shown(t), t, reason: t);
      }
    });

    test('bold and italic side by side both read', () {
      expect(shown('***x** y*'), 'x y');
      expect(shown('***x* y**'), 'x y');
      expect(shown('*y **x***'), 'y x');
      expect(shown('**y *x***'), 'y x');
      expect(shown('**bold **'), 'bold ');
    });

    test('italic over bold and the rest gives one italic, all hidden', () {
      final v0 = sel('**x** y', 0, 7);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.italic);
      expect(shown(v1.text), 'x y');
      final w0 = sel('*x* y', 0, 5);
      final w1 = toggleInline(w0, parseMd(w0.text), Md.bold);
      expect(shown(w1.text), 'x y');
    });

    test('bolding half of bold words takes them all in', () {
      final v0 = sel('**ab** cd', 3, 9);
      expect(toggleInline(v0, parseMd(v0.text), Md.bold).text, '**ab cd**');
    });

    test('several lines wrapped light the bar', () {
      final v0 = sel('one\ntwo', 0, 7);
      final v1 = toggleInline(v0, parseMd(v0.text), Md.bold);
      final d = parseMd(v1.text);
      expect(
        d.regionAround(Md.bold, v1.selection.start, v1.selection.start),
        isNotNull,
      );
    });

    test(
      'read view lists each underline at the right place in the shown text',
      () {
        final lines = <Underline>[];
        final span = mdReadSpan(
          parseMd('- **x** <u>हिंदी रेखा 😀</u> y'),
          const TextStyle(fontSize: 16),
          Pal.test(),
          underlines: lines,
        );
        final shown = span.toPlainText();
        expect(shown, '• x हिंदी रेखा 😀 y');
        expect(lines, hasLength(1));
        expect(
          shown.substring(lines.single.start, lines.single.end),
          'हिंदी रेखा 😀',
        );
      },
    );

    test('clear formatting drops the tags', () {
      final v0 = sel('a <u>b</u>', 0, 10);
      expect(clearFormatting(v0, parseMd(v0.text)).text, 'a b');
    });
  });

  group('backspace over hidden markers', () {
    TextEditingValue back(String t, int at) {
      final old = sel(t, at);
      final nw = sel(t.replaceRange(at - 1, at, ''), at - 1);
      final c = FormatController()..formatting = true;
      c.value = old;
      return HiddenMarkerBackspace(c).formatEditUpdate(old, nw);
    }

    test('deleting the only letter of bold leaves no ** behind', () {
      expect(back('a **b** c', 7).text, 'a  c');
    });

    test('a word delete keeps the markers and drops the letters', () {
      final t = 'hello **world**';
      final old = sel(t, t.length);
      final nw = sel('hello **', 8);
      final c = FormatController()..formatting = true;
      c.value = old;
      final v = HiddenMarkerBackspace(c).formatEditUpdate(old, nw);
      expect(v.text, 'hello ');
    });

    test('after bold deletes the last letter, keeps it bold', () {
      final v = back('**bold** x', 8);
      expect(v.text, '**bol** x');
      expect(v.selection.baseOffset, 7);
    });

    test('after underline with emoji deletes the emoji whole', () {
      expect(back('<u>hi 😀</u>', 12).text, '<u>hi </u>');
    });

    test('at the start of a heading takes the heading off', () {
      final v = back('a\n# Title', 4);
      expect(v.text, 'a\nTitle');
      expect(v.selection.baseOffset, 2);
    });

    test('ordinary letters delete as usual', () {
      expect(back('hello', 5).text, 'hell');
    });

    test('nothing visible before: nothing deleted', () {
      expect(back('**x**', 2).text, '**x**');
    });
  });

  group('typing after formatted words', () {
    TextEditingValue type(String t, int at, String ins, {int? stop}) {
      final c = FormatController()..formatting = true;
      c.value = sel(t, at);
      c.stopAt = stop;
      final nw = sel(t.replaceRange(at, at, ins), at + ins.length);
      return ContinueFormatting(c).formatEditUpdate(c.value, nw);
    }

    test('carries bold on', () {
      expect(type('**bold**', 8, 'x').text, '**boldx**');
    });

    test('carries underline and bold inside it on', () {
      expect(type('<u>**hi**</u>', 13, '!').text, '<u>**hi!**</u>');
    });

    test('not after B was tapped there, not onto a new line, not a link', () {
      expect(type('**bold**', 8, 'x', stop: 8).text, '**bold**x');
      expect(type('**bold**', 8, '\n').text, '**bold**\n');
      expect(type('[a](b)', 6, 'x').text, '[a](b)x');
    });
  });

  group('B with just a cursor', () {
    String shown(String t) => parseMd(t).runs
        .where((r) => r.flags & Md.marker == 0)
        .map((r) => t.substring(r.start, r.end))
        .join();

    FormatController ctl(String t, int at) => FormatController()
      ..formatting = true
      ..value = sel(t, at);

    /// Taps [kind] then types [ins], the way the field does it.
    String tapType(FormatController c, int kind, String ins) {
      c.value = inlineAtCursor(c, c.value, c.doc, kind);
      final at = c.selection.baseOffset;
      final old = c.value;
      final nw = sel(old.text.replaceRange(at, at, ins), at + ins.length);
      c.value = ContinueFormatting(c).formatEditUpdate(old, nw);
      return c.text;
    }

    test('nothing goes into the text until a letter is typed', () {
      final c = ctl('hello ', 6);
      c.value = inlineAtCursor(c, c.value, c.doc, Md.bold);
      expect(c.text, 'hello ');
      expect(formatStateOf(c).inline & Md.bold, Md.bold);
      c.selection = const TextSelection.collapsed(offset: 0);
      expect(c.pendingAt, -1);
      expect(c.text, 'hello ');
    });

    test('then the letter comes out bold', () {
      final c = ctl('hello ', 6);
      expect(tapType(c, Md.bold, 'x'), 'hello **x**');
      // and the next letters carry it on
      final old = c.value;
      final at = old.selection.baseOffset;
      c.value = ContinueFormatting(
        c,
      ).formatEditUpdate(old, sel(old.text.replaceRange(at, at, 'y'), at + 1));
      expect(shown(c.text), 'hello xy');
      expect(c.text, 'hello **xy**');
    });

    test('a space first goes in plain, the word after it bold', () {
      final c = ctl('hi', 2);
      expect(tapType(c, Md.bold, ' '), 'hi ');
      final old = c.value;
      c.value = ContinueFormatting(c).formatEditUpdate(old, sel('hi x', 4));
      expect(c.text, 'hi **x**');
    });

    test('Enter after tapping B: nothing left behind', () {
      final c = ctl('hi', 2);
      expect(tapType(c, Md.bold, '\n'), 'hi\n');
    });

    test('at the end of underlined bold: bold stops, underline goes on', () {
      final c = ctl('**<u>both</u>**', 9); // after "both", before </u>
      final text = tapType(c, Md.bold, 'z');
      expect(shown(text), 'bothz');
      final d = parseMd(text);
      final z = d.runs.firstWhere(
        (r) => d.text.substring(r.start, r.end) == 'z',
      );
      expect(z.flags & Md.underline, Md.underline);
      expect(z.flags & Md.bold, 0);
    });

    test('at the end of bold inside underline: bold stops there', () {
      final c = ctl('<u>**both**</u>', 9); // after "both", before **
      final text = tapType(c, Md.bold, 'z');
      final d = parseMd(text);
      final z = d.runs.firstWhere(
        (r) => d.text.substring(r.start, r.end) == 'z',
      );
      expect(z.flags & (Md.bold | Md.underline), Md.underline);
    });

    test('italic right after bold: bold and italic, no stray stars', () {
      final c = ctl('**a**', 5);
      final text = tapType(c, Md.italic, 'b');
      expect(shown(text), 'ab');
      final d = parseMd(text);
      final b = d.runs.firstWhere(
        (r) => d.text.substring(r.start, r.end) == 'b',
      );
      expect(b.flags & (Md.bold | Md.italic), Md.bold | Md.italic);
    });

    test('B, B again: back to how it was, nothing written', () {
      final c = ctl('**a**', 5);
      c.value = inlineAtCursor(c, c.value, c.doc, Md.bold);
      expect(c.stopAt, 5);
      expect(formatStateOf(c).inline & Md.bold, 0);
      c.value = inlineAtCursor(c, c.value, c.doc, Md.bold);
      expect(formatStateOf(c).inline & Md.bold, Md.bold);
      expect(c.text, '**a**');
    });
  });

  group('stars and pairs read right', () {
    String shown(String t) => parseMd(t).runs
        .where((r) => r.flags & Md.marker == 0)
        .map((r) => t.substring(r.start, r.end))
        .join();

    test('stars in sums, words and notes stay right', () {
      expect(shown('2*3*4'), '2*3*4');
      expect(shown('snake_case_name'), 'snake_case_name');
      expect(shown('an _italic_ word'), 'an italic word');
      // The extra star has no partner and shows; "this" stays italic.
      expect(shown('***Note:** see *this*'), '*Note: see this');
    });

    test('bold off a whole bold-italic line keeps the italic', () {
      final v0 = sel('***x***', 0, 7);
      final v = toggleInline(v0, parseMd(v0.text), Md.bold);
      expect(v.text, '*x*');
      expect(shown(v.text), 'x');
    });

    test('italic written by the bar reads in Notepad and Markdown apps', () {
      final v0 = sel('hello', 0, 5);
      expect(toggleInline(v0, parseMd(v0.text), Md.italic).text, '*hello*');
      // <i> from an older build still reads
      expect(shown('<i>x</i>'), 'x');
    });

    test('backspace emptying bold keeps it for the next letters', () {
      final c = FormatController()
        ..formatting = true
        ..value = sel('a **b**', 5);
      final v = HiddenMarkerBackspace(
        c,
      ).formatEditUpdate(c.value, sel('a ****', 4));
      expect(v.text, 'a ');
      expect(c.pendingKinds & Md.bold, Md.bold);
    });
  });

  group('Enter in a list', () {
    test('continues a bullet', () {
      final v = enter('- milk', 6);
      expect(v.text, '- milk\n- ');
      expect(v.selection.baseOffset, 9);
    });

    test('counts a numbered list on', () {
      expect(enter('9. nine', 7).text, '9. nine\n10. ');
    });

    test('keeps the indent of a nested item', () {
      expect(enter('  - sub', 7).text, '  - sub\n  - ');
    });

    test('on an empty item ends the list', () {
      final v = enter('- milk\n- ', 9);
      expect(v.text, '- milk\n');
      expect(v.selection.baseOffset, 7);
    });

    test('before the text of an item keeps the bullet on both halves', () {
      // Cursor right after "- ": the item is split, not ended.
      final v = enter('- milk', 2);
      expect(v.text, '- \n- milk');
    });

    test('a plain line is left alone', () {
      expect(enter('hello', 5).text, 'hello\n');
    });
  });

  group('line kinds', () {
    test('heading cycles none -> H1 -> H2 -> H3 -> none', () {
      var v = sel('Title', 2);
      for (final want in ['# Title', '## Title', '### Title', 'Title']) {
        final doc = parseMd(v.text);
        v = setLineKind(
          v,
          doc,
          nextHeading(doc.lineAt(v.selection.start).kind),
        );
        expect(v.text, want);
      }
    });

    test('selecting two whole lines does not touch the third', () {
      final t = 'a\nb\nc';
      final v = setLineKind(sel(t, 0, 4), parseMd(t), MdLineKind.bullet);
      expect(v.text, '- a\n- b\nc');
    });

    test('bullets off again keep the text', () {
      final t = '- a\n- b';
      final v = setLineKind(sel(t, 0, t.length), parseMd(t), MdLineKind.bullet);
      expect(v.text, 'a\nb');
    });
  });

  test('a link label loses [ ] and the address its ( ) and spaces', () {
    final v = insertLink(sel('see [this] doc', 0, 14), 'https://a.b/x (1)');
    expect(v.text, '[see this doc](https://a.b/x%20%281%29)');
    expect(parseMd(v.text).regions.any((r) => r.kind & Md.link != 0), isTrue);
  });

  test('clear formatting leaves only the words', () {
    final t = '# **Big** *news*';
    final v = clearFormatting(sel(t, 3), parseMd(t));
    expect(v.text, 'Big news');
  });

  group('code colours', () {
    for (final (ext, code) in [
      ('.c', 'int main(void) {\n  printf("hi\\n");\n  return 0;\n}\n'),
      ('.cpp', '#include <vector>\nstd::vector<int> v{1,2};\n'),
      ('.dart', 'void main() {\n  final x = "a\$b";\n}\n'),
      ('.kt', 'fun main() { val s = "x"; println(s) }\n'),
      ('.java', 'class A { public static void main(String[] a) {} }\n'),
      ('.cs', 'class A { static void Main() { var s = @"x"; } }\n'),
      ('.rs', 'fn main() { let s: &str = "x"; println!("{}", s); }\n'),
      ('.py', 'def f(x):\n    return x  # done\n'),
      ('.json', '{"a": [1, true, null]}\n'),
    ]) {
      test('$ext is coloured and spells the file exactly', () {
        final lang = codeLanguageFor(ext);
        expect(lang, isNotNull);
        final pieces = highlightCode(code, lang!);
        expect(pieces, isNotNull);
        expect(pieces!.map((p) => p.$1).join(), code);
        expect(pieces.any((p) => p.$2 != null), isTrue);
      });
    }

    test('plain text files are never coloured', () {
      for (final ext in ['', '.txt', '.md', '.log', '.csv']) {
        expect(codeLanguageFor(ext), isNull, reason: ext);
      }
    });
  });

  group('backslash escapes (Word and RTF notes)', () {
    String shown(String t, {bool escapes = true}) {
      final d = parseMd(t, escapes: escapes);
      return [
        for (final r in d.runs)
          if (r.flags & (Md.marker | Md.listMarker) == 0)
            t.substring(r.start, r.end),
      ].join();
    }

    test('an escaped character is plain text, its backslash hidden', () {
      expect(shown(r'\*\*not bold\*\*'), '**not bold**');
      expect(shown(r'\- not a list'), '- not a list');
      expect(shown(r'3\. x'), '3. x');
      expect(shown(r'\# x'), '# x');
      expect(shown(r'a \ b'), r'a \ b');
      expect(
        parseMd(r'\- x', escapes: true).lines.single.kind,
        MdLineKind.plain,
      );
      expect(parseMd(r'\*\*x\*\*', escapes: true).regions, isEmpty);
      // Formatting around an escape still works.
      final d = parseMd(r'**a\*b**', escapes: true);
      expect(d.regions.single.kind, Md.bold);
      expect(shown(r'**a\*b**'), 'a*b');
    });

    test('a backslash before a letter, or in a plain note, stays', () {
      expect(shown(r'C:\temp'), r'C:\temp');
      expect(shown(r'\server\*x', escapes: false), r'\server\*x');
      expect(parseMd(r'\- x').lines.single.kind, MdLineKind.plain);
    });

    test('Clear formatting keeps escapes', () {
      final t = r'\*\*x\*\* and **y**';
      final v = clearFormatting(sel(t, 3), parseMd(t, escapes: true));
      expect(v.text, r'\*\*x\*\* and y');
    });

    test('backspace on an escaped character takes its backslash too', () {
      const t = r'a \*b';
      final old = sel(t, 4);
      final nw = sel(r'a \b', 3);
      final c = FormatController()
        ..formatting = true
        ..escapes = true;
      c.value = old;
      expect(HiddenMarkerBackspace(c).formatEditUpdate(old, nw).text, 'a b');
    });
  });
}
