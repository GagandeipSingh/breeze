/// The formatting Breeze understands, read straight from a note's text.
///
/// Like Windows Notepad, formatting is stored as Markdown, so the file stays
/// plain text any app can open:
///
///   # Heading 1   ## Heading 2   ### Heading 3
///   **bold**   *italic*   ***bold italic***   ~~strikethrough~~
///   <u>underline</u> (Markdown has no underline of its own; this HTML tag is
///   what Obsidian, Typora and GitHub draw as one)
///   - bullet (also * or +)   1. numbered (also 1) )   [text](link)
///
/// With escapes on (notes kept as Word or RTF files, whose text the user
/// never sees as Markdown), a backslash before ASCII punctuation makes that
/// character plain text, as in CommonMark: `\*not italic\*`, `\- not a
/// bullet`, `1\. not a number`. The backslash is a marker. Plain notes keep
/// every backslash as typed (a `\\server` path stays one).
///
/// One pass gives every consumer what it needs: [MdDoc.runs] cover the text
/// end to end in order (the editor styles them, read mode and PDF drop the
/// markers), [MdDoc.regions] say where each piece of inline formatting opens
/// and closes (the toolbar toggles them), and [MdDoc.lines] the line kinds.
/// Formatting never spans a line break.
library;

/// Flags on a run.
abstract final class Md {
  static const bold = 1;
  static const italic = 2;
  static const strike = 4;
  static const link = 8;

  /// Syntax (**, #, [, ](url)): dimmed while editing, hidden when reading.
  static const marker = 16;

  /// A list's bullet or number: shown everywhere, as • when reading.
  static const listMarker = 32;
  static const h1 = 64;
  static const h2 = 128;
  static const h3 = 256;
  static const heading = h1 | h2 | h3;
  static const underline = 512;

  /// A backslash escaping the character after it (with [marker]): Clear
  /// formatting keeps it, or the character would turn into formatting.
  static const escape = 1024;
}

class MdRun {
  const MdRun(this.start, this.end, this.flags);
  final int start;
  final int end;
  final int flags;
}

/// Where one piece of inline formatting opens and closes. [kind] is a set of
/// [Md] flags (***x*** is bold and italic at once).
class MdRegion {
  const MdRegion(
    this.kind,
    this.openStart,
    this.openEnd,
    this.closeStart,
    this.closeEnd,
  );
  final int kind;
  final int openStart;
  final int openEnd;
  final int closeStart;
  final int closeEnd;
}

enum MdLineKind { plain, h1, h2, h3, bullet, numbered }

class MdLine {
  const MdLine(this.start, this.end, this.prefixEnd, this.kind, this.indent);

  /// The line, without its newline.
  final int start;
  final int end;

  /// Where the heading or list marker (and its space) ends.
  final int prefixEnd;
  final MdLineKind kind;

  /// Leading spaces of a list item (nested lists keep them).
  final String indent;
}

class MdDoc {
  const MdDoc(this.text, this.lines, this.runs, this.regions);
  final String text;
  final List<MdLine> lines;
  final List<MdRun> runs;
  final List<MdRegion> regions;

  /// The line holding [offset].
  MdLine lineAt(int offset) {
    var lo = 0, hi = lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lines[mid].start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lines[lo];
  }

  /// The innermost region of [kind] holding [start]..[end] (its text, not
  /// its markers), or null.
  MdRegion? regionAround(int kind, int start, int end) {
    MdRegion? best;
    for (final r in regions) {
      if (r.kind & kind == 0) continue;
      if (r.openEnd <= start && end <= r.closeStart) {
        if (best == null || r.openEnd >= best.openEnd) best = r;
      }
    }
    return best;
  }
}

final _heading = RegExp(r'^(#{1,3}) ');
final _bullet = RegExp(r'^( *)([-*+]) ');
final _numbered = RegExp(r'^( *)(\d{1,4})([.)]) ');

final _inlineRe = RegExp(
  r'\[([^\]\n]+)\]\(([^)\s]+)\)' // 1: link text, 2: url
  r'|\*\*\*([^\s*].*?)\*\*\*' // 3: bold italic
  // 4: italic opening on a bold (***x** y*), only when that bold closes
  // inside it and no other lone * is in it (***Note:** see *this*).
  r'|(?<![*\\0-9])\*(\*\*[^\s*](?:(?:[^*]|\*\*)*?[^\s*])?\*\*(?:(?:[^*]|\*\*)*?[^\s*])?)\*(?![*0-9])'
  // 5: bold. May hold an italic right at its start (***x* y**); a space
  // may end it (deleting a last letter can leave one), never start it, so
  // "x ** 2" stays as written.
  r'|\*\*(\*?[^\s*].*?)\*\*(?!\*)'
  r'|~~([^\s~].*?)~~' // 6: strikethrough
  // 7: italic, which may end on a bold (*y **x***). Not between digits:
  // 2*3*4 stays as written.
  r'|(?<![*\\0-9])\*(?=[^\s*])(.+?)(?<=[^\s*]|[^\s*]\*\*)\*(?![*0-9])'
  r'|<u>(\s*\S.*?)</u>' // 8: underline
  // 9: italic as the bar writes it: tags like underline, so it never
  // runs into the ** of a bold beside it.
  r'|<i>(\s*\S.*?)</i>'
  // 10: italic with underscores (_x_), as Notepad and Markdown write it;
  // never inside a word, so snake_case_names stay as written.
  r'|(?<![A-Za-z0-9_\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![A-Za-z0-9_])',
);

/// The kind of one line, by its start.
MdLine mdLine(String text, int start, int end) {
  final line = text.substring(start, end);
  final h = _heading.firstMatch(line);
  if (h != null) {
    final kind = [
      MdLineKind.h1,
      MdLineKind.h2,
      MdLineKind.h3,
    ][h[1]!.length - 1];
    return MdLine(start, end, start + h.end, kind, '');
  }
  final n = _numbered.firstMatch(line);
  if (n != null) {
    return MdLine(start, end, start + n.end, MdLineKind.numbered, n[1]!);
  }
  final b = _bullet.firstMatch(line);
  if (b != null) {
    return MdLine(start, end, start + b.end, MdLineKind.bullet, b[1]!);
  }
  return MdLine(start, end, start, MdLineKind.plain, '');
}

/// [text] with each escape (backslash + ASCII punctuation) made inert: the
/// backslash becomes U+E000 and the character a private-use stand-in, so
/// no pattern can read either, and every offset stays the same.
String mdMaskEscapes(String text) {
  if (!text.contains('\\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    if (u == 0x5C &&
        i + 1 < text.length &&
        _escapable(text.codeUnitAt(i + 1))) {
      out
        ..writeCharCode(_escMark)
        ..writeCharCode(0xE100 + text.codeUnitAt(i + 1));
      i++;
    } else {
      out.writeCharCode(u);
    }
  }
  return out.toString();
}

const _escMark = 0xE000;

/// ASCII punctuation (CommonMark's escapable characters).
bool _escapable(int u) =>
    (u >= 0x21 && u <= 0x2F) ||
    (u >= 0x3A && u <= 0x40) ||
    (u >= 0x5B && u <= 0x60) ||
    (u >= 0x7B && u <= 0x7E);

MdDoc parseMd(String text, {bool escapes = false}) {
  if (escapes && text.contains('\\')) {
    final masked = mdMaskEscapes(text);
    if (!identical(masked, text) && masked != text) {
      final d = parseMd(masked);
      // Each escaping backslash is a marker of its own.
      final runs = <MdRun>[];
      for (final r in d.runs) {
        if (r.flags & (Md.marker | Md.listMarker) != 0) {
          runs.add(r);
          continue;
        }
        var a = r.start;
        for (var o = r.start; o < r.end; o++) {
          if (masked.codeUnitAt(o) != _escMark) continue;
          if (o > a) runs.add(MdRun(a, o, r.flags));
          runs.add(MdRun(o, o + 1, r.flags | Md.marker | Md.escape));
          a = o + 1;
        }
        if (r.end > a) runs.add(MdRun(a, r.end, r.flags));
      }
      return MdDoc(text, d.lines, runs, d.regions);
    }
  }
  final lines = <MdLine>[];
  final runs = <MdRun>[];
  final regions = <MdRegion>[];
  var start = 0;
  while (true) {
    final nl = text.indexOf('\n', start);
    final end = nl < 0 ? text.length : nl;
    final line = mdLine(text, start, end);
    lines.add(line);
    final lineFlag = switch (line.kind) {
      MdLineKind.h1 => Md.h1,
      MdLineKind.h2 => Md.h2,
      MdLineKind.h3 => Md.h3,
      _ => 0,
    };
    if (line.prefixEnd > start) {
      final isList =
          line.kind == MdLineKind.bullet || line.kind == MdLineKind.numbered;
      runs.add(
        MdRun(
          start,
          line.prefixEnd,
          lineFlag | (isList ? Md.listMarker : Md.marker),
        ),
      );
    }
    _inline(text, line.prefixEnd, end, lineFlag, runs, regions);
    if (nl < 0) break;
    runs.add(MdRun(nl, nl + 1, 0));
    start = nl + 1;
  }
  return MdDoc(text, lines, runs, regions);
}

/// Lines longer than this are not read for bold/italic/links: an unclosed
/// ** makes the search run to the line's end from every position, which on
/// a 30k-character line took seconds per key.
const mdMaxInlineLine = 4000;

void _inline(
  String text,
  int from,
  int to,
  int flags,
  List<MdRun> runs,
  List<MdRegion> regions,
) {
  if (from >= to) return;
  if (to - from > mdMaxInlineLine) {
    runs.add(MdRun(from, to, flags));
    return;
  }
  final s = text.substring(from, to);
  var pos = 0;
  for (final m in _inlineRe.allMatches(s)) {
    if (m.start > pos) runs.add(MdRun(from + pos, from + m.start, flags));
    final a = from + m.start, b = from + m.end;
    if (m[1] != null) {
      final textEnd = a + 1 + m[1]!.length;
      runs.add(MdRun(a, a + 1, flags | Md.marker));
      _inline(text, a + 1, textEnd, flags | Md.link, runs, regions);
      runs.add(MdRun(textEnd, b, flags | Md.marker));
      regions.add(MdRegion(Md.link, a, a + 1, textEnd, b));
    } else {
      // Opening and closing marker lengths (<u> and </u> differ).
      final (kind, o, c) = m[3] != null
          ? (Md.bold | Md.italic, 3, 3)
          : m[5] != null
          ? (Md.bold, 2, 2)
          : m[6] != null
          ? (Md.strike, 2, 2)
          : m[8] != null
          ? (Md.underline, 3, 4)
          : m[9] != null
          ? (Md.italic, 3, 4)
          : (Md.italic, 1, 1); // 4, 7 (*x*) and 10 (_x_)
      runs.add(MdRun(a, a + o, flags | Md.marker));
      _inline(text, a + o, b - c, flags | kind, runs, regions);
      runs.add(MdRun(b - c, b, flags | Md.marker));
      regions.add(MdRegion(kind, a, a + o, b - c, b));
    }
    pos = m.end;
  }
  if (pos < s.length) runs.add(MdRun(from + pos, to, flags));
}

/// The link address of the [Md.link] run at [offset], or null.
String? mdLinkAt(MdDoc doc, int offset) {
  for (final r in doc.regions) {
    if (r.kind == Md.link && r.openStart <= offset && offset < r.closeEnd) {
      final tail = doc.text.substring(r.closeStart, r.closeEnd); // ](url)
      return tail.substring(2, tail.length - 1);
    }
  }
  return null;
}

/// Whether formatting applies to a file of this extension: notes and
/// Markdown yes, code and data no (a `*` in JSON is not italic).
bool mdFormattable(String ext) => const {
  '',
  '.txt',
  '.md',
  '.markdown',
  '.text',
  '.note',
  '.rtf',
  '.docx',
}.contains(ext.toLowerCase());
