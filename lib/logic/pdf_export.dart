import 'dart:io' show File, Platform;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:intl/intl.dart' show Bidi;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'code_highlight.dart';
import 'markdown_lite.dart';

/// A note as a PDF, for Print and Share as PDF.
///
/// Rules, each from a way it broke:
/// - Inter (with real italics) carries Latin, Greek and Cyrillic as real,
///   selectable text; code uses Courier, a monospace font every PDF reader
///   has.
/// - EVERY language prints. A paragraph holding any other script (Hindi,
///   Arabic, Chinese, Tamil, Thai, ...) is drawn by the phone itself, which
///   has fonts and right-to-left layout for all of them, and placed as a
///   picture. Bundling a font per script would add tens of megabytes, and
///   the PDF library cannot lay out right-to-left or joined scripts anyway:
///   even with Noto Devanagari it printed हिन्दी as हन्दिी (the vowel sign
///   after the letter instead of before it).
/// - Those pictures are as narrow as their text and share a memory budget
///   ([_pixelBudget]): each one is held uncompressed until the PDF is saved,
///   and a long Hindi note drawn full-width at full sharpness ran to over a
///   gigabyte. Past the budget they are drawn less sharp, and past four
///   times it not at all (the bundled fonts take over).
/// - Emoji are in COLOUR, as in the app: each different one drawn once by
///   the phone, as a picture. Noto Emoji, black and white, covers anything
///   past [_maxEmoji] different ones.
/// - With [formatted], headings, bold, italic, strikethrough, lists and
///   links print as they look, and the Markdown syntax does not. With a
///   [codeLanguage], code prints in its syntax colours (light theme: paper
///   is white).
/// - The layout runs on a background isolate: a long note takes seconds and
///   would freeze the screen. Only the drawing needs the main one.
/// - A paragraph taller than a page cannot be laid out and throws, so lines
///   are cut into pieces sized to their type (a heading's are shorter), a
///   picture is never taller than [_maxImageHeight], and a word longer than
///   a line (a URL, minified JSON) is broken so it wraps.
/// - Windows line ends (\r\n) and tabs print as nothing and four spaces,
///   not as boxes; leading spaces keep their indentation.
/// - The page cap is far above any real note; past it the build fails and
///   the caller says so instead of crashing.
Future<Uint8List> buildNotePdf(
  String title,
  String text, {
  bool formatted = false,
  // A Word or RTF note: a backslash escapes punctuation (see parseMd).
  bool escapes = false,
  String? codeLanguage,
  // Off ("Code colours" off in Settings): code prints monospace, in black.
  bool colours = true,
}) async {
  final code = codeLanguage != null;
  final pieces = code && colours && text.length <= _maxCodeColour
      ? await CodeColourer.instance
            .colour(text, codeLanguage)
            .timeout(const Duration(seconds: 20), onTimeout: () => null)
      : null;
  if (Platform.isAndroid) {
    final native = await _nativePdf(
      title,
      text,
      formatted,
      code,
      pieces,
      escapes,
    );
    if (native != null) return native;
  }
  final fonts = await _fonts();
  final cover = code ? _courierCover : await _coverage(fonts);
  final paras = [
    _Para([(_clean(title), Md.h1, 0)], Md.h1),
    ...(code
        ? _codeParagraphs(text, pieces)
        : _paragraphs(text, formatted, escapes: escapes)),
  ];
  final emoji = <String, (Uint8List, double)>{};
  final images = <int, _Img>{};
  // Paragraphs drawn inside the picture of the one before them.
  final covered = <int>{};
  var pixels = 0;
  bool drawn(_Para p) =>
      !p.text.runes.every((r) => cover.contains(r) || _passes(r));
  for (var i = 0; i < paras.length; i++) {
    final para = paras[i];
    final rtl = Bidi.detectRtlDirectionality(para.text);
    if (rtl || drawn(para)) {
      if (pixels < _pixelBudget * 4) {
        final scale = pixels < _pixelBudget ? _scale : _scale / 2;
        // Neighbouring plain lines go into ONE picture with the same gaps:
        // a picture per line made a long Hindi note take many seconds.
        final group = [para];
        if (i > 0 && para.lineFlags & Md.heading == 0) {
          for (
            var j = i + 1;
            j < paras.length && group.length < _maxGroup;
            j++
          ) {
            final q = paras[j];
            if (q.lineFlags & Md.heading != 0) break;
            final qRtl = Bidi.detectRtlDirectionality(q.text);
            if (qRtl != rtl || !(qRtl || drawn(q))) break;
            group.add(q);
          }
        }
        final r = await _drawGroup(
          group,
          scale: scale,
          rtl: rtl,
          code: code,
          gap: code ? 1.5 : 5,
        );
        if (r != null) {
          final (img, used) = r;
          images[i] = img;
          pixels += img.pixels;
          for (var k = 1; k < used; k++) {
            covered.add(i + k);
          }
          i += used - 1;
          continue;
        }
      }
    }
    for (final c in para.text.characters) {
      if (emoji.length >= _maxEmoji) break;
      if (emoji.containsKey(c) || !_isEmoji(c)) continue;
      final png = await _emojiPng(c);
      if (png != null) emoji[c] = png;
    }
  }
  return Isolate.run(
    () => _build(title, paras, images, covered, fonts, emoji, code),
  );
}

const _native = MethodChannel('breeze/open');

/// The PDF made by Android (PdfMaker.kt): the phone lays the text out with
/// its own fonts, so every language and colour emoji print as on screen,
/// as real text, and fast. Null when it fails; the Dart PDF follows.
Future<Uint8List?> _nativePdf(
  String title,
  String text,
  bool formatted,
  bool code,
  List<(String, String?)>? pieces,
  bool escapes,
) async {
  try {
    final paras = [
      _Para([(_clean(title), Md.h1, 0)], Md.h1),
      ...(code
          ? _codeParagraphs(text, pieces, split: false)
          : _paragraphs(text, formatted, split: false, escapes: escapes)),
    ];
    final path = await _native.invokeMethod<String>('makePdf', {
      'code': code,
      'paras': [
        for (final p in paras)
          [
            p.lineFlags,
            for (final s in p.segs) ...[
              s.$1.replaceAll('\u00A0', ' '),
              s.$2,
              s.$3,
            ],
          ],
      ],
    });
    if (path == null) return null;
    final file = File(path);
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {}
    return bytes;
  } catch (_) {
    return null;
  }
}

// -- fonts ---------------------------------------------------------------

const _fontFiles = [
  'assets/fonts/Inter-Regular.ttf',
  'assets/fonts/Inter-Bold.ttf',
  'assets/fonts/Inter-Italic.ttf',
  'assets/fonts/Inter-BoldItalic.ttf',
  'assets/fonts/NotoSansDevanagari-Regular.ttf',
  'assets/fonts/NotoEmoji-Regular.ttf',
];

Future<List<Uint8List>> _fonts() async => [
  for (final f in _fontFiles) (await rootBundle.load(f)).buffer.asUint8List(),
];

/// Every character Inter can draw. Worked out once, off the main thread.
Set<int>? _cover;
Future<Set<int>> _coverage(List<Uint8List> fonts) async {
  final c = _cover;
  if (c != null) return c;
  final inter = fonts[0];
  final found = await Isolate.run(
    () =>
        TtfParser(ByteData.sublistView(inter)).charToGlyphIndexMap.keys.toSet(),
  );
  _cover = found;
  return found;
}

/// What the PDF's built-in Courier draws (Windows Latin-1).
final Set<int> _courierCover = {
  for (var r = 0x20; r <= 0x7E; r++) r,
  for (var r = 0xA0; r <= 0xFF; r++) r,
};

/// Characters that never need a font: spaces, controls and the invisible
/// joiners, plus emoji (drawn as pictures).
bool _passes(int r) =>
    r <= 0x20 ||
    r == 0xA0 ||
    (r >= 0x200B && r <= 0x200F) ||
    r == 0xFE0E ||
    r == 0xFE0F ||
    (r >= 0x1F3FB && r <= 0x1F3FF) ||
    _isEmoji(String.fromCharCode(r));

// -- paragraphs ----------------------------------------------------------

/// A styled piece: text, [Md] flags, colour (ARGB, 0 for the default).
typedef _Seg = (String, int, int);

/// One printed paragraph: styled pieces, and its line's flags (heading).
class _Para {
  _Para(this.segs, this.lineFlags);
  final List<_Seg> segs;
  final int lineFlags;
  String get text => segs.map((s) => s.$1).join();
}

/// Characters per paragraph at body size: well under one page even when
/// drawn as a picture. Bigger type gets proportionally fewer.
const _maxBlock = 800;

/// No \r (Windows line ends), tabs as four spaces.
String _clean(String s) => s.replaceAll('\r', '').replaceAll('\t', '    ');

/// Leading spaces as no-break spaces: PDF text drops ordinary ones at the
/// start of a line, which flattened every indented line.
String _keepIndent(String s) {
  var i = 0;
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  return i == 0 ? s : ' ' * i + s.substring(i);
}

/// [segs] as paragraphs of at most the block size for [lineFlags].
void _addLine(
  List<_Para> out,
  List<_Seg> segs,
  int lineFlags, {
  bool split = true,
}) {
  if (segs.isEmpty || segs.every((s) => s.$1.isEmpty)) {
    // A no-break space: a plain one gives the line no height.
    out.add(_Para([(' ', lineFlags, 0)], lineFlags));
    return;
  }
  final first = segs.first;
  segs = [(_keepIndent(first.$1), first.$2, first.$3), ...segs.skip(1)];
  // Android lays out and splits paragraphs across pages itself.
  if (!split) {
    out.add(_Para(segs, lineFlags));
    return;
  }
  final max = (_maxBlock * _bodySize / _sizeFor(lineFlags)).floor();
  var piece = <_Seg>[];
  var len = 0;
  for (final s in segs) {
    for (final part in _cut(s.$1, max)) {
      final n = part.characters.length;
      if (len + n > max && piece.isNotEmpty) {
        out.add(_Para(piece, lineFlags));
        piece = [];
        len = 0;
      }
      piece.add((part, s.$2, s.$3));
      len += n;
    }
  }
  if (piece.isNotEmpty) out.add(_Para(piece, lineFlags));
}

List<_Para> _paragraphs(
  String text,
  bool formatted, {
  bool split = true,
  bool escapes = false,
}) {
  final out = <_Para>[];
  if (!formatted) {
    for (final line in text.split('\n')) {
      _addLine(out, [(_clean(line), 0, 0)], 0, split: split);
    }
    return out;
  }
  final doc = parseMd(text, escapes: escapes);
  var ri = 0;
  for (final line in doc.lines) {
    final segs = <_Seg>[];
    var lineFlags = 0;
    while (ri < doc.runs.length && doc.runs[ri].start < line.end) {
      final r = doc.runs[ri++];
      if (r.start < line.start) continue;
      lineFlags |= r.flags & Md.heading;
      if (r.flags & Md.marker != 0) continue;
      var t = _clean(text.substring(r.start, r.end));
      if (r.flags & Md.listMarker != 0) {
        t = t.replaceFirst(RegExp(r'[-*+](?= $)'), '•');
      }
      segs.add((t, r.flags, 0));
    }
    // Skip the newline run.
    if (ri < doc.runs.length && doc.runs[ri].start == line.end) ri++;
    _addLine(out, segs, lineFlags, split: split);
  }
  return out;
}

/// Code in its syntax colours, line by line. Past [_maxCodeColour] it is
/// printed plain (colouring a huge file takes too long).
const _maxCodeColour = 300000;

/// [pieces] come from the background colourer (colouring a long file on
/// the main thread froze the app for seconds); null prints it plain.
List<_Para> _codeParagraphs(
  String text,
  List<(String, String?)>? pieces, {
  bool split = true,
}) {
  if (pieces == null) return _paragraphs(text, false, split: split);
  final out = <_Para>[];
  var line = <_Seg>[];
  for (final (t, scope) in pieces) {
    final st = codeStyle(scope, false);
    var flags = 0;
    if (st?.fontStyle == FontStyle.italic) flags |= Md.italic;
    if (st?.fontWeight == FontWeight.bold ||
        st?.fontWeight == FontWeight.w700) {
      flags |= Md.bold;
    }
    final colour = st?.color?.toARGB32() ?? 0;
    final parts = t.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        _addLine(out, line, 0, split: split);
        line = <_Seg>[];
      }
      final s = _clean(parts[i]);
      if (s.isNotEmpty) line.add((s, flags, colour));
    }
  }
  _addLine(out, line, 0, split: split);
  return out;
}

/// [s] in pieces of at most [size] characters (an emoji is one).
List<String> _cut(String s, int size) {
  final cs = s.characters;
  if (cs.length <= size) return [s];
  final out = <String>[];
  var rest = cs;
  while (rest.isNotEmpty) {
    out.add(rest.take(size).string);
    rest = rest.skip(size);
  }
  return out;
}

// -- page geometry and type --------------------------------------------

const _bodySize = 11.0;
final _format = PdfPageFormat.a4;
double get _contentWidth =>
    _format.width - _format.marginLeft - _format.marginRight;

double _sizeFor(int flags) => flags & Md.h1 != 0
    ? 18.0
    : flags & Md.h2 != 0
    ? 15.0
    : flags & Md.h3 != 0
    ? 13.0
    : _bodySize;

/// A picture paragraph is never taller than this (a page's text area is
/// about 730 points); a taller one is shrunk to fit.
const _maxImageHeight = 600.0;

// -- drawing on the main isolate --------------------------------------

/// More different emoji than this in one note get the outline font instead
/// of a picture each.
const _maxEmoji = 400;

/// Pixels per PDF point: sharp when printed, small enough to share.
const _scale = 3.0;

/// Picture pixels held at full sharpness (~4 bytes each until saved).
const _pixelBudget = 40000000;

class _Img {
  _Img(this.png, this.width, this.height, this.pixels);
  final Uint8List png;
  final double width;
  final double height;
  final int pixels;
}

/// Lines drawn together in one picture, at most this many...
const _maxGroup = 40;

/// ...and at most this tall (points): a picture cannot split across pages,
/// so a tall one would leave a gap at the foot of the page before it.
const _maxGroupHeight = 140.0;

/// Paragraphs drawn by the phone into one picture, as narrow as their
/// text, [gap] points apart (the PDF's own gap between paragraphs). Takes
/// the first and as many more as fit; returns the picture and how many.
Future<(_Img, int)?> _drawGroup(
  List<_Para> paras, {
  required double scale,
  required bool rtl,
  required bool code,
  required double gap,
}) async {
  final tps = <TextPainter>[];
  try {
    var height = 0.0;
    for (final para in paras) {
      final tp = TextPainter(
        text: TextSpan(
          children: [
            for (final s in para.segs)
              TextSpan(
                text: s.$1,
                style: _flutterStyle(s.$2 | para.lineFlags, s.$3, scale, code),
              ),
          ],
        ),
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textAlign: rtl ? TextAlign.right : TextAlign.left,
      )..layout(maxWidth: _contentWidth * scale);
      final next = height + (tps.isEmpty ? 0 : gap * scale) + tp.height;
      if (tps.isNotEmpty && next > _maxGroupHeight * scale) {
        tp.dispose();
        break;
      }
      tps.add(tp);
      height = next;
    }
    final w = tps.map((t) => t.width).reduce((a, b) => a > b ? a : b).ceil();
    final h = height.ceil();
    if (w == 0 || h == 0) return null;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    var y = 0.0;
    for (final tp in tps) {
      tp.paint(canvas, Offset(rtl ? w - tp.width : 0, y));
      y += tp.height + gap * scale;
    }
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) return null;
    var pw = w / scale, ph = h / scale;
    if (ph > _maxImageHeight) {
      pw *= _maxImageHeight / ph;
      ph = _maxImageHeight;
    }
    return (_Img(data.buffer.asUint8List(), pw, ph, w * h), tps.length);
  } finally {
    for (final tp in tps) {
      tp.dispose();
    }
  }
}

TextStyle _flutterStyle(int f, int colour, double scale, bool code) {
  final link = f & Md.link != 0;
  return TextStyle(
    fontFamily: code ? 'monospace' : 'Inter',
    color: colour != 0
        ? Color(colour)
        : link
        ? const Color(0xFF1A5FD0)
        : const Color(0xFF000000),
    fontSize: (code && f & Md.heading == 0 ? _codeSize : _sizeFor(f)) * scale,
    height: 1.45,
    fontWeight: f & (Md.bold | Md.heading) != 0
        ? FontWeight.w700
        : FontWeight.w400,
    fontStyle: f & Md.italic != 0 ? FontStyle.italic : FontStyle.normal,
    decoration: TextDecoration.combine([
      if (f & Md.strike != 0) TextDecoration.lineThrough,
      if (link || f & Md.underline != 0) TextDecoration.underline,
    ]),
  );
}

/// Code prints a little smaller, so more of a line fits.
const _codeSize = 9.5;

Future<(Uint8List, double)?> _emojiPng(String e) async {
  final tp = TextPainter(
    text: TextSpan(text: e, style: const TextStyle(fontSize: 72)),
    textDirection: TextDirection.ltr,
  )..layout();
  try {
    final w = tp.width.ceil();
    final h = tp.height.ceil();
    if (w == 0 || h == 0) return null;
    final rec = ui.PictureRecorder();
    tp.paint(Canvas(rec), Offset.zero);
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) return null;
    return (data.buffer.asUint8List(), w / h);
  } finally {
    tp.dispose();
  }
}

/// Whether one user-visible character is an emoji.
bool _isEmoji(String c) {
  for (final r in c.runes) {
    if (r == 0xFE0F || r == 0x200D || r == 0x20E3) return true;
    if (r >= 0x1F000 && r <= 0x1FAFF) return true;
    if (r >= 0x2600 && r <= 0x27BF) return true;
    if (r >= 0x2300 && r <= 0x23FF) return true;
    if (r >= 0x2B00 && r <= 0x2BFF) return true;
    if (r == 0x3030 || r == 0x303D || r == 0x3297 || r == 0x3299) return true;
  }
  return false;
}

// -- layout, on the background isolate --------------------------------

/// The invisible emoji helpers, dropped where an emoji falls back to the
/// outline font (it would draw them as stray marks).
final _emojiHelpers = RegExp(
  '[\u{FE0E}\u{FE0F}\u{200D}\u{1F3FB}-\u{1F3FF}]',
  unicode: true,
);

/// Longest run without a space that still wraps as a word.
const _maxWord = 40;

/// Breaks words longer than [_maxWord] with spaces so the line can wrap.
String _breakLongWords(String s) {
  if (s.length <= _maxWord) return s;
  return s.splitMapJoin(
    RegExp(
      r'\S{'
      '${_maxWord + 1}'
      r',}',
    ),
    onMatch: (m) => _cut(m[0]!, _maxWord).join(' '),
    onNonMatch: (t) => t,
  );
}

Future<Uint8List> _build(
  String title,
  List<_Para> paras,
  Map<int, _Img> images,
  Set<int> covered,
  List<Uint8List> fonts,
  Map<String, (Uint8List, double)> emoji,
  bool code,
) {
  pw.Font font(Uint8List b) => pw.Font.ttf(ByteData.sublistView(b));
  final inter = font(fonts[0]);
  final interBold = font(fonts[1]);
  final fallback = [font(fonts[4]), font(fonts[5])];
  final doc = pw.Document(
    title: title,
    theme: code
        ? pw.ThemeData.withFont(
            base: pw.Font.courier(),
            bold: pw.Font.courierBold(),
            italic: pw.Font.courierOblique(),
            boldItalic: pw.Font.courierBoldOblique(),
            fontFallback: fallback,
          )
        : pw.ThemeData.withFont(
            base: inter,
            bold: interBold,
            italic: font(fonts[2]),
            boldItalic: font(fonts[3]),
            fontFallback: fallback,
          ),
  );
  // One image object per emoji, however often it appears.
  final emojiImages = {
    for (final e in emoji.entries)
      e.key: (pw.MemoryImage(e.value.$1), e.value.$2),
  };

  double size(int f) => code && f & Md.heading == 0 ? _codeSize : _sizeFor(f);

  pw.TextStyle pdfStyle(int f, int colour, bool title) {
    final link = f & Md.link != 0;
    final decos = [
      if (f & Md.strike != 0) pw.TextDecoration.lineThrough,
      if (link || f & Md.underline != 0) pw.TextDecoration.underline,
    ];
    return pw.TextStyle(
      // The title is always Inter, also above code.
      font: title ? interBold : null,
      fontSize: size(f),
      fontWeight: f & (Md.bold | Md.heading) != 0
          ? pw.FontWeight.bold
          : pw.FontWeight.normal,
      fontStyle: f & Md.italic != 0 ? pw.FontStyle.italic : pw.FontStyle.normal,
      decoration: decos.isEmpty ? null : pw.TextDecoration.combine(decos),
      color: colour != 0
          ? PdfColor.fromInt(colour)
          : link
          ? PdfColor.fromInt(0xFF1A5FD0)
          : null,
    );
  }

  // A paragraph as spans: styled text, each drawn emoji as a picture.
  List<pw.InlineSpan> spans(_Para para, bool title) {
    final out = <pw.InlineSpan>[];
    for (final seg in para.segs) {
      final f = seg.$2 | para.lineFlags;
      final style = pdfStyle(f, seg.$3, title);
      final sz = size(f);
      final run = StringBuffer();
      void flush() {
        if (run.isEmpty) return;
        out.add(pw.TextSpan(text: run.toString(), style: style));
        run.clear();
      }

      for (final c in _breakLongWords(seg.$1).characters) {
        final img = emojiImages[c];
        if (img != null) {
          flush();
          final h = sz * 1.15;
          out.add(
            pw.WidgetSpan(
              baseline: -sz * 0.22,
              child: pw.Image(img.$1, height: h, width: h * img.$2),
            ),
          );
        } else if (_isEmoji(c)) {
          run.write(c.replaceAll(_emojiHelpers, ''));
        } else {
          run.write(c);
        }
      }
      flush();
    }
    if (out.isEmpty) out.add(const pw.TextSpan(text: ' '));
    return out;
  }

  pw.Widget paragraph(int i) {
    final para = paras[i];
    // A blank line keeps a line's height (Courier has no no-break space,
    // so in code it collapsed to nothing).
    if (i > 0 && para.text.trim().isEmpty) {
      return pw.SizedBox(height: size(para.lineFlags) * (code ? 1.2 : 1.45));
    }
    final img = images[i];
    if (img != null) {
      final picture = pw.Image(
        pw.MemoryImage(img.png),
        width: img.width,
        height: img.height,
      );
      return Bidi.detectRtlDirectionality(para.text)
          ? pw.Align(alignment: pw.Alignment.centerRight, child: picture)
          : picture;
    }
    return pw.RichText(
      text: pw.TextSpan(
        style: pw.TextStyle(
          fontSize: size(para.lineFlags),
          lineSpacing: code ? 1.5 : 3,
        ),
        children: spans(para, i == 0),
      ),
    );
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: _format,
      // The default caps a document at 20 pages and throws past it.
      maxPages: 10000,
      build: (ctx) => [
        pw.Header(level: 0, child: paragraph(0)),
        for (var i = 1; i < paras.length; i++)
          if (!covered.contains(i))
            pw.Padding(
              padding: pw.EdgeInsets.only(
                bottom: paras[i].lineFlags & Md.heading != 0
                    ? 7
                    : (code ? 1.5 : 5),
                top: paras[i].lineFlags & Md.heading != 0 ? 6 : 0,
              ),
              child: paragraph(i),
            ),
      ],
      footer: (ctx) => ctx.pagesCount > 1
          ? pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                '${ctx.pageNumber} / ${ctx.pagesCount}',
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey600,
                ),
              ),
            )
          : pw.SizedBox(),
    ),
  );
  return doc.save();
}
