import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:breeze/data/note_store.dart';
import 'package:breeze/logic/docx.dart';
import 'package:breeze/logic/rtf.dart' show mdToModel;
import 'package:flutter_test/flutter_test.dart';

List<int> _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

bool _same(String a, String b) {
  final x = mdToModel(a), y = mdToModel(b);
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (!x[i].sameAs(y[i])) return false;
  }
  return true;
}

/// [docx] with one part removed (as an app that drops it would save it).
List<int> _without(List<int> docx, String part) {
  final a = ZipDecoder().decodeBytes(docx);
  final out = Archive();
  for (final f in a.files) {
    if (f.name == part) continue;
    out.addFile(ArchiveFile(f.name, f.content.length, f.content));
  }
  return ZipEncoder().encode(out);
}

/// [docx] with [part] replaced by [text].
List<int> _with(List<int> docx, String part, String text) {
  final a = ZipDecoder().decodeBytes(docx);
  final out = Archive();
  var found = false;
  for (final f in a.files) {
    found |= f.name == part;
    final data = f.name == part ? utf8.encode(text) : f.content;
    out.addFile(ArchiveFile(f.name, data.length, data));
  }
  if (!found) {
    final data = utf8.encode(text);
    out.addFile(ArchiveFile(part, data.length, data));
  }
  return ZipEncoder().encode(out);
}

String _part(List<int> docx, String part) => utf8.decode(
  ZipDecoder()
      .decodeBytes(docx)
      .files
      .firstWhere((f) => f.name == part)
      .content,
);

/// A minimal Word document whose body is [body].
List<int> _doc(String body, {String numbering = '', String styles = ''}) {
  final base = writeDocx('x');
  var out = _with(
    base,
    'word/document.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<w:body>$body</w:body></w:document>',
  );
  out = _without(out, 'docProps/custom.xml');
  if (numbering.isNotEmpty) out = _with(out, 'word/numbering.xml', numbering);
  if (styles.isNotEmpty) out = _with(out, 'word/styles.xml', styles);
  return out;
}

const _w =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

void main() {
  group('files made by Word', () {
    test('formatting Breeze keeps is read and editable', () {
      final r = readDocx(_fixture('word_keep.docx'));
      expect(r.unsupported, isEmpty);
      expect(r.native, isFalse);
      final lines = r.markdown.split('\n');
      expect(lines[0], startsWith('# Title '));
      expect(lines[1], '## Sub heading');
      expect(
        _same(
          lines[2],
          'Plain then **bold** *italic* <u>under line</u> ~~strike~~ and '
          '***both***.',
        ),
        isTrue,
        reason: lines[2],
      );
      expect(lines.sublist(3, 6), ['- Bullet one', '- Bullet two', '- Nested']);
      expect(lines[6], 'Between');
      expect(lines.sublist(7, 10), ['1. First', '2. Second', '3. Third']);
      expect(lines[10], 'See [Breeze site](https://example.com/a?b=1) now.');
      expect(lines[11], contains('café'));
    });

    test('what Breeze cannot keep is named, and it is not edited', () {
      final r = readDocx(_fixture('word_lossy.docx'));
      expect(r.editable, isFalse);
      expect(
        r.unsupported,
        containsAll(['colours', 'alignment', 'fonts', 'tables']),
      );
    });

    test('Hindi, Russian and Greek beside English: no false alarms', () {
      final r = readDocx(_fixture('word_scripts.docx'));
      expect(r.unsupported, isEmpty);
      expect(r.markdown, contains('Привет αβγ done.'));
      expect(r.markdown, contains('क्या'));
    });

    test('Breeze\'s file saved again by Word reads back as the note', () {
      final r = readDocx(_fixture('word_resaved.docx'));
      expect(r.unsupported, isEmpty);
      // Word wrote it last, so its look will become Breeze's: told first.
      expect(r.native, isFalse);
      const note =
          '# Title\n\nHello **bold** *it* <u>under</u> ~~gone~~ '
          '[link](https://a.com/x?a=1&b=2)\n- one\n  - nested\n- two\n'
          '1. first\n2. second\n5. fifth\n   1. sub\n\n## Two\n### Three\n'
          '\tTabbed — क्या 😀';
      expect(_same(r.markdown, note), isTrue, reason: r.markdown);
    });
  });

  group('Breeze writes, and reads back the same', () {
    const samples = [
      '',
      'one line',
      'a\n',
      '\n\n\n',
      '# H1\n## H2\n### H3',
      '**b** *i* <u>u</u> ~~s~~ ***bi*** [link](https://x.com/a?b=1&c="d")',
      '- a\n  - b\n    - c\n- d',
      '1. a\n2. b\n5. c\n   1. d\n   2. e\n3. f',
      '3. starts at three\n4. four\n\ntext\n5. five\n1. restart',
      '- bullet\n1. num\n- bullet\n2. num',
      '**# not a heading** ~~- not a list~~ *1. not numbered*',
      '\tTab and  two spaces — हिंदी 😀 café €5 <&> "q"',
    ];
    for (final md in samples) {
      test(jsonEncode(md), () {
        final out = writeDocx(md);
        expect(looksLikeDocx(out), isTrue);
        final r = readDocx(out);
        // The same note (spelled as Breeze writes it: *i*, %22...).
        expect(_same(r.markdown, md), isTrue, reason: r.markdown);
        expect(r.unsupported, isEmpty);
        expect(r.native, isTrue);
        // As an app that drops Breeze's copy of the text would leave it:
        // the document alone reads as the same note.
        final f = readDocx(_without(out, 'docProps/custom.xml'));
        expect(f.unsupported, isEmpty);
        expect(_same(f.markdown, md), isTrue, reason: f.markdown);
      });
    }

    test('numbers Word would count differently start a new list', () {
      final out = writeDocx('1. a\n2. b\n5. c\n   1. d\n6. e\n1. f');
      final num = _part(out, 'word/numbering.xml');
      // a, b in one list; c (5) starts one; e (6) continues it; f restarts.
      expect(RegExp('<w:num ').allMatches(num).length, 1 + 3);
      final f = readDocx(_without(out, 'docProps/custom.xml'));
      expect(f.markdown, '1. a\n2. b\n5. c\n  1. d\n6. e\n1. f');
    });

    test('the document says it is Breeze\'s, with real Word styles', () {
      final out = writeDocx('# T\n- x\n[l](https://a.b)');
      final doc = _part(out, 'word/document.xml');
      expect(doc, contains('<w:pStyle w:val="Heading1"/>'));
      expect(doc, contains('<w:numPr>'));
      expect(doc, contains('<w:hyperlink r:id='));
      expect(_part(out, 'docProps/app.xml'), contains('Breeze'));
    });

    test('a character Word cannot hold stops the save', () {
      expect(() => writeDocx('a\u0001b'), throwsStateError);
      // In a link the address is cleaned; the file must still open.
      final out = writeDocx('see [l](http://a${String.fromCharCode(1)}b) ok');
      expect(readDocx(out).editable, isTrue);
      expect(
        () => writeDocx('a${String.fromCharCode(0xD800)}b'),
        throwsStateError,
      );
    });

    test('3000 random notes all save and read back', () {
      final rnd = Random(11);
      final bits = [
        'a',
        'word',
        ' ',
        '  ',
        '**',
        '*',
        '_',
        '~~',
        '<u>',
        '</u>',
        '<i>',
        '</i>',
        '[',
        ']',
        '(',
        ')',
        '[t](http://e.com/p?a=1&b=2)',
        '#',
        '# ',
        '- ',
        '1. ',
        '7. ',
        '\t',
        'हिंदी',
        '😀',
        'é',
        '&',
        '<',
        '>',
        '"',
        '\\',
        String.fromCharCode(0xA0),
        String.fromCharCode(0x200D),
        '\n',
        '\n',
      ];
      var refused = 0;
      for (var n = 0; n < 3000; n++) {
        final sb = StringBuffer();
        final len = rnd.nextInt(30);
        for (var k = 0; k < len; k++) {
          sb.write(bits[rnd.nextInt(bits.length)]);
        }
        final md = sb.toString();
        final List<int> out;
        try {
          out = writeDocx(md);
        } catch (e) {
          fail('save failed for ${jsonEncode(md)}: $e');
        }
        final back = readDocx(out);
        expect(
          _same(back.markdown, md),
          isTrue,
          reason: '${jsonEncode(md)} -> ${jsonEncode(back.markdown)}',
        );
        expect(back.editable, isTrue);
        final f = readDocx(_without(out, 'docProps/custom.xml'));
        if (f.editable) {
          expect(
            _same(f.markdown, md),
            isTrue,
            reason: '${jsonEncode(md)} -> ${jsonEncode(f.markdown)}',
          );
        } else {
          refused++;
        }
      }
      expect(refused, lessThan(150));
    });
  });

  group('other Word features are named', () {
    String? flag(String body, {String numbering = '', String styles = ''}) {
      final r = readDocx(_doc(body, numbering: numbering, styles: styles));
      return r.unsupported.isEmpty ? null : r.unsupported.join('|');
    }

    test('tables, pictures, comments, tracked changes, fields', () {
      expect(
        flag('<w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl>'),
        contains('tables'),
      );
      expect(flag('<w:p><w:r><w:drawing/></w:r></w:p>'), contains('pictures'));
      expect(
        flag('<w:p><w:r><w:commentReference w:id="1"/></w:r></w:p>'),
        contains('comments'),
      );
      expect(
        flag('<w:p><w:del><w:r><w:delText>x</w:delText></w:r></w:del></w:p>'),
        contains('tracked changes'),
      );
      expect(
        flag(
          '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText> PAGE </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>1</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
        ),
        contains('fields'),
      );
    });

    test('a HYPERLINK field is a link', () {
      final r = readDocx(
        _doc(
          '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText> HYPERLINK "https://a.com/x" </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>site</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
        ),
      );
      expect(r.unsupported, isEmpty);
      expect(r.markdown, '[site](https://a.com/x)');
    });

    test('looks: colour, highlight, size, font, alignment, page breaks', () {
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:color w:val="FF0000"/></w:rPr>'
          '<w:t>red</w:t></w:r></w:p>',
        ),
        contains('colours'),
      );
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:highlight w:val="yellow"/></w:rPr>'
          '<w:t>hi</w:t></w:r></w:p>',
        ),
        contains('highlighting'),
      );
      expect(
        flag(
          '<w:p><w:r><w:t>plain</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:sz w:val="40"/></w:rPr>'
          '<w:t>big</w:t></w:r></w:p>',
        ),
        contains('text sizes'),
      );
      expect(
        flag(
          '<w:p><w:r><w:t>plain</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:rFonts w:ascii="Courier New" '
          'w:hAnsi="Courier New"/></w:rPr><w:t>mono</w:t></w:r></w:p>',
        ),
        contains('fonts'),
      );
      expect(
        flag(
          '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:t>mid</w:t></w:r></w:p>',
        ),
        contains('alignment'),
      );
      expect(
        flag('<w:p><w:r><w:br w:type="page"/></w:r></w:p>'),
        contains('page breaks'),
      );
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/>'
          '</w:rPr><w:t>2</w:t></w:r></w:p>',
        ),
        contains('superscript or subscript'),
      );
      // Hindi typed in Word (a run marked w:cs) is drawn at its
      // complex-script size (szCs), so a Latin size on it changes nothing;
      // its own size, or a digit's, does.
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t>है</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:szCs w:val="40"/><w:cs/></w:rPr>'
          '<w:t>क्या</w:t></w:r></w:p>',
        ),
        contains('text sizes'),
      );
      expect(
        flag(
          '<w:p><w:r><w:t>plain</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:sz w:val="40"/></w:rPr>'
          '<w:t>2026</w:t></w:r></w:p>',
        ),
        contains('text sizes'),
      );
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t>है</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:sz w:val="28"/><w:cs/></w:rPr>'
          '<w:t>क्या</w:t></w:r></w:p>',
        ),
        isNull,
      );
    });

    test('list styles Breeze cannot write', () {
      String numbering(String fmt, String text) =>
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="$fmt"/>'
          '<w:lvlText w:val="$text"/></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '</w:numbering>';
      const item =
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
          '</w:numPr></w:pPr><w:r><w:t>x</w:t></w:r></w:p>';
      expect(flag(item, numbering: numbering('decimal', '%1.')), isNull);
      expect(
        flag(item, numbering: numbering('lowerLetter', '%1.')),
        contains('list numbering styles'),
      );
      expect(
        flag(item, numbering: numbering('decimal', '(%1)')),
        contains('list numbering styles'),
      );
      expect(
        flag(item, numbering: numbering('bullet', '✱')),
        contains('bullet styles'),
      );
      expect(flag(item, numbering: numbering('bullet', '•')), isNull);
    });

    test('looks Word draws that Breeze would lose', () {
      // Grey from the theme ("Black, Lighter 50%").
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:color w:val="7F7F7F" w:themeColor="text1" '
          'w:themeTint="80"/></w:rPr><w:t>grey</w:t></w:r></w:p>',
        ),
        contains('colours'),
      );
      // Boxed text, a coloured underline, a Wingdings smiley.
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:bdr w:val="single"/></w:rPr>'
          '<w:t>box</w:t></w:r></w:p>',
        ),
        contains('text effects'),
      );
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:u w:val="single" w:color="FF0000"/>'
          '</w:rPr><w:t>u</w:t></w:r></w:p>',
        ),
        contains('underline styles'),
      );
      expect(
        flag('<w:p><w:r><w:t>${String.fromCharCode(0xF04A)}</w:t></w:r></w:p>'),
        contains('symbols'),
      );
      // A hidden paragraph mark joins two paragraphs in Word.
      expect(
        flag(
          '<w:p><w:pPr><w:rPr><w:vanish/></w:rPr></w:pPr>'
          '<w:r><w:t>one</w:t></w:r></w:p><w:p><w:r><w:t>two</w:t></w:r></w:p>',
        ),
        contains('hidden text'),
      );
      // A formatting change recorded by track changes.
      expect(
        flag(
          '<w:p><w:r><w:rPr><w:b/><w:rPrChange w:id="1" w:author="a">'
          '<w:rPr/></w:rPrChange></w:rPr><w:t>x</w:t></w:r></w:p>',
        ),
        contains('tracked changes'),
      );
    });

    test('Word drops edge spaces of text not marked to keep them', () {
      final r = readDocx(
        _doc(
          '<w:p><w:r><w:t>x</w:t></w:r><w:r><w:t> a </w:t></w:r>'
          '<w:r><w:t>y</w:t></w:r></w:p>',
        ),
      );
      expect(r.markdown, 'xay');
    });

    test('italic in both styles shows upright, as in Word', () {
      final styles =
          '<w:styles $_w><w:style w:type="paragraph" w:default="1" '
          'w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
          '<w:style w:type="paragraph" w:styleId="Q"><w:name w:val="Q"/>'
          '<w:rPr><w:i/></w:rPr></w:style>'
          '<w:style w:type="character" w:styleId="E"><w:name w:val="E"/>'
          '<w:rPr><w:i/></w:rPr></w:style></w:styles>';
      final r = readDocx(
        _doc(
          '<w:p><w:pPr><w:pStyle w:val="Q"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">slanted </w:t></w:r>'
          '<w:r><w:rPr><w:rStyle w:val="E"/></w:rPr><w:t>upright</w:t></w:r>'
          '</w:p>',
          styles: styles,
        ),
      );
      expect(
        _same(r.markdown, '*slanted* upright'),
        isTrue,
        reason: r.markdown,
      );
    });

    test('Hindi is bold by bCs in a w:cs run, by b otherwise (Word)', () {
      // Checked in Word's PDF export: an unmarked run uses the Latin
      // properties whatever its script.
      final marked = readDocx(
        _doc(
          '<w:p><w:r><w:rPr><w:bCs/><w:cs/></w:rPr><w:t>क्या</w:t></w:r>'
          '<w:r><w:rPr><w:b/><w:cs/></w:rPr><w:t>है</w:t></w:r></w:p>',
        ),
      );
      expect(marked.markdown, '**क्या**है');
      final unmarked = readDocx(
        _doc(
          '<w:p><w:r><w:rPr><w:bCs/></w:rPr><w:t>क्या</w:t></w:r>'
          '<w:r><w:rPr><w:b/></w:rPr><w:t>है</w:t></w:r></w:p>',
        ),
      );
      expect(unmarked.markdown, 'क्या**है**');
    });
  });

  group('list numbers are the ones Word shows', () {
    String numbering(String abstracts, String nums) =>
        '<w:numbering $_w>$abstracts$nums</w:numbering>';
    String abs(
      int id, {
      List<String> fmts = const ['decimal', 'decimal'],
      String extra = '',
      int start = 1,
    }) {
      final b = StringBuffer('<w:abstractNum w:abstractNumId="$id">');
      for (var l = 0; l < fmts.length; l++) {
        b.write(
          '<w:lvl w:ilvl="$l"><w:start w:val="$start"/>'
          '<w:numFmt w:val="${fmts[l]}"/>'
          '<w:lvlText w:val="${fmts[l] == 'bullet' ? String.fromCharCode(0x2022) : '%${l + 1}.'}"/>'
          '${l == 1 ? extra : ''}</w:lvl>',
        );
      }
      b.write('</w:abstractNum>');
      return b.toString();
    }

    String item(int num, int lvl, String t) =>
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="$lvl"/><w:numId w:val="$num"/>'
        '</w:numPr></w:pPr><w:r><w:t>$t</w:t></w:r></w:p>';

    String md(String body, String numbering) =>
        readDocx(_doc(body, numbering: numbering)).markdown;

    test('a restart applies once; the abstract list counts on', () {
      final n = numbering(
        abs(0),
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
        '<w:num w:numId="2"><w:abstractNumId w:val="0"/>'
        '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/>'
        '</w:lvlOverride></w:num>',
      );
      expect(
        md(
          item(1, 0, 'a') +
              item(1, 0, 'b') +
              item(1, 0, 'c') +
              item(2, 0, 'd') +
              item(2, 0, 'e') +
              item(1, 0, 'f'),
          n,
        ),
        '1. a\n2. b\n3. c\n1. d\n2. e\n3. f',
      );
    });

    test('a bullet parent resets the numbers under it', () {
      final n = numbering(
        abs(0, fmts: ['bullet', 'decimal']),
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>',
      );
      expect(
        md(
          item(1, 0, 'a') + item(1, 1, 'x') + item(1, 0, 'b') + item(1, 1, 'y'),
          n,
        ),
        '- a\n  1. x\n- b\n  1. y',
      );
    });

    test('an unused parent level counts as used', () {
      final n = numbering(
        abs(0),
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>',
      );
      expect(md(item(1, 1, 'a') + item(1, 0, 'b'), n), '  1. a\n2. b');
    });

    test('lvlRestart 0 never restarts; a list may start at 0', () {
      final never = numbering(
        abs(0, extra: '<w:lvlRestart w:val="0"/>'),
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>',
      );
      expect(
        md(item(1, 1, 'x') + item(1, 0, 'a') + item(1, 1, 'y'), never),
        '  1. x\n2. a\n  2. y',
      );
      final zero = numbering(
        abs(0, start: 0),
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>',
      );
      expect(md(item(1, 0, 'a') + item(1, 0, 'b'), zero), '0. a\n1. b');
    });

    test('Breeze writes lists Word numbers as the note does', () {
      for (final note in [
        '  1. a\n1. b',
        '## h\n  1. i1\n1. i2',
        '0. a\n0. b\n0. c',
        '- a\n  1. x\n- b\n  1. y',
        '1. a\n2. b\n5. c\n  1. d\n6. e\n1. f',
      ]) {
        final out = writeDocx(note);
        final f = readDocx(out);
        expect(
          _same(f.markdown, note),
          isTrue,
          reason: '${jsonEncode(note)} -> ${jsonEncode(f.markdown)}',
        );
      }
    });
  });

  group('more', () {
    test('a line break inside a list item is named; in text it splits', () {
      final r = readDocx(
        _doc('<w:p><w:r><w:t>one</w:t><w:br/><w:t>two</w:t></w:r></w:p>'),
      );
      expect(r.unsupported, isEmpty);
      expect(r.markdown, 'one\ntwo');
    });
  });

  group('never crashes on a damaged file', () {
    test('random bytes, cut-off zips and broken XML', () {
      final rnd = Random(5);
      final good = writeDocx(
        '# T\n**b** [l](https://u.v)\n- x\n1. y\nहिंदी 😀',
      );
      final word = _fixture('word_keep.docx');
      for (var n = 0; n < 600; n++) {
        final List<int> bytes;
        switch (n % 4) {
          case 0:
            bytes = good.sublist(0, rnd.nextInt(good.length + 1));
          case 1:
            bytes = List.of(word);
            for (var k = 0; k < 5; k++) {
              bytes[rnd.nextInt(bytes.length)] = rnd.nextInt(256);
            }
          case 2:
            final doc = _part(good, 'word/document.xml');
            bytes = _with(
              good,
              'word/document.xml',
              doc.substring(0, rnd.nextInt(doc.length + 1)),
            );
          default:
            bytes = List.generate(rnd.nextInt(300), (_) => rnd.nextInt(256));
        }
        readDocx(bytes);
        docxPlainText(bytes);
      }
    });
  });

  test('plain text for previews and search', () {
    expect(
      docxPlainText(_fixture('word_scripts.docx')),
      contains('Привет αβγ done.'),
    );
  });

  group('the store', () {
    late Directory base;
    late NoteStore store;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('breeze_docx');
      store = await NoteStore.openIn(base);
    });
    tearDown(() => base.delete(recursive: true));

    test('a new .docx note is a Word document', () async {
      final n = await store.create('Doc.docx', content: '**b**', rtf: true);
      expect(looksLikeDocx(await n.file.readAsBytes()), isTrue);
      final t = await store.readText(n);
      expect(t.text, '**b**');
      expect(t.rtf!.editable, isTrue);
      expect(t.rtf!.native, isTrue);
    });

    test('renamed .rtf to .docx becomes Word, and back', () async {
      var n = await store.create('Plan.rtf', content: '# Hi\n*x*', rtf: true);
      n = await store.save(n, '# Hi\n*x*', newName: 'Plan.docx', rtf: true);
      expect(n.fullName, 'Plan.docx');
      expect(looksLikeDocx(await n.file.readAsBytes()), isTrue);
      expect((await store.readText(n)).text, '# Hi\n*x*');
      n = await store.save(n, '# Hi\n*x*', newName: 'Plan.txt', rtf: true);
      expect(await n.file.readAsString(), '# Hi\n*x*');
    });

    test('a text file named .docx stays text', () async {
      final f = File('${store.dir.path}/notes.docx')
        ..writeAsStringSync('hello');
      await store.refresh();
      f.existsSync();
      final n = store.notes.firstWhere((x) => x.fullName == 'notes.docx');
      final t = await store.readText(n);
      expect(t.text, 'hello');
      expect(t.rtf, isNull);
    });

    test('a Word file handed over by Android keeps its exact bytes', () async {
      final word = _fixture('word_keep.docx');
      // Android decodes a file that is not UTF-8 as Latin-1.
      final text = latin1.decode(word);
      final n = await store.openIncoming('Report.docx', text);
      expect(await n.file.readAsBytes(), word);
      // Opening it again reuses that copy.
      final again = await store.openIncoming('Report.docx', text);
      expect(again.file.path, n.file.path);
      expect((await store.readText(n)).text, startsWith('# Title'));
    });
  });
  group('second Word review', () {
    String? flag(String body, {String numbering = ''}) {
      final r = readDocx(_doc(body, numbering: numbering));
      return r.unsupported.isEmpty ? null : r.unsupported.join('|');
    }

    const arial =
        '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/>'
        '<w:sz w:val="24"/></w:rPr>';

    test('a document in one font and size is editable, and keeps it', () {
      final doc = _doc(
        '<w:p><w:r>$arial<w:t>One </w:t></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:b/>'
        '<w:sz w:val="24"/></w:rPr><w:t>two</w:t></w:r></w:p>'
        '<w:p><w:r>$arial<w:t>three</w:t></w:r></w:p>',
      );
      final r = readDocx(doc);
      expect(r.unsupported, isEmpty);
      final look = docxLook(doc)!;
      expect(look.font, 'Arial');
      expect(look.size, 24);
      final saved = writeDocxKeeping(('One **two**\nthree and more', doc));
      final styles = utf8.decode(
        ZipDecoder()
            .decodeBytes(saved)
            .files
            .firstWhere((f) => f.name == 'word/styles.xml')
            .content,
      );
      expect(styles, contains('w:ascii="Arial"'));
      expect(styles, contains('<w:sz w:val="24"/>'));
      expect(docxLook(saved)!.font, 'Arial');
      // A mix is still named.
      expect(
        flag(
          '<w:p><w:r>$arial<w:t>a</w:t></w:r>'
          '<w:r><w:t>b</w:t></w:r></w:p>',
        ),
        allOf(contains('fonts'), contains('text sizes')),
      );
    });

    test('a field that never ends is not silently hidden', () {
      expect(
        flag(
          '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:t>Hello visible</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Second</w:t></w:r></w:p>',
        ),
        contains('content Breeze cannot read'),
      );
    });

    test('Breeze files open in Word without Compatibility Mode', () {
      final names = ZipDecoder()
          .decodeBytes(writeDocx('hi'))
          .files
          .map((f) => f.name)
          .toList();
      expect(names, contains('word/settings.xml'));
      final out = ZipDecoder().decodeBytes(writeDocx('hi'));
      String part(String n) =>
          utf8.decode(out.files.firstWhere((f) => f.name == n).content);
      expect(part('word/settings.xml'), contains('w:val="15"'));
      expect(part('word/_rels/document.xml.rels'), contains('settings.xml'));
      expect(part('[Content_Types].xml'), contains('/word/settings.xml'));
    });

    test('numbering that draws nothing is no list (LibreOffice headings)', () {
      final n =
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="none"/>'
          '<w:lvlText w:val=""/></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '</w:numbering>';
      final r = readDocx(
        _doc(
          '<w:p><w:pPr><w:pStyle w:val="Heading1"/><w:numPr><w:ilvl w:val="0"/>'
          '<w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Head</w:t></w:r></w:p>',
          numbering: n,
        ),
      );
      expect(r.unsupported, isEmpty);
      expect(r.markdown, '# Head');
    });

    test('an emptied header is not a loss; one with text is', () {
      List<int> withHeader(String hdr) {
        var d = _doc(
          '<w:p><w:r><w:t>Body</w:t></w:r></w:p>'
          '<w:sectPr><w:headerReference w:type="default" r:id="rIdH"/>'
          '</w:sectPr>',
        );
        final rels = utf8.decode(
          ZipDecoder()
              .decodeBytes(d)
              .files
              .firstWhere((f) => f.name == 'word/_rels/document.xml.rels')
              .content,
        );
        d = _with(
          d,
          'word/_rels/document.xml.rels',
          rels.replaceFirst(
            '</Relationships>',
            '<Relationship Id="rIdH" Type="http://schemas.openxmlformats.org/'
                'officeDocument/2006/relationships/header" '
                'Target="header1.xml"/></Relationships>',
          ),
        );
        return _with(
          d,
          'word/header1.xml',
          '<w:hdr $_w><w:p><w:pPr><w:pStyle w:val="Header"/></w:pPr>'
              '$hdr</w:p></w:hdr>',
        );
      }

      expect(readDocx(withHeader('')).unsupported, isEmpty);
      expect(
        readDocx(withHeader('<w:r><w:t>Top</w:t></w:r>')).unsupported,
        contains('headers and footers'),
      );
    });

    test('keycap emoji are drawn in a font Word picks', () {
      expect(
        flag(
          '<w:p><w:r><w:t>Step 1</w:t></w:r>'
          '<w:r><w:rPr><w:rFonts w:ascii="Segoe UI Symbol" '
          'w:hAnsi="Segoe UI Symbol"/></w:rPr><w:t>⃣</w:t></w:r></w:p>',
        ),
        isNull,
      );
    });

    test('a start override is where that level restarts in its list', () {
      final n =
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%1."/></w:lvl>'
          '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%2."/></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '<w:num w:numId="2"><w:abstractNumId w:val="0"/>'
          '<w:lvlOverride w:ilvl="1"><w:startOverride w:val="7"/>'
          '</w:lvlOverride></w:num></w:numbering>';
      String item(int num, int lvl, String t) =>
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="$lvl"/>'
          '<w:numId w:val="$num"/></w:numPr></w:pPr>'
          '<w:r><w:t>$t</w:t></w:r></w:p>';
      final r = readDocx(
        _doc(
          item(1, 0, 'a') +
              item(2, 1, 'a1') +
              item(2, 1, 'a2') +
              item(2, 0, 'b') +
              item(2, 1, 'b1'),
          numbering: n,
        ),
      );
      expect(r.markdown, '1. a\n  7. a1\n  8. a2\n2. b\n  7. b1');
    });

    test('w:cs draws a run with the complex-script look', () {
      final r = readDocx(
        _doc(
          '<w:p><w:r><w:rPr><w:b/><w:cs/></w:rPr>'
          '<w:t>99 abc</w:t></w:r></w:p>',
        ),
      );
      expect(r.markdown, '99 abc');
    });
  });
  group('third Word review', () {
    String? flag(String body, {String numbering = '', String styles = ''}) {
      final r = readDocx(_doc(body, numbering: numbering, styles: styles));
      return r.unsupported.isEmpty ? null : r.unsupported.join('|');
    }

    String run(String rPr, String t) =>
        '<w:p><w:r><w:rPr>$rPr</w:rPr><w:t>$t</w:t></w:r></w:p>';

    test('Breeze marks Hindi runs w:cs, so Word uses bCs, szCs and cs', () {
      final out = writeDocx('Hi **नमस्ते** दुनिया 2026');
      final doc = _part(out, 'word/document.xml');
      expect(doc, contains('<w:cs/></w:rPr><w:t xml:space="preserve">नमस्ते'));
      expect(doc, contains('<w:t xml:space="preserve">Hi </w:t>'));
      expect(readDocx(out).unsupported, isEmpty);
    });

    test('a look set twice in one place shows if either shows it', () {
      expect(
        flag(
          run(
            '<w:highlight w:val="yellow"/>'
                '<w:shd w:val="clear" w:color="auto" w:fill="auto"/>',
            'x',
          ),
        ),
        contains('highlighting'),
      );
      expect(
        flag(run('<w:spacing w:val="40"/><w:w w:val="100"/>', 'x')),
        contains('text effects'),
      );
      expect(
        flag(run('<w:shadow/><w:effect w:val="none"/>', 'x')),
        contains('text effects'),
      );
      expect(
        flag(run('<w:caps/><w:smallCaps w:val="0"/>', 'x')),
        contains('text effects'),
      );
      expect(
        flag(
          run('<w:position w:val="8"/><w:vertAlign w:val="baseline"/>', 'x'),
        ),
        contains('superscript or subscript'),
      );
      expect(
        flag(
          '<w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="4"/></w:pBdr>'
          '<w:shd w:val="clear" w:color="auto" w:fill="auto"/></w:pPr>'
          '<w:r><w:t>x</w:t></w:r></w:p>',
        ),
        contains('borders or shading'),
      );
      // A border with no line draws nothing.
      expect(
        flag(
          '<w:p><w:pPr><w:pBdr><w:bottom w:val="none" w:sz="0"/></w:pBdr>'
          '</w:pPr><w:r><w:t>x</w:t></w:r></w:p>',
        ),
        isNull,
      );
    });

    test('é is drawn in the hAnsi font, not the ascii one', () {
      expect(
        flag(
          '<w:p><w:r><w:t>plain café</w:t></w:r></w:p>'
          '${run('<w:rFonts w:ascii="Calibri" w:hAnsi="Courier New"/>', 'café')}',
        ),
        contains('fonts'),
      );
    });

    test('with no defaults Word uses Times New Roman 10', () {
      const bare =
          '<w:styles $_w><w:style w:type="paragraph" w:default="1" '
          'w:styleId="Normal"><w:name w:val="Normal"/></w:style></w:styles>';
      expect(
        flag(
          '${run('<w:sz w:val="20"/>', 'a')}<w:p><w:r><w:t>b</w:t></w:r></w:p>',
          styles: bare,
        ),
        isNull,
      );
      final doc = _doc('<w:p><w:r><w:t>b</w:t></w:r></w:p>', styles: bare);
      expect(docxLook(doc)!.font, 'Times New Roman');
      expect(docxLook(doc)!.size, 20);
    });

    test('a header Word does not show is not a loss', () {
      List<int> withHeader(String kind, {bool titlePg = false}) {
        var d = _doc(
          '<w:p><w:r><w:t>Body</w:t></w:r></w:p>'
          '<w:sectPr><w:headerReference w:type="$kind" r:id="rIdH"/>'
          '${titlePg ? '<w:titlePg/>' : ''}</w:sectPr>',
        );
        d = _with(
          d,
          'word/_rels/document.xml.rels',
          _part(d, 'word/_rels/document.xml.rels').replaceFirst(
            '</Relationships>',
            '<Relationship Id="rIdH" Type="http://schemas.openxmlformats.org/'
                'officeDocument/2006/relationships/header" '
                'Target="header1.xml"/></Relationships>',
          ),
        );
        return _with(
          d,
          'word/header1.xml',
          '<w:hdr $_w><w:p><w:r><w:t>First page</w:t></w:r></w:p></w:hdr>',
        );
      }

      expect(readDocx(withHeader('first')).unsupported, isEmpty);
      expect(readDocx(withHeader('even')).unsupported, isEmpty);
      expect(
        readDocx(withHeader('first', titlePg: true)).unsupported,
        contains('headers and footers'),
      );
      expect(
        readDocx(withHeader('default')).unsupported,
        contains('headers and footers'),
      );
    });

    test('an invisible numbering level that indents is named', () {
      final n =
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="none"/>'
          '<w:lvlText w:val=""/><w:pPr><w:ind w:left="1440" w:hanging="360"/>'
          '</w:pPr></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '</w:numbering>';
      expect(
        flag(
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
          '</w:numPr></w:pPr><w:r><w:t>x</w:t></w:r></w:p>',
          numbering: n,
        ),
        contains('indents'),
      );
    });

    test('a font or size mix inside one heading is named', () {
      const h = '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>';
      final styles = _part(writeDocx('x'), 'word/styles.xml');
      expect(
        flag(
          '<w:p>$h<w:r><w:t xml:space="preserve">Half </w:t></w:r>'
          '<w:r><w:rPr><w:rFonts w:ascii="Comic Sans MS" '
          'w:hAnsi="Comic Sans MS"/></w:rPr><w:t>Comic</w:t></w:r></w:p>',
          styles: styles,
        ),
        contains('fonts'),
      );
      expect(
        flag(
          '<w:p>$h<w:r><w:rPr><w:rFonts w:ascii="Comic Sans MS" '
          'w:hAnsi="Comic Sans MS"/></w:rPr><w:t>All comic</w:t></w:r></w:p>',
          styles: styles,
        ),
        isNull,
      );
    });

    test('the page size, orientation and margins are kept on save', () {
      final old = _doc(
        '<w:p><w:r><w:t>Wide</w:t></w:r></w:p>'
        '<w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>'
        '<w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" '
        'w:header="360" w:footer="360" w:gutter="0"/></w:sectPr>',
      );
      expect(readDocx(old).unsupported, isEmpty);
      final doc = _part(writeDocxKeeping(('Wide', old)), 'word/document.xml');
      expect(
        doc,
        contains('<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>'),
      );
      expect(doc, contains('w:top="720"'));
      expect(
        flag(
          '<w:p><w:r><w:t>x</w:t></w:r></w:p>'
          '<w:sectPr><w:vAlign w:val="center"/></w:sectPr>',
        ),
        contains('page layout'),
      );
    });

    test('list restarts Breeze cannot count as Word does are named', () {
      String abs(String extra) =>
          '<w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%1."/></w:lvl>'
          '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%2."/>$extra</w:lvl>'
          '<w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%3."/></w:lvl></w:abstractNum>';
      String item(int num, int lvl) =>
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="$lvl"/>'
          '<w:numId w:val="$num"/></w:numPr></w:pPr>'
          '<w:r><w:t>x</w:t></w:r></w:p>';
      // An override above the num's first item (Word: 1. / 1. / 2.).
      expect(
        flag(
          item(1, 0) + item(2, 1) + item(1, 0),
          numbering:
              '<w:numbering $_w>${abs('')}'
              '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
              '<w:num w:numId="2"><w:abstractNumId w:val="0"/>'
              '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/>'
              '</w:lvlOverride></w:num></w:numbering>',
        ),
        contains('list styles'),
      );
      // lvlRestart 0: a deeper item does not count that level (Word:
      // 1. 2. 1. 1.).
      final r = readDocx(
        _doc(
          item(1, 0) + item(1, 0) + item(1, 2) + item(1, 1),
          numbering:
              '<w:numbering $_w>'
              '${abs('<w:lvlRestart w:val="0"/>')}'
              '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
              '</w:numbering>',
        ),
      );
      expect(r.markdown, '1. x\n2. x\n    1. x\n  1. x');
    });
  });
  group('fourth Word review', () {
    String? flag(String body, {String styles = ''}) {
      final r = readDocx(_doc(body, styles: styles));
      return r.unsupported.isEmpty ? null : r.unsupported.join('|');
    }

    test('digits and punctuation beside Hindi are Latin, as Word types', () {
      final doc = _part(
        writeDocx('कीमत 2500000 रुपये है, ठीक है?'),
        'word/document.xml',
      );
      expect(
        doc,
        contains('<w:cs/></w:rPr><w:t xml:space="preserve">कीमत </w:t>'),
      );
      expect(doc, contains('<w:r><w:t xml:space="preserve">2500000 </w:t>'));
      expect(doc, contains('<w:r><w:t xml:space="preserve">, </w:t>'));
    });

    test('a document with digits inside its Hindi runs keeps them there', () {
      final old = _doc(
        '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t>कीमत 2500 है</w:t></w:r></w:p>',
      );
      expect(
        docxLook(old)!.neutralsInCs,
        containsAll("2500 ".codeUnits.toSet().difference({0x20})),
      );
      final doc = _part(
        writeDocxKeeping(('कीमत 2500 है', old)),
        'word/document.xml',
      );
      expect(doc, contains('<w:t xml:space="preserve">कीमत 2500 है</w:t>'));
    });

    test('Hindi marked in one place and not in another is named', () {
      expect(
        flag(
          '<w:p><w:r><w:t>नमस्ते</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:szCs w:val="28"/><w:cs/></w:rPr>'
          '<w:t>नमस्ते</w:t></w:r></w:p>',
        ),
        contains('text sizes'),
      );
    });

    test('Hindi in a font of its own (Google Docs) is kept', () {
      const nirmala =
          '<w:rFonts w:ascii="Nirmala UI" w:hAnsi="Nirmala UI" '
          'w:cs="Nirmala UI"/>';
      final old = _doc(
        '<w:p><w:r><w:t>English</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr>$nirmala</w:rPr><w:t>नमस्ते</w:t></w:r></w:p>',
      );
      expect(readDocx(old).unsupported, isEmpty);
      expect(docxLook(old)!.fontCs, 'Nirmala UI');
    });

    test('one link stays one link in Word, whatever is inside it', () {
      final doc = _part(
        writeDocx('[नमस्ते **world** 2024](https://example.com/a)'),
        'word/document.xml',
      );
      expect('<w:hyperlink'.allMatches(doc).length, 1);
    });

    test('pattern shading and a style look the run does not turn off', () {
      expect(
        flag(
          '<w:p><w:pPr><w:shd w:val="pct20" w:color="auto" w:fill="auto"/>'
          '</w:pPr><w:r><w:t>x</w:t></w:r></w:p>',
        ),
        contains('borders or shading'),
      );
      const styles =
          '<w:styles $_w><w:style w:type="paragraph" '
          'w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>'
          '</w:style><w:style w:type="paragraph" w:styleId="C">'
          '<w:name w:val="C"/><w:rPr><w:caps/></w:rPr></w:style></w:styles>';
      expect(
        flag(
          '<w:p><w:pPr><w:pStyle w:val="C"/></w:pPr><w:r><w:rPr>'
          '<w:smallCaps w:val="0"/></w:rPr><w:t>x</w:t></w:r></w:p>',
          styles: styles,
        ),
        contains('text effects'),
      );
    });
  });
  group('fifth Word review', () {
    test('notes with bold carried past italic save to Word', () {
      for (final n in [
        '*मैं **ठीक*** **हूँ**',
        '*a **b*** **c**',
        '**x** *y **z*** **w**',
      ]) {
        final back = readDocx(writeDocx(n));
        expect(_same(back.markdown, n), isTrue, reason: back.markdown);
      }
    });

    test('a list item indented on its own is named', () {
      final n =
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
          '<w:lvlText w:val="\u2022"/><w:pPr><w:ind w:left="720" '
          'w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '</w:numbering>';
      String item(String ind) =>
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
          '</w:numPr>$ind</w:pPr><w:r><w:t>x</w:t></w:r></w:p>';
      expect(
        readDocx(
          _doc(item('<w:ind w:left="1080"/>'), numbering: n),
        ).unsupported,
        contains('indents'),
      );
      // The level's own indent written out again is no change.
      expect(
        readDocx(
          _doc(item('<w:ind w:left="720" w:hanging="360"/>'), numbering: n),
        ).unsupported,
        isEmpty,
      );
    });

    test('English letters inside a Hindi run are judged in its look', () {
      final r = readDocx(
        _doc(
          '<w:p><w:r><w:t>plain</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:rFonts w:cs="Cordia New"/>'
          '<w:szCs w:val="28"/><w:cs/></w:rPr><w:t>abc</w:t></w:r></w:p>',
        ),
      );
      expect(r.unsupported, containsAll(['fonts', 'text sizes']));
    });

    test('each mark beside Hindi is written where the document had it', () {
      final old = _doc(
        '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t>सूची:</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> 250, </w:t></w:r>'
        '<w:r><w:rPr><w:cs/></w:rPr><w:t>ठीक</w:t></w:r></w:p>',
      );
      final look = docxLook(old)!;
      expect(look.neutralsInCs, contains(0x3A)); // :
      expect(look.neutralsInCs, isNot(contains(0x32))); // 2
      // A paragraph that keeps little of the old one: the rule by mark.
      final doc = _part(
        writeDocxKeeping(('सूची: 999, नया काम', old)),
        'word/document.xml',
      );
      expect(doc, contains('>सूची: </w:t>'));
      expect(doc, contains('>999, </w:t>'));
      // One that keeps most of it: each kept mark where it was.
      final kept = _part(
        writeDocxKeeping(('सूची: 250, ठीक है', old)),
        'word/document.xml',
      );
      expect(kept, contains('>सूची:</w:t>'));
      expect(kept, contains('> 250, </w:t>'));
    });
  });
  group('unchanged paragraphs', () {
    test('keep where each mark sat in the Hindi runs', () {
      final old = _doc(
        '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t xml:space="preserve">'
        'नया पता: मकान नं. 12/</w:t></w:r><w:r><w:t xml:space="preserve">'
        'B, </w:t></w:r><w:r><w:rPr><w:cs/></w:rPr><w:t>नोएडा 201301</w:t>'
        '</w:r></w:p>'
        '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t>कीमत</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> 250.</w:t></w:r></w:p>',
      );
      final md = readDocx(old).markdown;
      final doc = _part(writeDocxKeeping((md, old)), 'word/document.xml');
      expect(doc, contains('>नया पता: मकान नं. 12/</w:t>'));
      expect(doc, contains('>नोएडा 201301</w:t>'));
      expect(doc, contains('<w:r><w:t xml:space="preserve">B, </w:t>'));
    });
  });

  group("the document's look is kept on save", () {
    String styles(List<int> d) => _part(d, 'word/styles.xml');

    test('Word defaults: spacing, headings, kerning and bullets', () {
      final old = _fixture('word_look_a.docx');
      final r = readDocx(old);
      expect(r.unsupported, isEmpty);
      final out = writeDocxKeeping((r.markdown, old));
      final s = styles(out);
      expect(s, contains('<w:kern w:val="2"/>'));
      expect(
        s,
        contains('<w:spacing w:after="160" w:line="259" w:lineRule="auto"/>'),
      );
      final h1 = RegExp(r'w:styleId="Heading1">.*?</w:style>').stringMatch(s)!;
      expect(h1, contains('w:ascii="Calibri Light"'));
      expect(h1, contains('<w:sz w:val="40"/>'));
      expect(h1, contains('<w:color w:val="2F5496"/>'));
      expect(h1, isNot(contains('<w:b/>')));
      expect(h1, contains('w:before="360"'));
      final n = _part(out, 'word/numbering.xml');
      expect(n, contains('<w:lvlText w:val=""/>'));
      expect(n, contains('w:ascii="Symbol"'));
      expect(_same(readDocx(out).markdown, r.markdown), isTrue);
    });

    test('double spacing and a red Arial heading', () {
      final old = _fixture('word_look_b.docx');
      final r = readDocx(old);
      final s = styles(writeDocxKeeping((r.markdown, old)));
      expect(s, contains('w:line="480"'));
      final h1 = RegExp(r'w:styleId="Heading1">.*?</w:style>').stringMatch(s)!;
      expect(h1, contains('w:ascii="Arial"'));
      expect(h1, contains('<w:color w:val="FF0000"/>'));
    });

    test("a new note keeps Breeze's own look", () {
      final s = styles(writeDocx('# A\n\nb\n\n- c'));
      expect(s, isNot(contains('w:kern')));
      expect(s, contains('w:after="120" w:line="276"'));
      expect(
        _part(writeDocx('- c'), 'word/numbering.xml'),
        contains('<w:lvlText w:val="•"/>'),
      );
    });

    test('odd values in the old file never reach the XML', () {
      const bad =
          '<w:styles $_w><w:docDefaults><w:rPrDefault><w:rPr>'
          '<w:kern w:val="99999"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>'
          '<w:spacing w:after="1&quot;/&gt;&lt;x" w:line="abc" '
          'w:lineRule="evil"/></w:pPr></w:pPrDefault></w:docDefaults>'
          '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
          '<w:name w:val="Normal"/></w:style>'
          '<w:style w:type="paragraph" w:styleId="Heading1">'
          '<w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr>'
          '<w:rPr><w:rFonts w:ascii="A&quot;&lt;b" w:hAnsi="A&quot;&lt;b"/>'
          '<w:color w:val="zz&quot;"/></w:rPr></w:style></w:styles>';
      const num =
          '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
          '<w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" '
          'w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="X&quot;/&gt;"/>'
          '</w:rPr></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>';
      final old = _doc(
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>T</w:t>'
        '</w:r></w:p><w:p><w:pPr><w:numPr><w:ilvl w:val="0"/>'
        '<w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>i</w:t></w:r></w:p>',
        styles: bad,
        numbering: num,
      );
      final out = writeDocxKeeping(('# T\n- i', old));
      final s = styles(out);
      expect(s, isNot(contains('<x')));
      expect(s, isNot(contains('evil')));
      expect(s, isNot(contains('abc')));
      expect(s, isNot(contains('99999')));
      expect(_part(out, 'word/numbering.xml'), isNot(contains('X"')));
      final back = readDocx(out);
      expect(back.unsupported, isEmpty);
      expect(_same(back.markdown, '# T\n- i'), isTrue, reason: back.markdown);
    });
  });

  test('C1 control characters save to Word and read back', () {
    // Word itself writes them raw (a mis-decoded paste holds U+008D); a
    // note that opens must save.
    for (final md in ['café \u0085 next', 'a\u0096b', '\u007F\u0080\u009f']) {
      final back = readDocx(writeDocx(md));
      expect(back.unsupported, isEmpty);
      expect(back.markdown, md);
    }
  });

  test('an edited Hindi paragraph keeps its digits where they were', () {
    // "25" sat in the Hindi run, "2024" in a Latin one: no rule by
    // character can say that, only the old paragraph.
    final old = _doc(
      '<w:p><w:r><w:rPr><w:cs/></w:rPr><w:t xml:space="preserve">मैं 25 साल'
      '</w:t></w:r><w:r><w:t xml:space="preserve"> 2024 </w:t></w:r>'
      '<w:r><w:rPr><w:cs/></w:rPr><w:t>में।</w:t></w:r></w:p>',
    );
    final r = readDocx(old);
    expect(r.unsupported, isEmpty);
    List<(bool, String)> runs(String md) {
      final doc = _part(writeDocxKeeping((md, old)), 'word/document.xml');
      return [
        for (final m in RegExp(
          r'<w:r>(<w:rPr>.*?</w:rPr>)?<w:t[^>]*>([^<]*)</w:t>',
        ).allMatches(doc))
          ((m[1] ?? '').contains('<w:cs/>'), m[2]!),
      ];
    }

    for (final md in [r.markdown, '${r.markdown} ठीक', 'अब ${r.markdown}']) {
      final rs = runs(md);
      expect(rs.any((x) => x.$1 && x.$2.contains('25')), isTrue, reason: '$rs');
      expect(
        rs.any((x) => !x.$1 && x.$2.contains('2024')),
        isTrue,
        reason: '$rs',
      );
    }
  });

  test('text that looks like Markdown is edited and saved as text', () {
    final old = _doc(
      '<w:p><w:r><w:t>- not a list</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>2. not a number</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">a *b* _c_ &lt;u&gt;d&lt;/u&gt; C:\\x</w:t></w:r></w:p>',
    );
    final r = readDocx(old);
    expect(r.unsupported, isEmpty);
    // The user adds a word to each line; the rest is saved as it was.
    final edited = r.markdown.split('\n').map((l) => '$l ok').join('\n');
    final doc = _part(writeDocxKeeping((edited, old)), 'word/document.xml');
    expect(doc, isNot(contains('numPr')));
    expect(doc, isNot(contains('<w:i/>')));
    expect(doc, isNot(contains('<w:u ')));
    final back = readDocx(writeDocxKeeping((edited, old)));
    expect(back.markdown.split('\n'), [
      r'\- not a list ok',
      r'2\. not a number ok',
      r'a \*b\* \_c\_ \<u>d\</u> C:\x ok',
    ]);
  });

  group('a bullet indented by hand', () {
    String lvl(int l, String text, int left, [String font = 'Symbol']) =>
        '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
        '<w:lvlText w:val="$text"/><w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="$left" w:hanging="360"/></w:pPr>'
        '<w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font"/></w:rPr></w:lvl>';
    String numbering(String levels) =>
        '<w:numbering $_w><w:abstractNum w:abstractNumId="0">$levels'
        '</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/>'
        '</w:num></w:numbering>';
    String item(String t, {int ilvl = 0, String ind = ''}) =>
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="$ilvl"/><w:numId w:val="1"/>'
        '</w:numPr>$ind</w:pPr><w:r><w:t>$t</w:t></w:r></w:p>';
    const pushed = '<w:ind w:left="1440" w:hanging="360"/>';

    test('to where another level draws, same bullet: that level', () {
      final n = numbering(lvl(0, '•', 720) + lvl(1, '•', 1440));
      final doc = _doc(
        item('top') + item('pushed', ind: pushed) + item('real', ilvl: 1),
        numbering: n,
      );
      final r = readDocx(doc);
      expect(r.unsupported, isEmpty);
      expect(r.markdown, '- top\n  - pushed\n  - real');
      // Saving puts it at that level; reading the save gives the same.
      final saved = writeDocxKeeping((r.markdown, doc));
      expect(readDocx(saved).markdown, r.markdown);
      expect(readDocx(saved).unsupported, isEmpty);
    });

    test('anything less exact stays read-only', () {
      String? flag(String levels, String ind) {
        final r = readDocx(
          _doc(item('top') + item('x', ind: ind), numbering: numbering(levels)),
        );
        return r.unsupported.isEmpty ? null : r.unsupported.join('|');
      }

      // No level draws there.
      expect(
        flag(
          lvl(0, '•', 720) + lvl(1, '•', 1440),
          '<w:ind w:left="1000" w:hanging="360"/>',
        ),
        contains('indents'),
      );
      // A level does, but not where Breeze writes it (a 360 step ladder):
      // saved, the item would move.
      expect(
        flag(
          lvl(0, '•', 360) + lvl(1, '•', 720),
          '<w:ind w:left="720" w:hanging="360"/>',
        ),
        contains('indents'),
      );
      // Its own level, but also indented from the right.
      expect(
        flag(
          lvl(0, '•', 720),
          '<w:ind w:left="720" w:hanging="360" w:right="720"/>',
        ),
        contains('indents'),
      );
      // That level draws a different bullet.
      expect(
        flag(lvl(0, '•', 720) + lvl(1, 'o', 1440, 'Courier New'), pushed),
        contains('indents'),
      );
      // Same place, different hang.
      expect(
        flag(
          lvl(0, '•', 720) + lvl(1, '•', 1440),
          '<w:ind w:left="1440" w:hanging="200"/>',
        ),
        contains('indents'),
      );
      // A list with a numbered level: counts could move.
      expect(
        flag(
          '${lvl(0, '•', 720)}'
          '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
          '<w:lvlText w:val="%2."/><w:pPr><w:ind w:left="1440" '
          'w:hanging="360"/></w:pPr></w:lvl>'
          '${lvl(2, '•', 1440)}',
          pushed,
        ),
        contains('indents'),
      );
    });
  });

  test('a paragraph hidden whole is not shown or counted, as in Word', () {
    const n =
        '<w:numbering $_w><w:abstractNum w:abstractNumId="0">'
        '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
        '<w:lvlText w:val="%1."/></w:lvl></w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
        '</w:numbering>';
    String item(String t, {bool hide = false}) {
      final v = hide ? '<w:rPr><w:vanish/></w:rPr>' : '';
      return '<w:p><w:pPr>$v<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
          '</w:numPr></w:pPr><w:r>$v<w:t>$t</w:t></w:r></w:p>';
    }

    final r = readDocx(
      _doc(item('a') + item('hid', hide: true) + item('b'), numbering: n),
    );
    // Word shows "1. a" and "2. b" (checked); still never saved over.
    expect(r.markdown, '1. a\n2. b');
    expect(r.unsupported, contains('hidden text'));
    expect(r.editable, isFalse);
  });

  group('Google Docs bullets', () {
    String numbering(List<String> glyphs) {
      final abs = StringBuffer();
      final nums = StringBuffer();
      for (var i = 0; i < glyphs.length; i++) {
        abs.write(
          '<w:abstractNum w:abstractNumId="$i"><w:lvl w:ilvl="0">'
          '<w:start w:val="1"/><w:numFmt w:val="bullet"/>'
          '<w:lvlText w:val="${glyphs[i]}"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
          '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr>'
          '</w:lvl></w:abstractNum>',
        );
        nums.write(
          '<w:num w:numId="${i + 1}"><w:abstractNumId w:val="$i"/></w:num>',
        );
      }
      return '<w:numbering $_w>$abs$nums</w:numbering>';
    }

    String item(String t, int numId) =>
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/>'
        '<w:numId w:val="$numId"/></w:numPr></w:pPr>'
        '<w:r><w:t>$t</w:t></w:r></w:p>';

    test('a dash list is editable and keeps its dash on save', () {
      final doc = _doc(
        item('Tickets', 1) + item('Charger', 1),
        numbering: numbering(['-']),
      );
      final r = readDocx(doc);
      expect(r.unsupported, isEmpty);
      expect(r.markdown, '- Tickets\n- Charger');
      final saved = writeDocxKeeping(('${r.markdown}\n- Water', doc));
      expect(_part(saved, 'word/numbering.xml'), contains('w:val="-"'));
      expect(readDocx(saved).markdown, '- Tickets\n- Charger\n- Water');
    });

    test('two bullet styles at one level stay as they are (read-only)', () {
      final r = readDocx(
        _doc(
          '${item('a', 1)}<w:p/>${item('b', 2)}',
          numbering: numbering(['●', '-']),
        ),
      );
      expect(r.unsupported, contains('bullet styles'));
    });
  });

  test('a real Google Docs file opens editable and saves as it looked', () {
    // Made in the Google Docs app (Android) and sent to Breeze: a heading,
    // bold, a dash list and a numbered list, Arial 11.
    final doc = _fixture('google_docs.docx');
    final r = readDocx(doc);
    expect(r.unsupported, isEmpty);
    expect(r.markdown, startsWith('# Trip plan\nBring **snacks**'));
    expect(r.markdown, contains('- Tickets\n- Charger\n1. Pack bags'));
    final edited = r.markdown.replaceFirst('- Charger', '- Charger\n- Water');
    final saved = writeDocxKeeping((edited, doc));
    expect(readDocx(saved).markdown, edited);
    expect(_part(saved, 'word/numbering.xml'), contains('w:val="-"'));
    expect(docxLook(saved)!.font, 'Arial');
  });
}
