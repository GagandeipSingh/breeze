import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:breeze/data/note_store.dart';
import 'package:breeze/logic/markdown_lite.dart';
import 'package:breeze/logic/rtf.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture(String name) {
  final bytes = File('test/fixtures/$name').readAsBytesSync();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

bool _same(String a, String b) {
  final x = mdToModel(a), y = mdToModel(b);
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (!x[i].sameAs(y[i])) return false;
  }
  return true;
}

void main() {
  group('files made by Word', () {
    test('formatting Breeze keeps is read and editable', () {
      final r = readRtf(_fixture('word_keep.rtf'));
      expect(r.unsupported, isEmpty);
      expect(
        r.markdown,
        '# Title हिंदी 🎉\n'
        '## Sub heading\n'
        'Plain then **bold** *italic* <u>under line</u> ~~strike~~ '
        'and ***both***.\n'
        '- Bullet one\n'
        '- Bullet two\n'
        '- Nested\n'
        'Between\n'
        '1. First\n'
        '2. Second\n'
        '3. Third\n'
        'See [Breeze site](https://example.com/a?b=1) now.\n'
        '<u>हिंदी रेखा</u> 😀 café €5',
      );
    });

    test('a file Breeze wrote, saved again by Word, reads the same', () {
      final r = readRtf(_fixture('word_resaved.rtf'));
      expect(r.unsupported, isEmpty);
      expect(r.markdown, contains('[**bold link**](https://a.b/c)'));
      expect(r.markdown, contains('  - nested two'));
      expect(r.markdown, contains('3. starts at three'));
    });

    test('what Breeze cannot keep is named, so the file is not edited', () {
      final r = readRtf(_fixture('word_lossy.rtf'));
      expect(r.editable, isFalse);
      expect(
        r.unsupported,
        containsAll(['colours', 'alignment', 'fonts', 'tables']),
      );
      expect(r.markdown, startsWith('Red words\nCentred\nMono font'));
    });
  });

  group('other writers', () {
    test('TextEdit: line ends by backslash, bold through a Bold font', () {
      final r = readRtf(_fixture('textedit.rtf'));
      expect(r.unsupported, isEmpty);
      final lines = r.markdown.split('\n');
      expect(lines[0], 'Hello **world** été €…”“‘’–—™');
      expect(lines[1], '- Item');
    });

    test('an old-style list (\\pn) reads as a list', () {
      const rtf =
          r'{\rtf1\ansi{\fonttbl{\f0 Arial;}}'
          r'{\pntext\f0 1.\tab}{\*\pn\pnlvlbody\pndec\pnstart1\pnindent360}One\par '
          r'{\pntext\f0 2.\tab}{\*\pn\pnlvlbody\pndec\pnstart1\pnindent360}Two\par '
          r'{\pntext\f0 \bullet\tab}{\*\pn\pnlvlblt}Dot\par}';
      final r = readRtf(rtf);
      expect(r.markdown, '1. One\n2. Two\n- Dot');
    });

    test('LibreOffice: list marker after the paragraph settings', () {
      expect(
        readRtf(_fixture('libreoffice_list.rtf')).markdown,
        '4. Four\n5. Five\n6. Six',
      );
    });

    test('a heading by style name, and a paragraph that looks like a list', () {
      const rtf =
          r'{\rtf1\ansi{\stylesheet{\s0 Normal;}{\s2 Heading 2;}}'
          r'\pard\s2 Title\par\pard - not a list in RTF\par}';
      final r = readRtf(rtf);
      expect(r.markdown, startsWith('## Title\n'));
      // A plain "- x" is written escaped, so it stays plain text.
      expect(r.unsupported, isEmpty);
      expect(r.markdown, endsWith('\n\\- not a list in RTF'));
      for (final (rtf, md) in [
        (r'{\rtf1\ansi\pard # of items\par}', r'\# of items'),
        (r'{\rtf1\ansi\pard 3. x\par}', r'3\. x'),
        (r'{\rtf1\ansi\pard   * y\par}', r'  \* y'),
      ]) {
        final x = readRtf(rtf);
        expect(x.editable, isTrue);
        expect(x.markdown, md);
        expect(readRtf(writeRtf(x.markdown)).markdown, md);
      }
    });

    group('found in review: never edited when saving would change it', () {
      String? flag(String rtf) {
        final r = readRtf(rtf);
        return r.unsupported.isEmpty ? null : r.unsupported.join('|');
      }

      test('bytes in another character set (WordPad Russian)', () {
        // Decoded by the font's character set, not as Windows-1252.
        final r = readRtf(
          r"{\rtf1\ansi\ansicpg1252{\fonttbl{\f1\fcharset204 Calibri;}}"
          r"\pard\f1\'cf\'f0\'e8\'e2\'e5\'f2\par}",
        );
        expect(r.markdown, 'Привет');
        expect(r.unsupported, isEmpty);
        expect(
          flag(r"{\rtf1\ansi{\fonttbl{\f1\fcharset2 Symbol;}}\pard\f1 J\par}"),
          contains('symbol fonts'),
        );
      });

      test('tracked changes: deleted text never comes back', () {
        final r = readRtf(
          r'{\rtf1\ansi\pard keep {\deleted\revauthdel1 GONE }end\par}',
        );
        expect(r.markdown, 'keep end');
        expect(r.unsupported, contains('tracked changes'));
      });

      test('numbered headings, list styles, custom bullets', () {
        const lists =
            r'{\*\listtable{\list{\listlevel\levelnfc0\levelstartat1}\listid1}}'
            r'{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}';
        expect(
          flag(
            '{\\rtf1\\ansi{\\stylesheet{\\s1 heading 1;}}$lists'
            r'{\listtext 1.\tab}\pard\s1\ls1 Intro\par}',
          ),
          contains('numbered headings'),
        );
        expect(
          flag('{\\rtf1\\ansi$lists{\\listtext (1)\\tab}\\pard\\ls1 a\\par}'),
          contains('list numbering styles'),
        );
        expect(
          flag('{\\rtf1\\ansi$lists{\\listtext 1.1.\\tab}\\pard\\ls1 a\\par}'),
          contains('list numbering styles'),
        );
        expect(
          flag(
            r'{\rtf1\ansi{\pntext A.\tab}{\*\pn\pnlvlbody\pnucltr}\pard a\par}',
          ),
          contains('list numbering styles'),
        );
        expect(
          flag(
            r'{\rtf1\ansi{\pntext \u10003?\tab}{\*\pn\pnlvlblt}\pard a\par}',
          ),
          contains('bullet styles'),
        );
      });

      test('a list carried only by its marker or its style', () {
        expect(
          readRtf(r'{\rtf1\ansi{\listtext 1.\tab}\pard First\par}').markdown,
          '1. First',
        );
      });

      test('a line break inside a list item', () {
        final r = readRtf(
          r'{\rtf1\ansi{\listtext 1.\tab}\pard\ls1 alpha\line beta\par}',
        );
        expect(r.unsupported, contains('line breaks in lists or headings'));
        expect(r.markdown, '1. alpha\nbeta');
      });

      test('underlined blanks on a form', () {
        expect(
          flag(r'{\rtf1\ansi Name: {\ul \tab\tab}\par}'),
          contains('underlined blanks'),
        );
      });

      test('bold on part of a heading', () {
        expect(
          flag(
            r'{\rtf1\ansi{\stylesheet{\s1 heading 1;}}\pard\s1 plain {\b bold} x\par}',
          ),
          contains('bold inside headings'),
        );
      });

      test('columns, borders, shading, equations, dark grey text', () {
        expect(flag(r'{\rtf1\ansi\cols2 a\column b\par}'), contains('columns'));
        expect(
          flag(r'{\rtf1\ansi\pard\brdrb\brdrs a\par}'),
          contains('borders or shading'),
        );
        expect(
          flag(r'{\rtf1\ansi x{\mmath{\*\moMath{\mr a+b}}}\par}'),
          contains('equations'),
        );
        expect(
          flag(
            r'{\rtf1\ansi{\colortbl;\red89\green89\blue89;}\pard\cf1 grey\par}',
          ),
          contains('colours'),
        );
      });

      test('a field with no result, and a link to a place', () {
        expect(
          flag(r'{\rtf1\ansi x{\field{\*\fldinst PAGE}{\fldrslt }}y\par}'),
          contains('fields'),
        );
        expect(
          flag(
            r'{\rtf1\ansi{\field{\*\fldinst HYPERLINK "http://a.com/x" \\l "sec"}{\fldrslt t}}\par}',
          ),
          contains('links inside the document'),
        );
      });

      test("damaged \\' escapes never crash or eat a brace", () {
        expect(readRtf(r"{\rtf1\ansi \pard a\'-1b\par}").markdown, 'a-1b');
        expect(readRtf(r"{\rtf1\ansi \pard a\'+Fb\par}").markdown, 'a+Fb');
        expect(
          readRtf(r"{\rtf1\ansi {\fonttbl{\f0\'-1 x;}}a\par}").markdown,
          'a',
        );
        expect(readRtf(r"{\rtf1\ansi {a\'4}b\par}").markdown, 'a4b');
      });

      test('a whole emoji in one \\u', () {
        expect(
          readRtf(
            r'{\rtf1\ansi a\'
            r'u128512?b\par}',
          ).markdown,
          'a😀b',
        );
      });

      test('C1 control characters save and read back', () {
        for (final md in ['café \u0085 next', 'a\u0096b', '\u0080\u009f']) {
          expect(readRtf(writeRtf(md)).markdown, md);
        }
      });

      test('Word counts lists itself: numbers survive without markers', () {
        // Word and LibreOffice ignore \listtext and count from each level's
        // start; with the markers removed, the reader counts the same way.
        const md =
            '1. a\n3. b\n- c\n7. d\n8. e\n  2. sub\n  3. sub\n9. f\n'
            'para\n4. again\n5. on\n  1. x';
        final rtf = writeRtf(md);
        final counted = rtf.replaceAll(RegExp(r'\{\\listtext[^}]*\}'), '');
        final cut = counted.indexOf(r'{\*\breezemd ');
        final end = counted.indexOf('}\n\\viewkind4');
        final foreign = counted.substring(0, cut) + counted.substring(end + 1);
        final r = readRtf(foreign);
        expect(r.unsupported, isEmpty);
        expect(_same(r.markdown, md), isTrue, reason: r.markdown);
      });

      test("another app's file is marked so editing asks first", () {
        expect(readRtf(_fixture('word_keep.rtf')).native, isFalse);
        expect(readRtf(writeRtf('**x**')).native, isTrue);
      });
    });

    group('found in the third review', () {
      // What Word sees: Breeze's file without its embedded note text.
      String foreign(String rtf) {
        final at = rtf.indexOf(r'{\*\breezemd');
        if (at < 0) return rtf;
        var depth = 0;
        var i = at;
        while (i < rtf.length) {
          final ch = rtf[i];
          if (ch == r'\') {
            i += 2;
            continue;
          }
          if (ch == '{') depth++;
          if (ch == '}' && --depth == 0) break;
          i++;
        }
        return rtf.substring(0, at) + rtf.substring(i + 1);
      }

      test('a formatted "# x", "- x" or "1. x" stays text, not a heading '
          'or list', () {
        for (final md in [
          '**# x**',
          '~~- milk~~',
          '*1. note*',
          '[# x](http://a.com)',
        ]) {
          final out = foreign(writeRtf(md));
          final r = readRtf(out);
          // Italic may come back spelled <i>...</i>: the same note.
          expect(
            modelToMd(mdToModel(r.markdown)),
            modelToMd(mdToModel(md)),
            reason: md,
          );
          expect(r.unsupported, isEmpty, reason: md);
          expect(rtfToModel(out).single.kind, MdLineKind.plain, reason: md);
        }
        // An unformatted one still is the list item it reads as.
        expect(
          rtfToModel(foreign(writeRtf('- milk'))).single.kind,
          MdLineKind.bullet,
        );
      });

      test('an fcharset0 font is Windows-1252 even under ansicpg1251', () {
        final rtf = latin1.decode([
          ...latin1.encode(
            r'{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\fcharset0 Calibri;}'
            r'{\f1\fcharset204 Calibri Cyr;}}\pard caf',
          ),
          ...latin1.encode(r"\'e9 {\f1 \'cf\'f0}\par}"),
        ]);
        final r = readRtf(rtf);
        expect(r.markdown, 'café Пр');
      });

      test('custom tab stops, frames, hidden marks and coloured links are '
          'reported', () {
        String? flag(String rtf) {
          final r = readRtf(rtf);
          return r.unsupported.isEmpty ? null : r.unsupported.join('|');
        }

        expect(
          flag(r'{\rtf1\ansi\pard\tx4321 Name\tab Value\par}'),
          contains('tab stops'),
        );
        // Default half-inch stops (TextEdit writes them) are fine.
        expect(
          flag(r'{\rtf1\ansi\pard\tx720\tx1440 Name\tab Value\par}'),
          isNull,
        );
        expect(
          flag(r'{\rtf1\ansi\pard\dropcapli3\dropcapt1 T\par}'),
          contains('text frames'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard one{\v\par}two\par}'),
          contains('hidden text'),
        );
        const red =
            r'{\rtf1\ansi{\colortbl;\red255\green0\blue0;}\pard '
            r'{\field{\*\fldinst HYPERLINK "http://a.com"}'
            r'{\fldrslt {\cf1 red link}}}\par}';
        expect(flag(red), contains('colours'));
        const blue =
            r'{\rtf1\ansi{\colortbl;\red5\green99\blue193;}\pard '
            r'{\field{\*\fldinst HYPERLINK "http://a.com"}'
            r'{\fldrslt {\cf1\ul blue link}}}\par}';
        expect(flag(blue), isNull);
        const dbl =
            r'{\rtf1\ansi\pard {\field{\*\fldinst HYPERLINK "http://a.com"}'
            r'{\fldrslt {\uldb x}}}\par}';
        expect(flag(dbl), contains('underline styles'));
      });

      test('em, en and quarter spaces keep their width', () {
        final r = readRtf(
          r'{\rtf1\ansi\pard a\emspace b\enspace c\qmspace d\par}',
        );
        expect(r.markdown, 'a b c d');
      });
    });

    group('found in the second review', () {
      // A backslash-u escape, built so no tool turns it into a character.
      String u(int n) => '${'\\'}u$n?';
      String? flag(String rtf) {
        final r = readRtf(rtf);
        return r.unsupported.isEmpty ? null : r.unsupported.join('|');
      }

      test('Word writes Russian and Greek as bytes: read right, editable', () {
        final r = readRtf(_fixture('word_scripts.rtf'));
        expect(r.unsupported, isEmpty);
        expect(r.markdown, contains('Привет αβγ done.'));
        expect(r.markdown, contains('क्या'));
      });

      test(
        'raw bytes follow the code page; Mac and unknown ones are not edited',
        () {
          final cyr = latin1.decode([
            ...latin1.encode(
              r'{\rtf1\ansi\ansicpg1251{\fonttbl{\f0 Arial;}}\pard ',
            ),
            0xCF,
            0xF0,
            0xE8,
            0xE2,
            0xE5,
            0xF2,
            ...latin1.encode(r'\par}'),
          ]);
          final r = readRtf(cyr);
          expect(r.markdown, 'Привет');
          expect(r.unsupported, isEmpty);
          final mac = latin1.decode([
            ...latin1.encode(r'{\rtf1\mac\pard '),
            0x8E,
            ...latin1.encode(r'\par}'),
          ]);
          expect(flag(mac), contains('text in another encoding'));
          expect(
            flag(
              r"{\rtf1\ansi{\fonttbl{\f1\fcharset128 MS Gothic;}}\pard\f1\'82\'a0\par}",
            ),
            contains('text in another encoding'),
          );
        },
      );

      test('links whose address holds a backslash-l save', () {
        for (final md in [
          r'[x](C:\l.txt)',
          r'[x](a\l)',
          r'[x](\\srv\l-1)',
          r'[x](\l)',
          '[t](\u0001)',
        ]) {
          expect(readRtf(writeRtf(md)).markdown, md);
        }
        expect(
          flag(
            r'{\rtf1\ansi{\field{\*\fldinst HYPERLINK "C:\\\\l.txt"}{\fldrslt x}}\par}',
          ),
          isNull,
        );
        expect(
          flag(
            r'{\rtf1\ansi{\field{\*\fldinst HYPERLINK "http://a" \\o "tip"}{\fldrslt x}}\par}',
          ),
          contains('link tooltips'),
        );
      });

      test('a Light or Black face is another font', () {
        expect(
          flag(
            r'{\rtf1\ansi{\fonttbl{\f0 Helvetica;}{\f1 Helvetica-Light;}}\pard\f0 normal {\f1 light} text\par}',
          ),
          contains('fonts'),
        );
        expect(
          flag(
            r'{\rtf1\ansi{\fonttbl{\f0 Helvetica;}{\f1 Helvetica-Bold;}}\pard\f0 normal {\f1\b bold} text\par}',
          ),
          isNull,
        );
      });

      test('size and font of Cyrillic, Greek and digits are judged', () {
        expect(
          flag(
            '{\\rtf1\\ansi\\pard ${u(1055)}${u(1088)} {\\fs72 ${u(1080)}${u(1074)}}\\par}',
          ),
          contains('text sizes'),
        );
        // Digits are not judged (Word sets one beside Hindi in the Hindi
        // size), so a word must carry the size.
        expect(
          flag(r'{\rtf1\ansi\pard Total {\fs96 Big}\par}'),
          contains('text sizes'),
        );
        expect(
          flag(
            '{\\rtf1\\ansi{\\fonttbl{\\f0 Arial;}{\\f1 Courier New;}}\\pard\\f0 abc {\\f1 ${u(945)}${u(946)}}\\par}',
          ),
          contains('fonts'),
        );
      });

      const table =
          r'{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}';
      String list(String level) =>
          '{\\*\\listtable{\\list{\\listlevel$level}\\listid1}}$table';

      test('list styles defined only in the list table', () {
        // No marker at all.
        expect(
          flag(
            '{\\rtf1\\ansi${list(r"\levelnfc255{\leveltext\'00;}")}\\pard\\ls1 item\\par}',
          ),
          contains('list numbering styles'),
        );
        // Legal numbering 1.1. and "Step 1:".
        expect(
          flag(
            '{\\rtf1\\ansi${list(r"\levelnfc0{\leveltext\'04\'00.\'00.;}")}\\pard\\ls1 a\\par}',
          ),
          contains('list numbering styles'),
        );
        expect(
          flag(
            '{\\rtf1\\ansi${list(r"\levelnfc0{\leveltext\'07Step \'00:;}")}\\pard\\ls1 a\\par}',
          ),
          contains('list numbering styles'),
        );
        // A ➢ bullet.
        expect(
          flag(
            '{\\rtf1\\ansi${list('\\levelnfc23{\\leveltext\\\'01${u(10146)};}')}\\pard\\ls1 a\\par}',
          ),
          contains('bullet styles'),
        );
        // A plain decimal list is fine, and starts where Word says.
        final r = readRtf(
          '{\\rtf1\\ansi${list(r"\levelnfc0\levelstartat5{\leveltext\'02\'00.;}")}'
          r'\pard\ls1 a\par\pard\ls1 b\par}',
        );
        expect(r.unsupported, isEmpty);
        expect(r.markdown, '5. a\n6. b');
      });

      test("Word's restart override and old-style starts and brackets", () {
        final r = readRtf(
          r"{\rtf1\ansi{\*\listtable{\list{\listlevel\levelnfc0{\leveltext\'02\'00.;}}\listid1}}"
          r'{\*\listoverridetable{\listoverride\listid1\listoverridecount1{\lfolevel\listoverridestartat\levelstartat3}\ls2}}'
          r'\pard\ls2 a\par\pard\ls2 b\par}',
        );
        expect(r.markdown, '3. a\n4. b');
        expect(
          readRtf(
            r'{\rtf1\ansi\pard{\*\pn\pnlvlbody\pndec\pnstart4}x\par'
            r'\pard{\*\pn\pnlvlbody\pndec\pnstart4}y\par}',
          ).markdown,
          '4. x\n5. y',
        );
        expect(
          flag(
            r'{\rtf1\ansi{\*\pn\pnlvlbody\pndec{\pntxtb (}{\pntxta )}}\pard x\par}',
          ),
          contains('list numbering styles'),
        );
      });

      test('section breaks, page break before, date fields', () {
        expect(
          flag(r'{\rtf1\ansi\pard One\par\sect\sectd\sbkpage\pard Two\par}'),
          contains('page breaks'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard\pagebb Two\par}'),
          contains('page breaks'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard Today is \chdate .\par}'),
          contains('fields'),
        );
      });

      test('indents, right-to-left, tab stops, spacing, index entries', () {
        expect(flag(r'{\rtf1\ansi\pard\fi720 a\par}'), contains('indents'));
        expect(flag(r'{\rtf1\ansi\pard\ri720 a\par}'), contains('indents'));
        expect(
          flag(
            r'{\rtf1\ansi{\stylesheet{\s1 heading 1;}}\pard\s1\li720 H\par}',
          ),
          contains('indents'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard\rtlpar a\par}'),
          contains('right-to-left text'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard\tqr\tx9000 a\tab b\par}'),
          contains('tab stops'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard {\expndtw20 a}\par}'),
          contains('text effects'),
        );
        expect(
          flag(r'{\rtf1\ansi\pard a{\xe {b}}\par}'),
          contains('index entries'),
        );
        // TextEdit's plain left tab stops on every paragraph are fine.
        expect(flag(r'{\rtf1\ansi\pard\tx720\tx1440 a\par}'), isNull);
      });
    });

    test('literal stars and underscores are not turned into formatting', () {
      final r = readRtf(r'{\rtf1\ansi **not bold** and _x_\par}');
      // Written escaped: editable, and saved back as the same characters.
      expect(r.editable, isTrue);
      expect(r.markdown, r'\*\*not bold\*\* and \_x\_');
      expect(readRtf(writeRtf(r.markdown)).markdown, r.markdown);
      // Text with nothing to escape is written as it is.
      expect(readRtf(r'{\rtf1\ansi 2*3 and a_b\par}').markdown, '2*3 and a_b');
      // A backslash of its own stays one.
      expect(readRtf(r'{\rtf1\ansi C:\\temp\par}').markdown, r'C:\temp');
    });

    test('pictures, headers, footnotes, comments, hidden text', () {
      final r = readRtf(
        r'{\rtf1\ansi{\header Head\par}A{\*\shppict{\pict\pngblip 89504e47}}'
        r'B{\footnote note}{\*\annotation c}{\v hid}\super 2\nosupersub\par}',
      );
      expect(
        r.unsupported,
        containsAll([
          'headers and footers',
          'pictures or objects',
          'footnotes',
          'comments',
          'hidden text',
          'superscript or subscript',
        ]),
      );
      expect(r.markdown, 'AB2');
    });

    test('a field that is not a link is kept as its text, and named', () {
      final r = readRtf(
        r'{\rtf1\ansi Page {\field{\*\fldinst PAGE}{\fldrslt 3}}\par}',
      );
      expect(r.markdown, 'Page 3');
      expect(r.unsupported, ['fields']);
    });

    test('\\bin data and \\u stand-ins are skipped', () {
      final r = readRtf(
        '{\\rtf1\\ansi\\uc2 a\\u2361\\\'3f\\\'3fb{\\*\\blob\\bin3 }}}}c\\par}',
      );
      expect(r.markdown, 'aहbc');
    });
  });

  group('Breeze writes, and reads back the same', () {
    const samples = [
      '',
      'plain',
      '\n\n',
      '# H1\n## H2\n### H3 **b** *i*',
      '**bold** *italic* ***both*** <u>under</u> ~~strike~~',
      '**a *b* c** and *a **b** c*',
      '<u>**~~*all four*~~**</u> then plain',
      '~~one two~~ <u>a b </u>end',
      '- one\n- two\n  - three\n    - four\n1. a\n2. b\n\n7. c\n8. d',
      '1) paren\n- **bold item**',
      '[link](https://x.y/z) [**bold link**](https://a.b) [<u>u</u>](u)',
      'not a link [x] (y) and [a](b c) and [q](a"b) and [w](C:\\dir\\f)',
      'हिंदी **बोल्ड** 😀👨‍👩‍👧 é € \u{1F389} \t tab',
      r'{braces} \back\slash\ \\ \u1234',
      'stars * alone ** and 2*3*4 and snake_case_name',
      '**unclosed bold and *unclosed italic',
      'control \u000b\u000c\u0000 chars',
      '   leading spaces\ttab',
      '#not heading\n-not list\n1.not list',
      '**   **  spaces in bold',
      '<u>   </u> only spaces underlined',
    ];
    for (final md in samples) {
      test(jsonEncode(md), () {
        final rtf = writeRtf(md);
        expect(rtf, startsWith(r'{\rtf1'));
        // ASCII only: any app, any code page.
        expect(rtf.codeUnits.every((c) => c < 0x80), isTrue);
        final back = readRtf(rtf);
        expect(back.unsupported, isEmpty);
        expect(_same(back.markdown, md), isTrue, reason: back.markdown);
      });
    }

    test('3000 random notes all save and read back', () {
      final rnd = Random(7);
      const bits = [
        'a',
        'word',
        ' ',
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
        '[t](http://e.com/p)',
        '#',
        '# ',
        '- ',
        '1. ',
        '  ',
        '\t',
        'हिंदी',
        '😀',
        'é',
        '{',
        '}',
        '\\',
        '"',
        '2',
        '***',
        'x_y',
        '`',
        '<',
        '>',
        '\u00a0',
        '\u200d',
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
        final String rtf;
        try {
          rtf = writeRtf(md);
        } catch (e) {
          fail('save failed for ${jsonEncode(md)}: $e');
        }
        final back = readRtf(rtf);
        expect(back.markdown, md.replaceAll('\r', '\n'));
        expect(back.editable, isTrue);
        // As another app would leave it (the note's own text dropped): the
        // document alone must read back as the note, or be refused for
        // editing. Never shown as something else and editable.
        final cut = rtf.indexOf(r'{\*\breezemd ');
        final end = rtf.indexOf('}\n\\viewkind4');
        final foreign = rtf.substring(0, cut) + rtf.substring(end + 1);
        final f = readRtf(foreign);
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
      // Most notes read back from the document alone too.
      expect(refused, lessThan(150));
    });
  });

  group('never crashes on a damaged file', () {
    test('random and cut-off input', () {
      final rnd = Random(3);
      final base = writeRtf('# T\n**b** [l](u)\n- x\n1. y\nहिंदी 😀');
      final word = _fixture('word_keep.rtf');
      const alphabet =
          r'{}\abcdefghijklmnopqrstuvwxyz0123456789-* ;'
          "'";
      for (var n = 0; n < 2000; n++) {
        final String s;
        switch (n % 3) {
          case 0:
            s = base.substring(0, rnd.nextInt(base.length + 1));
          case 1:
            final w = word.substring(0, rnd.nextInt(word.length + 1));
            s = w;
          default:
            s = String.fromCharCodes(
              List.generate(
                rnd.nextInt(200),
                (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
              ),
            );
        }
        readRtf('{\\rtf1 $s');
        readRtf(s);
        rtfPlainText(s);
      }
    });

    test('a huge number and deep nesting', () {
      readRtf(r'{\rtf1\fs99999999999999999999999 a\u99999999999999 b\par}');
      readRtf('{\\rtf1 ${'{' * 5000}x${'}' * 5000}}');
    });
  });

  group('the store', () {
    late Directory base;
    late NoteStore store;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('breeze_rtf');
      store = await NoteStore.openIn(base);
    });
    tearDown(() => base.delete(recursive: true));

    test('a new .rtf note is an RTF document; a .txt stays text', () async {
      final r = await store.create('Doc.rtf', content: '**b**', rtf: true);
      final raw = await r.file.readAsString();
      expect(looksLikeRtf(raw), isTrue);
      final t = await store.readText(r);
      expect(t.text, '**b**');
      expect(t.rtf!.editable, isTrue);
      final txt = await store.create('Note', content: '**b**', rtf: true);
      expect(await txt.file.readAsString(), '**b**');
      expect((await store.readText(txt)).rtf, isNull);
    });

    test('renamed .txt to .rtf becomes RTF, and back becomes text', () async {
      var n = await store.create('Plan', content: '# Hi\n*x*', rtf: true);
      expect(store.extFor(n, 'Plan.rtf'), '.rtf');
      n = await store.save(n, '# Hi\n*x*', newName: 'Plan.rtf', rtf: true);
      expect(n.fullName, 'Plan.rtf');
      expect(looksLikeRtf(await n.file.readAsString()), isTrue);
      expect((await store.readText(n)).text, '# Hi\n*x*');
      n = await store.save(n, '# Hi\n*x*', newName: 'Plan.md', rtf: true);
      expect(n.fullName, 'Plan.md');
      expect(await n.file.readAsString(), '# Hi\n*x*');
    });

    test('a plain text file named .rtf stays plain', () async {
      final f = File('${store.dir.path}/Old.rtf')
        ..writeAsStringSync('not rtf **here**');
      await store.refresh();
      final n = store.notes.firstWhere((x) => x.fullName == 'Old.rtf');
      final t = await store.readText(n);
      expect(t.rtf, isNull);
      expect(t.text, 'not rtf **here**');
      await store.save(n, 'changed', rtf: false);
      expect(f.readAsStringSync(), 'changed');
    });

    test('opening the same RTF twice reuses its copy', () async {
      final src = _fixture('word_keep.rtf');
      final a = await store.openIncoming('w.rtf', src);
      final b = await store.openIncoming('w.rtf', src);
      expect(b.file.path, a.file.path);
      expect(await a.file.readAsString(), src);
    });
  });

  test('looksLikeRtf', () {
    expect(looksLikeRtf(r'{\rtf1 x}'), isTrue);
    expect(looksLikeRtf('\uFEFF  \n{\\rtf1'), isTrue);
    expect(looksLikeRtf('just text named .rtf'), isFalse);
    expect(mdLine('x', 0, 1).kind, MdLineKind.plain);
  });

  test('a real Google Docs RTF opens editable', () {
    // Sent from the Google Docs app (Android). It names all six border
    // sides on every paragraph with no border style: nothing is drawn.
    final r = readRtf(_fixture('google_docs.rtf'));
    expect(r.unsupported, isEmpty);
    expect(
      r.markdown,
      '# Trip plan\nBring **snacks** and ,cold, water.\n- Tickets\n'
      '- Charger\n1. Pack bags\n2. Leave at 9:30\nDone.',
    );
    final saved = writeRtf('${r.markdown}\n- More');
    expect(readRtf(saved).markdown, '${r.markdown}\n- More');
  });

  test('a border shows only with a style', () {
    String doc(String words) => '{\\rtf1\\ansi{\\pard $words Hi\\par}}';
    expect(
      readRtf(doc('\\brdrt\\brdrb\\brdrw10\\brdrcf1')).unsupported,
      isEmpty,
    );
    expect(readRtf(doc('\\brdrb\\brdrnone')).unsupported, isEmpty);
    expect(
      readRtf(doc('\\brdrb\\brdrs\\brdrw10')).unsupported,
      contains('borders or shading'),
    );
    expect(
      readRtf(doc('\\chbrdr\\brdrdb')).unsupported,
      contains('borders or shading'),
    );
  });

  test('a border set in a style counts where the style is used', () {
    String doc(String style, String body) =>
        '{\\rtf1\\ansi{\\stylesheet{\\s0 Normal;}'
        '{\\s1$style Ruled;}}$body}';
    const ruled = '\\brdrb\\brdrs\\brdrw10';
    expect(
      readRtf(doc(ruled, '{\\pard\\s1 Hello\\par}')).unsupported,
      contains('borders or shading'),
    );
    expect(
      readRtf(doc('\\shading2000', '{\\pard\\s1 Hello\\par}')).unsupported,
      contains('borders or shading'),
    );
    // Defined and never used: nothing shows.
    expect(readRtf(doc(ruled, '{\\pard Hello\\par}')).unsupported, isEmpty);
  });
}
