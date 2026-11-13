/// Rich Text Format (.rtf), read and written by hand: no Dart package reads
/// it.
///
/// The editor always works on Markdown-lite text (markdown_lite.dart), so an
/// .rtf note is converted on the way in and on the way out, and the file on
/// disk stays real RTF that Word, LibreOffice and TextEdit open formatted.
///
/// Nothing is lost silently. Both directions go through one model
/// ([RtfPara]) and are checked by reading the result back:
///  * [readRtf] lists what Breeze cannot keep (tables, pictures, colours,
///    fonts...). A file with any of that is shown, never edited in place.
///  * [writeRtf] reads its own output back and throws if it differs, so a
///    save never replaces a file with something other than what was typed.
library;

import 'markdown_lite.dart';

/// Whether [text] is RTF source (an .rtf name alone is not enough: a plain
/// text file can carry that name, and stays plain).
bool looksLikeRtf(String text) {
  var i = 0;
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) i = 1;
  while (i < text.length && ' \t\r\n'.contains(text[i])) {
    i++;
  }
  return text.startsWith(r'{\rtf', i);
}

/// An .rtf file as the editor shows it.
class RtfRead {
  const RtfRead(this.markdown, this.unsupported, {this.native = true});

  /// The text, as Markdown-lite.
  final String markdown;

  /// What the file holds that Breeze cannot keep, in words for the user
  /// ("tables", "colours"). Empty means it can be edited and saved as is.
  final List<String> unsupported;

  /// Written by Breeze and unchanged since. Otherwise (Word, TextEdit, or
  /// Breeze's file edited elsewhere) its look - font, sizes, spacing, page
  /// layout - becomes Breeze's when saved, which the user is told first.
  final bool native;

  bool get editable => unsupported.isEmpty;
}

/// One paragraph: its kind and its characters (UTF-16 units), each with its
/// formatting ([Md] flags) and link.
class RtfPara {
  RtfPara(this.kind, this.level, this.number);
  MdLineKind kind;

  /// List nesting (0 = top).
  int level;

  /// A numbered item's number; 0 otherwise.
  int number;
  final units = <int>[];
  final attrs = <int>[];
  final links = <String?>[];

  void add(int unit, int attr, String? link) {
    units.add(unit);
    attrs.add(attr);
    links.add(link);
  }

  String get text => String.fromCharCodes(units);

  bool sameAs(RtfPara o) {
    if (kind != o.kind || level != o.level || number != o.number) return false;
    if (units.length != o.units.length) return false;
    for (var i = 0; i < units.length; i++) {
      if (units[i] != o.units[i] ||
          attrs[i] != o.attrs[i] ||
          links[i] != o.links[i]) {
        return false;
      }
    }
    return true;
  }
}

const _inlineFlags = Md.bold | Md.italic | Md.strike | Md.underline;

bool _sameModel(List<RtfPara> a, List<RtfPara> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!a[i].sameAs(b[i])) return false;
  }
  return true;
}

bool _space(int u) => u == 0x20 || u == 0x09 || u == 0xA0;

/// One spelling for things that look the same, so the comparisons judge
/// what the reader sees rather than how it was written:
///  * a heading is bold anyway, and a link underlined anyway;
///  * bold, italic and strike on a space count only between two characters
///    that carry them (Markdown cannot start or end them on a space);
///  * underline made only of spaces is dropped (Markdown cannot write it);
///  * a plain paragraph whose text starts like a list or a heading ("- x")
///    is that list or heading, which is how Markdown reads it.
void _normalize(RtfPara p) {
  for (var i = 0; i < p.links.length; i++) {
    final l = p.links[i];
    if (l != null) {
      // An address of only control characters is no address: plain text.
      final c = _cleanUrl(l);
      p.links[i] = c.isEmpty ? null : c;
    }
  }
  if (p.kind != MdLineKind.bullet && p.kind != MdLineKind.numbered) {
    p.level = 0;
  }
  if (p.kind != MdLineKind.numbered) p.number = 0;
  final n = p.units.length;
  final heading =
      p.kind == MdLineKind.h1 ||
      p.kind == MdLineKind.h2 ||
      p.kind == MdLineKind.h3;
  for (var i = 0; i < n; i++) {
    var a = p.attrs[i] & _inlineFlags;
    if (heading) a &= ~Md.bold;
    if (p.links[i] != null) a &= ~Md.underline;
    p.attrs[i] = a;
  }
  // Spaces: keep bold/italic/strike only when both neighbours (same link)
  // have it.
  for (var i = 0; i < n; i++) {
    if (!_space(p.units[i])) continue;
    var l = i - 1;
    while (l >= 0 && _space(p.units[l])) {
      l--;
    }
    var r = i + 1;
    while (r < n && _space(p.units[r])) {
      r++;
    }
    var keep = 0;
    if (l >= 0 &&
        r < n &&
        p.links[l] == p.links[i] &&
        p.links[r] == p.links[i]) {
      keep = p.attrs[l] & p.attrs[r] & (Md.bold | Md.italic | Md.strike);
    }
    p.attrs[i] = (p.attrs[i] & Md.underline) | keep;
  }
  // Underline made only of spaces.
  var i = 0;
  while (i < n) {
    if (p.attrs[i] & Md.underline == 0) {
      i++;
      continue;
    }
    var j = i;
    var any = false;
    while (j < n &&
        p.attrs[j] & Md.underline != 0 &&
        p.links[j] == p.links[i]) {
      if (!_space(p.units[j])) any = true;
      j++;
    }
    if (!any) {
      for (var k = i; k < j; k++) {
        p.attrs[k] &= ~Md.underline;
      }
    }
    i = j;
  }
}

int _levelOf(String indent) => (indent.length ~/ 2).clamp(0, 8);

// -- Markdown <-> model ---------------------------------------------------

/// The paragraphs [md] shows, normalized.
List<RtfPara> mdToModel(String md) {
  final doc = parseMd(
    md.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
    escapes: true,
  );
  final links = <(int, int, String)>[];
  for (final r in doc.regions) {
    if (r.kind != Md.link) continue;
    final tail = doc.text.substring(r.closeStart, r.closeEnd); // ](url)
    links.add((r.openEnd, r.closeStart, tail.substring(2, tail.length - 1)));
  }
  // Asked in text order, so one pass: scanning every link for every
  // character took seconds on a note with thousands of links.
  links.sort((a, b) => a.$1.compareTo(b.$1));
  var next = 0;
  String? linkAt(int o) {
    while (next < links.length && links[next].$2 <= o) {
      next++;
    }
    if (next < links.length && links[next].$1 <= o) return links[next].$3;
    return null;
  }

  final out = <RtfPara>[];
  var ri = 0;
  final runs = doc.runs;
  for (final line in doc.lines) {
    var number = 0;
    if (line.kind == MdLineKind.numbered) {
      final pre = doc.text.substring(line.start, line.prefixEnd);
      number = int.parse(RegExp(r'\d+').firstMatch(pre)![0]!);
    }
    final p = RtfPara(line.kind, _levelOf(line.indent), number);
    while (ri < runs.length && runs[ri].end <= line.start) {
      ri++;
    }
    while (ri < runs.length && runs[ri].start < line.end) {
      final run = runs[ri];
      if (run.flags & (Md.marker | Md.listMarker) == 0) {
        for (var o = run.start; o < run.end && o < line.end; o++) {
          final link = run.flags & Md.link != 0 ? linkAt(o) : null;
          p.add(doc.text.codeUnitAt(o), run.flags & _inlineFlags, link);
        }
      }
      if (run.end > line.end) break;
      ri++;
    }
    _normalize(p);
    out.add(p);
  }
  return out;
}

/// Markdown-lite that shows [paras] (already normalized).
///
/// Each paragraph is written so it reads back as itself: italic as tags
/// first, then as `*` or `_` when the text holds a lone `<i>` the tags
/// would pair with. A paragraph no spelling can show is written anyway
/// (the caller compares and refuses to edit it).
String modelToMd(List<RtfPara> paras) {
  final sb = StringBuffer();
  for (var k = 0; k < paras.length; k++) {
    if (k > 0) sb.write('\n');
    final p = paras[k];
    String? first;
    var line = '';
    var found = false;
    // Nested marks first (shortest); if no italic spelling reads back as
    // the same line (bold carried across italic's end), every change of
    // look closes and reopens all marks: longer, never ambiguous.
    for (final (reset, escape, spaces) in [
      (false, false, false),
      (true, false, false),
      (false, true, false),
      (true, true, false),
      (false, false, true),
      (false, true, true),
    ]) {
      for (final italic in _italics) {
        line = _paraMd(p, italic, reset: reset, escape: escape, spaces: spaces);
        first ??= line;
        final back = mdToModel(line);
        if (back.length == 1 && back.first.sameAs(p)) {
          found = true;
          break;
        }
      }
      if (found) break;
    }
    sb.write(found ? line : first);
  }
  return sb.toString();
}

/// Characters inline Markdown reads: \ * _ ~ < [ ] ` (escaped when an
/// escaped spelling is needed).
const _mdSpecial = {0x5C, 0x2A, 0x5F, 0x7E, 0x3C, 0x5B, 0x5D, 0x60};

/// ASCII punctuation: what a backslash escapes.
bool _punct(int u) =>
    (u >= 0x21 && u <= 0x2F) ||
    (u >= 0x3A && u <= 0x40) ||
    (u >= 0x5B && u <= 0x60) ||
    (u >= 0x7B && u <= 0x7E);

const _italics = [('*', '*'), ('_', '_'), ('<i>', '</i>')];

/// With [escape], every character Markdown could read as formatting is
/// written escaped (`\*`, `\_`, `\- ` at the start...).
String _paraMd(
  RtfPara p,
  (String, String) italic, {
  bool reset = false,
  bool escape = false,
  bool spaces = false,
}) {
  final sb = StringBuffer();
  switch (p.kind) {
    case MdLineKind.h1:
      sb.write('# ');
    case MdLineKind.h2:
      sb.write('## ');
    case MdLineKind.h3:
      sb.write('### ');
    case MdLineKind.bullet:
      sb.write('${'  ' * p.level}- ');
    case MdLineKind.numbered:
      sb.write('${'  ' * p.level}${p.number}. ');
    case MdLineKind.plain:
      break;
  }
  // Where a plain paragraph would start a heading or list ("# of items",
  // "- x", "3. y"): that character is escaped.
  var lead = -1;
  if (escape && p.kind == MdLineKind.plain) {
    final m = RegExp(r'^ *(#|[-*+]|\d{1,4}[.)])').firstMatch(p.text);
    if (m != null) lead = m.end - 1;
  }
  var i = 0;
  final n = p.units.length;
  while (i < n) {
    final link = p.links[i];
    var j = i;
    while (j < n && p.links[j] == link) {
      j++;
    }
    if (link == null) {
      _inlineMd(
        sb,
        p,
        i,
        j,
        italic,
        reset: reset,
        escape: escape,
        lead: lead,
        spaces: spaces,
      );
    } else {
      sb.write('[');
      _inlineMd(
        sb,
        p,
        i,
        j,
        italic,
        reset: reset,
        escape: escape,
        lead: lead,
        spaces: spaces,
      );
      sb.write('](${_cleanUrl(link)})');
    }
    i = j;
  }
  return sb.toString();
}

/// Outer to inner: underline, strike, bold, italic.
const _order = [Md.underline, Md.strike, Md.bold, Md.italic];

void _inlineMd(
  StringBuffer sb,
  RtfPara p,
  int from,
  int to,
  (String, String) italic, {
  bool reset = false,
  bool escape = false,
  int lead = -1,
  bool spaces = false,
}) {
  String open(int f) => switch (f) {
    Md.underline => '<u>',
    Md.strike => '~~',
    Md.bold => '**',
    _ => italic.$1,
  };
  String close(int f) => switch (f) {
    Md.underline => '</u>',
    Md.strike => '~~',
    Md.bold => '**',
    _ => italic.$2,
  };
  final stack = <int>[];
  for (var i = from; i < to; i++) {
    var want = p.attrs[i];
    // With [spaces], bold, italic or strike already open stays open over
    // spaces (a space carries none of them once read): "<u>  </u>" alone
    // could not be written.
    if (spaces && _space(p.units[i])) {
      for (final f in stack) {
        if (f & (Md.bold | Md.italic | Md.strike) != 0) want |= f;
      }
    }
    // Close from the first open one no longer wanted.
    var cut = stack.length;
    if (reset && i > from && want != p.attrs[i - 1]) cut = 0;
    for (var s = 0; s < stack.length; s++) {
      if (want & stack[s] == 0) {
        cut = s;
        break;
      }
    }
    while (stack.length > cut) {
      sb.write(close(stack.removeLast()));
    }
    for (final f in _order) {
      if (want & f != 0 && !stack.contains(f)) {
        stack.add(f);
        sb.write(open(f));
      }
    }
    final u = p.units[i];
    // A backslash needs one only before punctuation it would escape: the
    // next letter, or a marker or bracket written after it.
    final special = u == 0x5C
        ? !(i + 1 < to && p.attrs[i + 1] == want && !_punct(p.units[i + 1]))
        : _mdSpecial.contains(u);
    if (escape && (i == lead || special)) sb.write('\\');
    sb.writeCharCode(u);
  }
  while (stack.isNotEmpty) {
    sb.write(close(stack.removeLast()));
  }
}

/// A link address both Markdown and a Word field can hold: no spaces,
/// round brackets, quotes or control characters (each escaped as in a URL).
String _cleanUrl(String url) => url
    .replaceAll(RegExp(r'[\x00-\x08\x0a-\x1f]'), '')
    .replaceAll(' ', '%20')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll('"', '%22')
    .replaceAll('\t', '%09');

// -- reading RTF ----------------------------------------------------------

/// [rtf] as Markdown-lite, with what could not be kept.
RtfRead readRtf(String rtf) {
  final r = _Reader(rtf)..run();
  // Another app that saves an RTF drops Breeze's embedded text, so its
  // presence means Breeze wrote the file.
  return finishRead(
    r.paras,
    r.problems,
    embedded: r.embedded?.toString(),
    embeddedNative: true,
  );
}

/// The last step of reading any document (RTF, Word): its paragraphs as
/// Markdown, with what [found] and these checks say cannot be kept.
/// [embedded] is the note text Breeze stored in its own file, used while the
/// document still shows exactly that. [native]: Breeze wrote it, so its look
/// is Breeze's already; [embeddedNative] says the same when [embedded] is
/// taken (a Word document keeps it through Word's own saves, so there it
/// proves nothing about who wrote the file).
RtfRead finishRead(
  List<RtfPara> paras,
  List<String> found, {
  String? embedded,
  bool native = false,
  bool? embeddedNative,
}) {
  final problems = [...found];
  void problem(String what) {
    if (!problems.contains(what)) problems.add(what);
  }

  for (final p in paras) {
    // Underlined blanks ("Name: ______" made of spaces or tabs): Markdown
    // has no way to keep them.
    var i = 0;
    while (i < p.units.length) {
      if (p.attrs[i] & Md.underline == 0 || p.links[i] != null) {
        i++;
        continue;
      }
      var j = i, any = false;
      while (j < p.units.length &&
          p.attrs[j] & Md.underline != 0 &&
          p.links[j] == null) {
        if (!_space(p.units[j])) any = true;
        j++;
      }
      if (!any) problem('underlined blanks');
      i = j;
    }
    _normalize(p);
  }
  // Breeze's own file carries the note's text as typed. It is taken only
  // while the document still shows exactly that: after an edit in another
  // app it no longer does, and the document itself is read instead.
  final own = embedded;
  if (own != null && _sameModel(mdToModel(own), paras)) {
    return RtfRead(own, problems, native: embeddedNative ?? native);
  }
  final md = modelToMd(paras);
  // Text that Markdown would read as formatting (a literal ** or <u>):
  // shown differently, so it is not edited.
  if (!_sameModel(mdToModel(md), paras)) {
    problem('characters Breeze reads as formatting');
  }
  return RtfRead(md, problems, native: native);
}

/// Whether two notes' paragraphs read the same (as [mdToModel] gives them).
bool sameModel(List<RtfPara> a, List<RtfPara> b) => _sameModel(a, b);

/// The paragraphs of [rtf], normalized (for checks).
List<RtfPara> rtfToModel(String rtf) {
  final r = _Reader(rtf)..run();
  for (final p in r.paras) {
    _normalize(p);
  }
  return r.paras;
}

/// The visible text of [rtf], for previews and search.
String rtfPlainText(String rtf) {
  try {
    final r = _Reader(rtf)..run();
    return r.paras.map((p) => p.text).join('\n');
  } catch (_) {
    return '';
  }
}

class _Chr {
  bool b = false, i = false, ul = false, strike = false, hidden = false;
  bool effects = false, sup = false, ulStyle = false, dstrike = false;
  bool deleted = false;

  /// Letters spaced out, squeezed or stretched (\expnd, \charscalex).
  bool spacing = false;
  int f = -1, fs = 24, cf = 0, hl = 0, cb = 0;

  _Chr copy() => _Chr()
    ..b = b
    ..i = i
    ..ul = ul
    ..strike = strike
    ..hidden = hidden
    ..effects = effects
    ..sup = sup
    ..ulStyle = ulStyle
    ..dstrike = dstrike
    ..deleted = deleted
    ..spacing = spacing
    ..f = f
    ..fs = fs
    ..cf = cf
    ..hl = hl
    ..cb = cb;
}

enum _Dest {
  text,
  skip,
  fonttbl,
  colortbl,
  stylesheet,
  listtable,
  listoverridetable,
  fldinst,
  listtext,
  pn,
  embedded,
  leveltext,
  pntxt,
}

class _Field {
  final inst = StringBuffer();
  String? _url;
  bool _parsed = false;

  /// The link address, or null for a field that is not a web link.
  String? url(_Reader r) {
    if (_parsed) return _url;
    _parsed = true;
    final s = inst.toString().trim();
    final m = RegExp(
      r'^HYPERLINK\s+(.*)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(s);
    if (m == null) {
      if (s.isNotEmpty) r.problem('fields');
      return null;
    }
    var rest = m[1]!.trim();
    // Switches, outside the quoted address (a path "C:\\letters" holds a
    // backslash-l of its own): \l a place in a document, \o a tooltip.
    // Markdown keeps only the address.
    final switches = rest.replaceAll(RegExp(r'"[^"]*"'), '');
    if (RegExp(r'\\l\b').hasMatch(switches)) {
      r.problem('links inside the document');
      if (rest.startsWith(r'\l')) return null;
    }
    if (RegExp(r'\\o\b').hasMatch(switches)) r.problem('link tooltips');
    String? u;
    final q = RegExp(r'"([^"]*)"').firstMatch(rest);
    if (q != null) {
      u = q[1];
    } else {
      final t = rest.split(RegExp(r'\s+'));
      if (t.isNotEmpty && !t.first.startsWith(r'\')) u = t.first;
    }
    if (u == null || u.trim().isEmpty) return null;
    // Word writes a link's own backslashes doubled inside the quotes.
    _url = u.trim().replaceAll(r'\\', r'\');
    return _url;
  }
}

class _Group {
  _Group(this.c, this.dest, this.uc);
  _Chr c;
  _Dest dest;
  int uc;
  bool starred = false;
  bool sawWord = false;
  _Field? field;
  bool result = false;
  _Style? style;
  _Font? font;
  bool ownsStyle = false, ownsFont = false, ownsField = false;

  /// In a \pntxtb (before) or \pntxta (after) group: its text.
  StringBuffer? pnText;
  bool pnBefore = false;

  _Group child() => _Group(c.copy(), dest, uc)
    ..field = field
    ..result = result
    ..style = style
    ..font = font;
}

class _Style {
  int s = 0;
  bool para = true;
  int outline = -1;
  int ls = 0;

  /// Draws a border or shading (a paragraph using it shows one).
  bool border = false;
  final name = StringBuffer();
}

class _Font {
  int n = 0;

  /// -1 when the font names none: it follows the document's nsicpg.
  /// charset0 is ANSI (Windows-1252), whatever nsicpg says.
  int charset = -1;
  final name = StringBuffer();
}

class _List {
  int id = 0;
  final levels = <_Level>[];
}

class _Level {
  int nfc = 0, start = 1;

  /// \leveltext: a length, then the marker with each level's number as a
  /// character 0-8 (length 2, then level 0's number and a dot, is "1.").
  final text = StringBuffer();
}

class _Para {
  int s = 0, outline = -1, ls = 0, ilvl = 0, li = 0;
  bool align = false, table = false;
  int pn = 0; // 1 bullet, 2 numbered
  int pnLevel = 0, pnStart = 1;
  int fi = 0, ri = 0;
  bool rtl = false;

  /// A custom tab stop is set (see 'tx').
  bool tabs = false;
}

class _Visible {
  _Visible(this.font, this.fs, this.cf, this.hl);
  final int font, fs, cf, hl;
}

class _Reader {
  _Reader(this.s);
  final String s;
  final paras = <RtfPara>[];
  final problems = <String>[];

  void problem(String what) {
    if (!problems.contains(what)) problems.add(what);
  }

  final fonts = <int, String>{};

  /// Each font's \fcharset: bytes (\'hh) under a font of another character
  /// set (Russian 204, Greek 161, Symbol 2...) are not Windows-1252.
  final fontCharsets = <int, int>{};
  final colours = <(int, int, int)?>[];

  /// A link's colour that Breeze's own link look matches: none, black, or a
  /// blue (Word's hyperlink is 0563C1). A red or green link is a colour
  /// the rewrite would lose.
  bool _linkColour(int cf) {
    if (cf <= 0 || cf >= colours.length) return true;
    final c = colours[cf];
    if (c == null) return true;
    final (r, g, b) = c;
    if (r == 0 && g == 0 && b == 0) return true;
    return b > 100 && b > r + 40 && b > g + 20;
  }

  int _red = 0, _green = 0, _blue = 0;
  bool _colourSet = false;
  final styles = <int, _Style>{};
  final lists = <int, _List>{}; // by listid
  final overrides = <int, int>{}; // ls -> listid
  _List? _list;
  int _ovListId = 0;
  Map<int, int> _ovStarts = {};
  int _lfo = -1;

  /// Per \ls, the level starts its override sets (Word's "restart at").
  final overrideStarts = <int, Map<int, int>>{};

  /// Whether the last paragraph was an old-style (\pn) numbered item, so
  /// a new run starts again at its \pnstart.
  bool _prevPn = false;
  bool _inOverride = false;
  int deff = 0;
  int codepage = 1252;

  // The paragraph being read.
  var para = _Para();
  var cur = RtfPara(MdLineKind.plain, 0, 0);
  final visible = <_Visible?>[];
  final listText = StringBuffer();

  /// The note's own text, in a file Breeze wrote ({\*\breezemd ...}).
  StringBuffer? embedded;
  bool hasListText = false;
  final counters = <int, int>{};

  /// The paragraph after a \line: the rest of the one before, so plain.
  bool _continuation = false;

  late _Group g;
  final stack = <_Group>[];
  int skip = 0;

  void run() {
    g = _Group(_Chr(), _Dest.text, 1);
    var i = 0;
    final n = s.length;
    while (i < n) {
      final ch = s.codeUnitAt(i);
      if (ch == 0x7B) {
        // {
        stack.add(g);
        g = g.child();
        skip = 0; // a \u's stand-in never crosses a brace
        i++;
        if (s.startsWith(r'\*', i)) {
          g.starred = true;
          i += 2;
        }
        _openGroup();
        continue;
      }
      if (ch == 0x7D) {
        // }
        _closeGroup();
        skip = 0;
        i++;
        if (stack.isEmpty) break; // a stray brace
        g = stack.removeLast();
        continue;
      }
      if (ch == 0x5C) {
        i = _control(i + 1);
        continue;
      }
      i++;
      if (ch == 0x0D || ch == 0x0A) continue;
      if (skip > 0) {
        skip--;
        continue;
      }
      // A raw byte from an old writer (the file was read as Latin-1): a
      // letter of the document's code page, decoded like \'hh. A \u
      // character is what it says.
      if (ch >= 0x80 && ch <= 0xFF) {
        _byte(ch);
      } else {
        _text(ch);
      }
    }
    _endPara(force: false);
  }

  void _openGroup() {
    final parent = stack.last;
    if (parent.dest == _Dest.stylesheet && parent.style == null) {
      g.style = _Style();
      g.ownsStyle = true;
    }
    if (parent.dest == _Dest.fonttbl && parent.font == null) {
      g.font = _Font();
      g.ownsFont = true;
    }
  }

  void _closeGroup() {
    if (g.ownsStyle) {
      final st = g.style!;
      final name = st.name.toString().replaceAll(';', '').trim();
      st.name
        ..clear()
        ..write(name);
      if (st.para) styles[st.s] = st;
    }
    if (g.ownsFont) {
      _finishFont(g.font!);
    }
    // A field whose result was empty still has to be judged (a PAGE field
    // with no text would otherwise vanish unremarked).
    if (g.ownsField) g.field!.url(this);
    final pt = g.pnText;
    if (pt != null) {
      final t = pt.toString().trim();
      if (para.pn == 1) {
        if (g.pnBefore && t.isNotEmpty && !_bullets.contains(t)) {
          problem('bullet styles');
        }
      } else if (g.pnBefore ? t.isNotEmpty : (t.isNotEmpty && t != '.')) {
        problem('list numbering styles');
      }
    }
    if (g.dest == _Dest.colortbl && stack.isNotEmpty) {
      // A colour table that does not end in ';'.
      if (_colourSet) _pushColour();
    }
  }

  void _finishFont(_Font f) {
    final name = f.name.toString().replaceAll(';', '').trim();
    if (name.isNotEmpty || !fonts.containsKey(f.n)) fonts[f.n] = name;
    fontCharsets[f.n] = f.charset;
  }

  void _pushColour() {
    colours.add(_colourSet ? (_red, _green, _blue) : null);
    _red = _green = _blue = 0;
    _colourSet = false;
  }

  /// A control word or symbol starting at [i] (just after the backslash).
  /// Returns where reading goes on.
  int _control(int i) {
    final n = s.length;
    if (i >= n) return i;
    final c = s.codeUnitAt(i);
    final letter = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);
    if (!letter) {
      i++;
      switch (c) {
        case 0x5C: // \\
        case 0x7B: // \{
        case 0x7D: // \}
          if (skip > 0) {
            skip--;
          } else {
            _text(c);
          }
        case 0x27: // \'hh: exactly two hex digits, else nothing is read
          // (int.tryParse would take "-1" or "+F").
          if (i + 2 <= n &&
              _isHex(s.codeUnitAt(i)) &&
              _isHex(s.codeUnitAt(i + 1))) {
            final v = int.parse(s.substring(i, i + 2), radix: 16);
            i += 2;
            if (skip > 0) {
              skip--;
            } else {
              _byte(v);
            }
          }
        case 0x7E: // \~ no-break space
          if (skip > 0) {
            skip--;
          } else {
            _text(0xA0);
          }
        case 0x5F: // \_ no-break hyphen
          if (skip > 0) {
            skip--;
          } else {
            _text(0x2011);
          }
        case 0x0A:
        case 0x0D:
          _word('par', null);
        case 0x09:
          _word('tab', null);
        default:
          // \- \: \| \* elsewhere: nothing to show.
          break;
      }
      return i;
    }
    final start = i;
    while (i < n) {
      final d = s.codeUnitAt(i);
      if ((d >= 0x61 && d <= 0x7A) || (d >= 0x41 && d <= 0x5A)) {
        i++;
      } else {
        break;
      }
    }
    final word = s.substring(start, i);
    int? param;
    final ps = i;
    if (i < n && s.codeUnitAt(i) == 0x2D) i++;
    final ds = i;
    while (i < n && s.codeUnitAt(i) >= 0x30 && s.codeUnitAt(i) <= 0x39) {
      i++;
    }
    if (i > ds) {
      // A damaged file's 40-digit number is no number.
      param = i - ds > 10 ? null : int.tryParse(s.substring(ps, i));
    } else {
      i = ps;
    }
    if (i < n && s.codeUnitAt(i) == 0x20) i++;
    if (word == 'bin' && param != null && param > 0) {
      return (i + param).clamp(0, n);
    }
    if (word == 'u') {
      if (g.dest != _Dest.skip && param != null) {
        var u = param;
        if (u < 0) u += 65536;
        if (u > 0xFFFF && u <= 0x10FFFF) {
          // A writer that put a whole emoji in one \u: two UTF-16 units.
          u -= 0x10000;
          _text(0xD800 + (u >> 10));
          _text(0xDC00 + (u & 0x3FF));
        } else if (u >= 0 && u <= 0xFFFF) {
          _text(u);
        }
      }
      skip = g.uc;
      return i;
    }
    if (skip > 0) {
      skip--;
      return i;
    }
    final first = !g.sawWord;
    g.sawWord = true;
    if (g.dest == _Dest.skip) return i;
    _word(word, param, first: first);
    return i;
  }

  static const _skipDests = {
    'info',
    'generator',
    'xmlnstbl',
    'rsidtbl',
    'themedata',
    'colorschememapping',
    'latentstyles',
    'datastore',
    'filetbl',
    'revtbl',
    'userprops',
    'template',
    'docvar',
    'pgdsctbl',
    'mmathPr',
    'falt',
    'panose',
    'fname',
    'levelnumbers',
    'listname',
    'listpicture',
    'nonshppict',
    'bkmkstart',
    'bkmkend',
    'datafield',
    'formfield',
    'ftnsep',
    'ftnsepc',
    'aftnsep',
    'aftnsepc',
    'ftncn',
    'aftncn',
    'wgrffmtfilter',
    'pnseclvl',
    'expandedcolortbl',
    'passwordhash',
    'protusertbl',
    'keycode',
    'title',
    'subject',
    'author',
    'operator',
    'keywords',
    'comment',
    'doccomm',
    'company',
  };

  static const _pictureDests = {
    'pict',
    'shppict',
    'object',
    'shp',
    'shpinst',
    'shptxt',
    'objdata',
    'do',
    'blipuid',
  };

  static const _headerDests = {
    'header',
    'headerl',
    'headerr',
    'headerf',
    'footer',
    'footerl',
    'footerr',
    'footerf',
  };

  void _word(String w, int? p, {bool first = false}) {
    final on = p == null || p != 0;
    // Destinations.
    switch (w) {
      case 'fonttbl':
        g.dest = _Dest.fonttbl;
        return;
      case 'colortbl':
        g.dest = _Dest.colortbl;
        return;
      case 'stylesheet':
        g.dest = _Dest.stylesheet;
        return;
      case 'listtable':
        g.dest = _Dest.listtable;
        return;
      case 'listoverridetable':
        g.dest = _Dest.listoverridetable;
        return;
      case 'field':
        g.field = _Field();
        g.ownsField = true;
        g.result = false;
        return;
      case 'mmath' || 'moMath' || 'moMathPara':
        problem('equations');
        g.dest = _Dest.skip;
        return;
      case 'oldcprops' || 'oldpprops' || 'oldsprops' || 'oldtprops':
        problem('tracked changes');
        g.dest = _Dest.skip;
        return;
      case 'fldinst':
        g.dest = _Dest.fldinst;
        return;
      case 'fldrslt':
        g.result = true;
        g.dest = _Dest.text;
        return;
      case 'listtext':
      case 'pntext':
        g.dest = _Dest.listtext;
        listText.clear();
        hasListText = true;
        return;
      case 'pn':
        g.dest = _Dest.pn;
        return;
      case 'breezemd':
        g.dest = _Dest.embedded;
        embedded = StringBuffer();
        return;
      case 'leveltext':
        if (g.dest == _Dest.listtable && (_list?.levels.isNotEmpty ?? false)) {
          g.dest = _Dest.leveltext;
        } else {
          g.dest = _Dest.skip;
        }
        return;
      case 'pntxta' || 'pntxtb':
        // The text after (a) and before (b) an old-style list number:
        // "(" and ")" make "(1)", which Markdown cannot write.
        if (g.dest == _Dest.pn) {
          g.dest = _Dest.pntxt;
          g.pnBefore = w == 'pntxtb';
          g.pnText = StringBuffer();
        } else {
          g.dest = _Dest.skip;
        }
        return;
      case 'xe' || 'tc' || 'txe':
        problem('index entries');
        g.dest = _Dest.skip;
        return;
      case 'footnote':
        problem('footnotes');
        g.dest = _Dest.skip;
        return;
      case 'annotation':
      case 'atnid':
      case 'atnauthor':
      case 'atrfstart':
        problem('comments');
        g.dest = _Dest.skip;
        return;
    }
    if (_skipDests.contains(w)) {
      g.dest = _Dest.skip;
      return;
    }
    if (_pictureDests.contains(w)) {
      problem('pictures or objects');
      g.dest = _Dest.skip;
      return;
    }
    if (_headerDests.contains(w)) {
      problem('headers and footers');
      g.dest = _Dest.skip;
      return;
    }
    switch (g.dest) {
      case _Dest.fonttbl:
        if (w == 'f') {
          final f = g.font ?? (g.font = _Font());
          if (!g.ownsFont && g.font != null && f.name.isNotEmpty) {
            _finishFont(f);
            g.font = _Font();
          }
          g.font!.n = p ?? 0;
        } else if (w == 'fcharset') {
          (g.font ??= _Font()).charset = p ?? 0;
        }
        return;
      case _Dest.colortbl:
        if (w == 'red') {
          _red = p ?? 0;
          _colourSet = true;
        } else if (w == 'green') {
          _green = p ?? 0;
          _colourSet = true;
        } else if (w == 'blue') {
          _blue = p ?? 0;
          _colourSet = true;
        }
        return;
      case _Dest.stylesheet:
        final st = g.style;
        if (st == null) return;
        if (w == 's') {
          st.s = p ?? 0;
        } else if (w == 'cs' || w == 'ds' || w == 'ts' || w == 'tsrowd') {
          st.para = false;
        } else if (w == 'outlinelevel') {
          st.outline = p ?? -1;
        } else if (w == 'ls') {
          st.ls = p ?? 0; // a list carried by the style ("List Number")
        } else if (w.startsWith('brdr') && !_noBorder.contains(w) ||
            const {'box', 'cbpat', 'cfpat', 'shading', 'chshdng'}.contains(w) &&
                (p ?? 1) != 0) {
          // Judged where a paragraph uses the style, not here: a style
          // nobody uses shows nothing.
          st.border = true;
        }
        return;
      case _Dest.listtable:
        if (w == 'list') {
          _list = _List();
        } else if (w == 'listlevel') {
          _list?.levels.add(_Level());
        } else if ((w == 'levelnfc' || w == 'levelnfcn') && _list != null) {
          final l = _list!.levels;
          if (l.isNotEmpty) l.last.nfc = p ?? 0;
        } else if (w == 'levelstartat' && _list != null) {
          final l = _list!.levels;
          if (l.isNotEmpty) l.last.start = p ?? 1;
        } else if (w == 'listid' && _list != null) {
          _list!.id = p ?? 0;
          lists[_list!.id] = _list!;
        }
        return;
      case _Dest.listoverridetable:
        if (w == 'listoverride') {
          _inOverride = true;
          _ovListId = 0;
          _ovStarts = {};
          _lfo = -1;
        } else if (w == 'listid' && _inOverride) {
          _ovListId = p ?? 0;
        } else if (w == 'lfolevel') {
          _lfo++;
        } else if (w == 'levelstartat' && _lfo >= 0) {
          // "Restart numbering at": Word's override of a level's start.
          _ovStarts[_lfo] = p ?? 1;
        } else if (w == 'listoverrideformat' || w == 'listlevel') {
          // The override redefines a level's look.
          problem('list numbering styles');
        } else if (w == 'ls' && _inOverride) {
          overrides[p ?? 0] = _ovListId;
          overrideStarts[p ?? 0] = _ovStarts;
        }
        return;
      case _Dest.leveltext:
        if (w == 'uc') g.uc = (p ?? 1).clamp(0, 10);
        return;
      case _Dest.pntxt:
        return;
      case _Dest.pn:
        if (w == 'pnstart') {
          para.pnStart = p ?? 1;
        } else if (w == 'pnlvlblt') {
          para.pn = 1;
        } else if (w == 'pnlvlbody') {
          para.pn = 2;
        } else if (w == 'pnlvl') {
          para.pn = 2;
          para.pnLevel = ((p ?? 1) - 1).clamp(0, 8);
        } else if (w == 'pnucltr' ||
            w == 'pnlcltr' ||
            w == 'pnucrm' ||
            w == 'pnlcrm' ||
            w == 'pnord' ||
            w == 'pncard') {
          // A., a., I., i. lists: Markdown numbers only 1. 2. 3.
          problem('list numbering styles');
        }
        return;
      case _Dest.skip:
        return;
      case _Dest.fldinst:
      case _Dest.listtext:
      case _Dest.embedded:
      case _Dest.text:
        break;
    }
    // An unknown starred destination: skip it whole.
    if (g.starred && first && !_known.contains(w)) {
      g.dest = _Dest.skip;
      return;
    }
    // How many stand-ins follow each Unicode character: it governs reading
    // in a list marker or field code too (TextEdit writes \uc0 there).
    if (w == 'uc') {
      g.uc = (p ?? 1).clamp(0, 10);
      return;
    }
    final char = _chars[w];
    if (char != null) {
      _text(char);
      return;
    }
    // In a list marker or a field's code only characters count: a \pard
    // inside a list marker must not undo the paragraph's own list.
    if (g.dest != _Dest.text) return;
    final c = g.c;
    switch (w) {
      case 'rtf':
      case 'ansi':
        break;
      case 'ansicpg':
        codepage = p ?? 1252;
      case 'mac':
      case 'pc':
      case 'pca':
        codepage = -1;
      case 'deff':
        deff = p ?? 0;
        c.f = deff;
      case 'uc':
        g.uc = (p ?? 1).clamp(0, 10);
      case 'par':
        // A hidden paragraph mark joins two paragraphs in Word.
        if (g.c.hidden) problem('hidden text');
        _endPara(force: true);
      case 'line':
        // A line break inside a paragraph: Markdown has none, so the rest
        // becomes a plain paragraph of its own. Inside a list item or a
        // heading that would make a new item or a lost heading line.
        if (para.ls > 0 || para.pn > 0 || hasListText || _headingNow()) {
          problem('line breaks in lists or headings');
        }
        _endPara(force: true);
        _continuation = true;
      case 'column':
        problem('columns');
        _endPara(force: true);
      case 'cols':
        if ((p ?? 1) > 1) problem('columns');
      case 'deleted':
        // Tracked changes: deleted text must not come back as text.
        c.deleted = on;
        if (on) problem('tracked changes');
      case 'revised':
        if (on) problem('tracked changes');
      case 'box' || 'cbpat' || 'cfpat' || 'shading' || 'chshdng':
        if ((p ?? 1) != 0) problem('borders or shading');
      case 'sect':
        // A section break: a new page in Word unless continuous, and its
        // page settings. Markdown has neither.
        problem('page breaks');
        if (cur.units.isNotEmpty) _endPara(force: true);
      case 'pagebb':
        if (on) problem('page breaks');
      case 'chdate' || 'chtime' || 'chpgn' || 'chdpl' || 'chdpa':
        // The date, the time or the page number, filled in when shown.
        problem('fields');
      case 'dropcapli' ||
          'dropcapt' ||
          'pvpara' ||
          'pvpg' ||
          'pvmrg' ||
          'phpg' ||
          'phmrg' ||
          'phcol' ||
          'posx' ||
          'posy' ||
          'posxc' ||
          'posxr' ||
          'posyc' ||
          'posyb' ||
          'absw' ||
          'absh':
        // A drop cap or a positioned frame of text.
        problem('text frames');
      case 'fi':
        para.fi = p ?? 0;
      case 'ri':
        para.ri = p ?? 0;
      case 'rtlpar':
        para.rtl = true;
      case 'ltrpar':
        para.rtl = false;
      case 'tqr' ||
          'tqc' ||
          'tqdec' ||
          'tldot' ||
          'tlhyph' ||
          'tlul' ||
          'tlth' ||
          'tleq' ||
          'tlmdot':
        // Right, centred or decimal tab stops, or dotted leaders.
        problem('tab stops');
      case 'tx' || 'tb':
        // A left tab stop off the default half-inch grid moves the text
        // after a tab; judged once the paragraph shows a tab.
        if ((p ?? 0) % 720 != 0) para.tabs = true;
      case 'ulc':
        final k = p ?? 0;
        if (k > 0 && k < colours.length) {
          final col = colours[k];
          if (col != null && (col.$1 > 0 || col.$2 > 0 || col.$3 > 0)) {
            problem('colours');
          }
        }
      case 'expnd' || 'expndtw' || 'charscalex':
        c.spacing = w == 'charscalex' ? (p ?? 100) != 100 : (p ?? 0) != 0;
      case 'page':
        problem('page breaks');
        if (cur.units.isNotEmpty) _endPara(force: true);
      case 'pard':
        para = _Para();
      case 'plain':
        g.c = _Chr()..f = deff;
      case 'b':
        c.b = on;
      case 'i':
        c.i = on;
      case 'ul':
        c.ul = on;
        c.ulStyle = false;
      case 'ulnone':
        c.ul = false;
        c.ulStyle = false;
      case 'uld' ||
          'uldash' ||
          'uldashd' ||
          'uldashdd' ||
          'uldb' ||
          'ulhwave' ||
          'ulldash' ||
          'ulth' ||
          'ulthd' ||
          'ulthdash' ||
          'ulthdashd' ||
          'ulthdashdd' ||
          'ulthldash' ||
          'ululdbwave' ||
          'ulw' ||
          'ulwave':
        c.ul = on;
        c.ulStyle = on;
      case 'strike':
        c.strike = on;
      case 'striked':
        c.strike = on;
        c.dstrike = on;
      case 'caps' || 'scaps' || 'outl' || 'shad' || 'embo' || 'impr':
        c.effects = on;
      case 'v':
        c.hidden = on;
      case 'super' || 'sub':
        c.sup = true;
      case 'nosupersub':
        c.sup = false;
      case 'up' || 'dn':
        c.sup = (p ?? 6) != 0;
      case 'f':
        c.f = p ?? 0;
      case 'fs':
        c.fs = p ?? 24;
      case 'cf':
        c.cf = p ?? 0;
      case 'highlight':
        c.hl = p ?? 0;
      case 'cb' || 'chcbpat':
        c.cb = p ?? 0;
      case 's':
        para.s = p ?? 0;
      case 'outlinelevel':
        para.outline = p ?? -1;
      case 'ls':
        para.ls = p ?? 0;
      case 'ilvl':
        para.ilvl = (p ?? 0).clamp(0, 8);
      case 'li':
        para.li = p ?? 0;
      case 'qc' || 'qr' || 'qj' || 'qd' || 'qk' || 'qt':
        para.align = true;
      case 'ql':
        para.align = false;
      case 'intbl' || 'trowd' || 'itap':
        if (w != 'itap' || (p ?? 0) > 0) {
          para.table = true;
          problem('tables');
        }
      case 'cell' || 'nestcell':
        _text(0x09);
      case 'row' || 'nestrow':
        _endPara(force: true);
      case 'chftn':
        problem('footnotes');
      default:
        // Paragraph and character borders. A border shows only with a
        // style (\brdrs, \brdrdb, \brdrdot...): the side (\brdrt, \chbrdr),
        // width and colour alone draw nothing, and Google Docs writes all
        // six sides bare on every paragraph.
        if (w.startsWith('brdr') && !_noBorder.contains(w)) {
          problem('borders or shading');
        }
    }
  }

  /// A list level's marker as the list table defines it, for writers that
  /// leave no \listtext: only "N." and a plain bullet are Markdown's.
  /// "1.1.", "Step 1:", "(1)" and a ➢ bullet are other styles.
  void _checkTemplate(_Level lv, int level, bool numbered) {
    final t = lv.text.toString();
    if (t.isEmpty) return; // no template given: nothing to judge
    final n = t.codeUnitAt(0);
    final body = t.substring(1, (1 + n).clamp(1, t.length));
    if (numbered) {
      if (body != String.fromCharCodes([level, 0x2E])) {
        problem('list numbering styles');
      }
    } else if (!_bullets.contains(body)) {
      problem('bullet styles');
    }
  }

  /// Whether the paragraph being read is a heading.
  bool _headingNow() {
    final o = para.outline;
    if (o >= 0 && o <= 8) return true;
    final st = styles[para.s];
    if (st == null) return false;
    return (st.outline >= 0 && st.outline <= 8) ||
        RegExp(
          r'^heading\s*\d$',
          caseSensitive: false,
        ).hasMatch(st.name.toString());
  }

  static const _chars = {
    'tab': 0x09,
    'emdash': 0x2014,
    'endash': 0x2013,
    'bullet': 0x2022,
    'lquote': 0x2018,
    'rquote': 0x2019,
    'ldblquote': 0x201C,
    'rdblquote': 0x201D,
    'emspace': 0x2003,
    'enspace': 0x2002,
    'qmspace': 0x2005,
    'zwj': 0x200D,
    'zwnj': 0x200C,
  };

  static bool _isHex(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);

  /// Bullets that are just "a bullet": Word's (Symbol ·, Courier o,
  /// Wingdings §), TextEdit's and LibreOffice's (• ◦ ▪), and Breeze's own.
  static const _bullets = {
    '•',
    '·',
    'o',
    '§',
    '▪',
    '◦',
    '-',
    '–',
    '*',
    '\uF0B7',
    '\uF06F',
    '\uF0A7',
  };

  static const _known = {
    'fldinst',
    'listtext',
    'pn',
    'pntext',
    'listtable',
    'listoverridetable',
    'fonttbl',
    'colortbl',
    'stylesheet',
  };

  static const _cp1252 = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, //
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
  ];

  void _byte(int v) {
    if (v < 0x80) {
      _text(v);
      return;
    }
    // A byte means a letter of the font's character set (Word writes
    // Russian as bytes in a "Calibri Cyr" font of \fcharset204), or for a
    // plain font of the document's \ansicpg. Decoded with that code page;
    // one Breeze does not have (Japanese, Mac...) is not edited, since
    // reading it as Windows-1252 would give the wrong letters.
    final cs = fontCharsets[g.c.f] ?? -1;
    if (cs == 2) {
      // A symbol font: the byte is a picture (judged in _text).
      _text(v < 0xA0 ? _cp1252[v - 0x80] : v);
      return;
    }
    final cp = cs < 0 || cs == 1
        ? codepage
        : cs == 0
        ? 1252
        : (_charsetPages[cs] ?? -1);
    if (cp == 1252 || cp == 0) {
      _text(v < 0xA0 ? _cp1252[v - 0x80] : v);
      return;
    }
    final table = _codePages[cp];
    final u = table == null ? 0xFFFD : table[v - 0x80];
    if (u == 0xFFFD) {
      if (g.dest == _Dest.text) problem('text in another encoding');
      _text(v < 0xA0 ? _cp1252[v - 0x80] : v);
      return;
    }
    _text(u);
  }

  /// \fcharset to its Windows code page.
  static const _charsetPages = {
    238: 1250,
    204: 1251,
    161: 1253,
    162: 1254,
    177: 1255,
    178: 1256,
    186: 1257,
    163: 1258,
    222: 874,
  };

  void _text(int u) {
    switch (g.dest) {
      case _Dest.skip:
      case _Dest.pn:
      case _Dest.listtable:
      case _Dest.listoverridetable:
        return;
      case _Dest.fonttbl:
        final f = g.font ?? (g.font = _Font());
        if (u == 0x3B) {
          _finishFont(f);
          if (!g.ownsFont) g.font = _Font();
        } else {
          f.name.writeCharCode(u);
        }
        return;
      case _Dest.colortbl:
        if (u == 0x3B) _pushColour();
        return;
      case _Dest.stylesheet:
        g.style?.name.writeCharCode(u);
        return;
      case _Dest.fldinst:
        g.field?.inst.writeCharCode(u);
        return;
      case _Dest.listtext:
        listText.writeCharCode(u);
        return;
      case _Dest.embedded:
        embedded?.writeCharCode(u);
        return;
      case _Dest.leveltext:
        final l = _list?.levels;
        if (l != null && l.isNotEmpty) l.last.text.writeCharCode(u);
        return;
      case _Dest.pntxt:
        g.pnText?.writeCharCode(u);
        return;
      case _Dest.text:
        break;
    }
    if (stack.isEmpty) return; // outside the document
    final c = g.c;
    final raw = u;
    if (c.deleted) return; // deleted by a tracked change (flagged)
    if (c.hidden) {
      if (!_space(raw)) problem('hidden text');
      return;
    }
    final link = g.result ? g.field?.url(this) : null;
    var a = 0;
    if (c.b) a |= Md.bold;
    if (c.i) a |= Md.italic;
    if (c.ul) a |= Md.underline;
    if (c.strike) a |= Md.strike;
    cur.add(raw, a, link);
    final shows = !_space(raw);
    if (shows) {
      // Symbol and Wingdings letters are pictures, not the letters stored.
      if ((fontCharsets[c.f] ?? 0) == 2) problem('symbol fonts');
      if (c.sup) problem('superscript or subscript');
      if (c.effects || c.spacing) problem('text effects');
      if (c.ulStyle) problem('underline styles');
      if (c.dstrike) problem('double strikethrough');
    }
    visible.add(
      shows
          ? _Visible(
              c.f,
              c.fs,
              link != null && _linkColour(c.cf) ? -1 : c.cf,
              c.hl + (c.cb > 0 ? 1000 + c.cb : 0),
            )
          : null,
    );
  }

  void _endPara({required bool force}) {
    if (!force && cur.units.isEmpty && !hasListText) return;
    final pp = para;
    if (pp.tabs && cur.units.contains(0x09)) problem('tab stops');
    var kind = MdLineKind.plain;
    var level = 0;
    var number = 0;
    // Heading: the paragraph's own outline level, else its style's.
    var outline = pp.outline;
    final st = styles[pp.s];
    if (st != null && st.border) problem('borders or shading');
    if (outline < 0 || outline > 8) {
      outline = st?.outline ?? -1;
      final m = RegExp(
        r'^heading\s*(\d)$',
        caseSensitive: false,
      ).firstMatch(st?.name.toString() ?? '');
      if ((outline < 0 || outline > 8) && m != null) {
        outline = int.parse(m[1]!) - 1;
      }
    }
    // The rest of a paragraph after a \line: plain text (flagged there when
    // it broke a list item or a heading).
    final continuation = _continuation;
    _continuation = false;
    if (continuation) outline = -1;
    if (outline >= 0 && outline <= 8) {
      if (outline > 2) problem('more than three heading levels');
      kind = [MdLineKind.h1, MdLineKind.h2, MdLineKind.h3][outline.clamp(0, 2)];
    }
    // The marker as shown ("1.", "•"), without its tab.
    final lt = listText.toString().replaceAll('\t', '').trim();
    final ltNum = RegExp(r'^\d{1,6}').firstMatch(lt);
    // A list by its own \ls, its style's (Word's "List Number"), an old
    // \pn, or only a marker that another writer left.
    final ls = pp.ls > 0 ? pp.ls : (st?.ls ?? 0);
    // An \ls naming no list that exists shows no marker in Word: not a
    // list, unless a marker was written beside it.
    final known = ls > 0 && lists[overrides[ls]] != null;
    final isList =
        !continuation && (known || pp.pn > 0 || (hasListText && lt.isNotEmpty));
    if (isList && kind != MdLineKind.plain) {
      // "1. Introduction" as a Heading 1: Markdown has numbers or headings.
      problem('numbered headings');
    } else if (isList) {
      var numbered = pp.pn == 2 || (pp.pn == 0 && ls == 0 && ltNum != null);
      level = ls > 0 ? pp.ilvl : pp.pnLevel;
      var startAt = pp.pn > 0 ? pp.pnStart : 1;
      if (ls > 0) {
        final list = lists[overrides[ls]];
        if (list != null && level < list.levels.length) {
          final lv = list.levels[level];
          final nfc = lv.nfc;
          // 255: no marker at all, which Markdown cannot show.
          if (nfc == 255) problem('list numbering styles');
          numbered = nfc != 23 && nfc != 255;
          startAt = overrideStarts[ls]?[level] ?? lv.start;
          if (numbered && nfc != 0 && nfc != 22) {
            problem('list numbering styles');
          }
          _checkTemplate(lv, level, numbered);
        } else {
          numbered = ltNum != null;
        }
      }
      if (numbered) {
        // Markdown writes "3." and nothing else: "(3)", "3)", "1.2." are
        // other styles.
        if (lt.isNotEmpty && !RegExp(r'^\d{1,4}\.$').hasMatch(lt)) {
          problem('list numbering styles');
        }
      } else if (lt.isNotEmpty && !_bullets.contains(lt)) {
        // A tick, an arrow, a picture bullet: Markdown has one bullet.
        problem('bullet styles');
      }
      kind = numbered ? MdLineKind.numbered : MdLineKind.bullet;
      // An old-style list starts again at its \pnstart after anything
      // that is not one of its items.
      if (ls == 0 && pp.pn > 0 && !_prevPn) {
        for (var d = 0; d < 9; d++) {
          counters.remove(d);
        }
      }
      if (numbered) {
        final key = ls * 16 + level;
        final next = ltNum != null
            ? int.parse(ltNum[0]!)
            : (counters[key] ?? startAt - 1) + 1;
        counters[key] = next;
        for (var d = level + 1; d < 9; d++) {
          counters.remove(ls * 16 + d);
        }
        number = next;
      }
    }
    final shows = visible.any((v) => v != null);
    // Indents of plain paragraphs and headings (a list's own are its
    // levels): left, right, and first line.
    if (shows && !isList && (pp.li > 0 || pp.ri > 0 || pp.fi != 0)) {
      problem('indents');
    }
    if (pp.align && shows) problem('alignment');
    if (pp.rtl && shows) problem('right-to-left text');
    _prevPn = isList && ls == 0 && pp.pn > 0;
    cur
      ..kind = kind
      ..level = level
      ..number = number;
    final heading =
        kind != MdLineKind.plain &&
        kind != MdLineKind.bullet &&
        kind != MdLineKind.numbered;
    if (heading) {
      // A heading is bold as a whole; one bold word in it would be lost.
      var bold = false, plain = false;
      for (var i = 0; i < cur.units.length; i++) {
        if (_space(cur.units[i]) || cur.links[i] != null) continue;
        if (cur.attrs[i] & Md.bold != 0) {
          bold = true;
        } else {
          plain = true;
        }
      }
      if (bold && plain) problem('bold inside headings');
    }
    _checkLooks(heading);
    paras.add(cur);
    cur = RtfPara(MdLineKind.plain, 0, 0);
    visible.clear();
    listText.clear();
    hasListText = false;
  }

  // Fonts, sizes and colours in body text, checked across the document.
  final _bodyFonts = <String>{};
  final _bodySizes = <int>{};

  /// What a heading or body text looks like beyond what Breeze keeps.
  ///  * Colour: body text must be plain (black or automatic). A heading may
  ///    wear its style's colour (Word's are blue), but only one.
  ///  * Size and font: one for all body text. Read on Latin letters only:
  ///    Word sets Hindi and emoji in their own font, at their own size (14pt
  ///    beside 11pt), which is Word's default and not the writer's choice.
  void _checkLooks(bool heading) {
    final headingColours = <int>{};
    for (var i = 0; i < visible.length; i++) {
      final v = visible[i];
      if (v == null) continue;
      if (v.hl != 0) problem('highlighting');
      // -1: plain. A link's colour is the link's own.
      var colour = -1;
      if (v.cf > 0 && v.cf < colours.length) {
        final c = colours[v.cf];
        // Any colour but black: a dark grey is chosen too, and would be lost.
        if (c != null && (c.$1 > 0 || c.$2 > 0 || c.$3 > 0)) {
          colour = c.$1 << 16 | c.$2 << 8 | c.$3;
        }
      }
      if (heading) {
        if (v.cf >= 0) headingColours.add(colour);
        if (headingColours.length > 1) problem('colours');
        continue;
      }
      if (colour != -1) problem('colours');
      // Letters of the scripts Word sets in the body font (Latin, Greek,
      // Cyrillic). Punctuation and digits are not judged: next to Hindi,
      // Word sets a "?" or the 5 of "€5" in the Hindi font and size.
      final u = cur.units[i];
      final body =
          (u >= 0x41 && u <= 0x5A) ||
          (u >= 0x61 && u <= 0x7A) ||
          (u >= 0xC0 && u < 0x250 && u != 0xD7 && u != 0xF7) ||
          (u >= 0x370 && u < 0x530);
      if (!body) continue;
      _bodySizes.add(v.fs);
      if (_bodySizes.length > 1) problem('text sizes');
      _bodyFonts.add(_family(fonts[v.font] ?? fonts[deff] ?? ''));
      if (_bodyFonts.length > 1) problem('fonts');
    }
  }

  static String _family(String name) {
    var n = name.toLowerCase().trim();
    // The bold and italic faces of a family are the same look plus a
    // weight Breeze keeps (TextEdit names them "Helvetica-Bold"); a Light
    // or Black face is another look, and stays a different name.
    n = n.replaceFirst(
      RegExp(
        r'-(bold|italic|oblique|boldoblique|bolditalic|regular|roman)(mt)?$',
      ),
      '',
    );
    n = n.replaceFirst(RegExp(r'mt$'), '');
    // Word's script copies of one font: "Calibri Cyr", "Calibri Greek"...
    n = n.replaceFirst(
      RegExp(
        r' (cyr|greek|ce|tur|baltic|\(vietnamese\)|\(arabic\)|\(hebrew\))$',
      ),
      '',
    );
    for (final s in [' bold', ' italic', ' oblique', ' regular']) {
      n = n.replaceAll(s, '');
    }
    return n.trim();
  }
}

// -- writing RTF ----------------------------------------------------------

/// [md] as RTF. Reads its own output back and throws a [StateError] if it
/// would show anything other than [md], so a save never writes a lossy file.
String writeRtf(String md) {
  final text = md.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final paras = mdToModel(text);
  final out = _write(paras, text);
  // It must open editable again showing exactly [text]. That also proves
  // the document itself shows the note: readRtf hands back a text only
  // when its paragraphs match the document's (the kept copy's, or one
  // made from the document and checked).
  final back = readRtf(out);
  if (!back.editable || back.markdown != text) {
    throw StateError('RTF round trip differs');
  }
  return out;
}

String _write(List<RtfPara> paras, String md) {
  final sb = StringBuffer()
    ..write(r'{\rtf1\ansi\ansicpg1252\deff0\uc1')
    ..write('\n')
    ..write(r'{\fonttbl{\f0\fswiss\fcharset0 Calibri;}}')
    ..write('\n')
    ..write(r'{\colortbl;\red5\green99\blue193;}')
    ..write('\n')
    ..write(
      r'{\stylesheet{\fs24 Normal;}'
      r'{\s1\outlinelevel0\b\fs36\sbasedon0\snext0 heading 1;}'
      r'{\s2\outlinelevel1\b\fs30\sbasedon0\snext0 heading 2;}'
      r'{\s3\outlinelevel2\b\fs26\sbasedon0\snext0 heading 3;}}',
    )
    ..write('\n');
  // Lists. Word and LibreOffice do not read the numbers written beside
  // each item: they count, from each level's start. So a numbered list is
  // cut wherever counting would not give the note's own number (1. 3.,
  // a restart, a list after a paragraph), and each part starts where the
  // note does, level by level. Bullets share one list.
  final lsOf = List<int>.filled(paras.length, 0);
  final starts = <List<int>>[]; // per numbered list: start of each level
  List<int>? start;
  final started = List<bool>.filled(9, false);
  final count = List<int?>.filled(9, null);
  for (var k = 0; k < paras.length; k++) {
    final p = paras[k];
    if (p.kind == MdLineKind.bullet) {
      lsOf[k] = 1;
    } else if (p.kind == MdLineKind.numbered) {
      final l = p.level;
      final prevList =
          k > 0 &&
          (paras[k - 1].kind == MdLineKind.numbered ||
              paras[k - 1].kind == MdLineKind.bullet);
      var fits = start != null && prevList;
      if (fits) {
        final expected = count[l] != null
            ? count[l]! + 1
            : (started[l] ? start[l] : p.number);
        fits = expected == p.number;
      }
      if (!fits) {
        start = List<int>.filled(9, 1);
        starts.add(start);
        started.fillRange(0, 9, false);
        count.fillRange(0, 9, null);
      }
      if (!started[l]) {
        start![l] = p.number;
        started[l] = true;
      }
      count[l] = p.number;
      // A deeper level counts again from its start after this item.
      count.fillRange(l + 1, 9, null);
      lsOf[k] = 1 + starts.length;
    } else {
      start = null;
    }
  }
  final hasBullets = lsOf.contains(1);
  if (hasBullets || starts.isNotEmpty) {
    sb.write(r'{\*\listtable');
    if (hasBullets) sb.write(_listDef(1001, true, List.filled(9, 1)));
    for (var b = 0; b < starts.length; b++) {
      sb.write(_listDef(2001 + b, false, starts[b]));
    }
    sb.write('}\n');
    sb.write(r'{\*\listoverridetable');
    if (hasBullets) {
      sb.write(r'{\listoverride\listid1001\listoverridecount0\ls1}');
    }
    for (var b = 0; b < starts.length; b++) {
      sb.write(
        '{\\listoverride\\listid${2001 + b}\\listoverridecount0\\ls${2 + b}}',
      );
    }
    sb.write('}\n');
  }
  sb
    ..write(r'{\*\generator Breeze;}')
    // The note as typed, which other apps skip: reopened in Breeze it reads
    // back character for character, however its formatting was spelled.
    ..write(r'{\*\breezemd ')
    ..write(_esc(md))
    ..write('}\n')
    ..write(r'\viewkind4')
    ..write('\n');
  for (var k = 0; k < paras.length; k++) {
    final p = paras[k];
    switch (p.kind) {
      case MdLineKind.h1 || MdLineKind.h2 || MdLineKind.h3:
        final h = p.kind == MdLineKind.h1
            ? 1
            : p.kind == MdLineKind.h2
            ? 2
            : 3;
        sb.write(
          '\\pard\\plain\\s$h\\outlinelevel${h - 1}\\b\\fs${const [36, 30, 26][h - 1]} ',
        );
      case MdLineKind.bullet || MdLineKind.numbered:
        final mark = p.kind == MdLineKind.bullet ? r'\u8226?' : '${p.number}.';
        sb
          ..write('{\\listtext\\pard\\plain\\fs24 $mark\\tab}')
          ..write(
            '\\pard\\plain\\ls${lsOf[k]}\\ilvl${p.level}'
            '\\fi-360\\li${720 * (p.level + 1)}\\fs24 ',
          );
      case MdLineKind.plain:
        sb.write(r'\pard\plain\fs24 ');
    }
    var i = 0;
    final n = p.units.length;
    while (i < n) {
      final link = p.links[i];
      var j = i;
      while (j < n && p.links[j] == link) {
        j++;
      }
      if (link != null) {
        sb
          ..write(r'{\field{\*\fldinst{HYPERLINK "')
          // Field codes double a backslash, as Word writes them.
          ..write(_esc(link.replaceAll('"', '%22').replaceAll(r'\', r'\\')))
          ..write(r'"}}{\fldrslt{\ul\cf1 ');
      }
      var a = i;
      while (a < j) {
        var b = a;
        while (b < j && p.attrs[b] == p.attrs[a]) {
          b++;
        }
        final f = p.attrs[a];
        final ctl = StringBuffer();
        if (f & Md.bold != 0) ctl.write(r'\b');
        if (f & Md.italic != 0) ctl.write(r'\i');
        if (f & Md.underline != 0) ctl.write(r'\ul');
        if (f & Md.strike != 0) ctl.write(r'\strike');
        final text = _esc(String.fromCharCodes(p.units.sublist(a, b)));
        if (ctl.isEmpty) {
          sb.write(text);
        } else {
          sb.write('{$ctl $text}');
        }
        a = b;
      }
      if (link != null) sb.write('}}}');
      i = j;
    }
    sb.write('\\par\n');
  }
  sb.write('}');
  return sb.toString();
}

String _listDef(int id, bool bullet, List<int> start) {
  final sb = StringBuffer('{\\list\\listtemplateid$id');
  for (var l = 0; l < 9; l++) {
    final nfc = bullet ? 23 : 0;
    final startAt = start[l];
    final text = bullet
        ? r"{\leveltext\'01\u8226 ?;}{\levelnumbers;}"
        : "{\\leveltext\\'02\\'0$l.;}{\\levelnumbers\\'01;}";
    sb.write(
      '{\\listlevel\\levelnfc$nfc\\levelnfcn$nfc\\leveljc0\\leveljcn0'
      '\\levelfollow0\\levelstartat$startAt\\levelspace0\\levelindent0'
      '$text\\fi-360\\li${720 * (l + 1)}\\lin${720 * (l + 1)} }',
    );
  }
  sb.write('{\\listname ;}\\listid$id}');
  return sb.toString();
}

/// Text as RTF: ASCII only, every other character as \uN (UTF-16 units,
/// so emoji travel as their surrogate pair).
String _esc(String t) {
  final sb = StringBuffer();
  for (final u in t.codeUnits) {
    if (u == 0x5C) {
      sb.write(r'\\');
    } else if (u == 0x7B) {
      sb.write(r'\{');
    } else if (u == 0x7D) {
      sb.write(r'\}');
    } else if (u == 0x09) {
      sb.write(r'\tab ');
    } else if (u >= 0x20 && u < 0x80) {
      sb.writeCharCode(u);
    } else {
      sb.write('\\u${u > 32767 ? u - 65536 : u}?');
    }
  }
  return sb.toString();
}

/// Border words that draw nothing on their own: which side, its width and
/// colour, and "no border". Any other \brdr word is a style that shows.
const _noBorder = {
  'brdrt',
  'brdrb',
  'brdrl',
  'brdrr',
  'brdrbtw',
  'brdrbar',
  'brdrw',
  'brdrcf',
  'brdrnil',
  'brdrnone',
};

/// Windows code pages, bytes 0x80-0xFF (0xFFFD: no character).
/// Generated from Python's codecs.
const _codePages = <int, List<int>>{
  874: [
    0x20AC,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2026,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x00A0,
    0x0E01,
    0x0E02,
    0x0E03,
    0x0E04,
    0x0E05,
    0x0E06,
    0x0E07,
    0x0E08,
    0x0E09,
    0x0E0A,
    0x0E0B,
    0x0E0C,
    0x0E0D,
    0x0E0E,
    0x0E0F,
    0x0E10,
    0x0E11,
    0x0E12,
    0x0E13,
    0x0E14,
    0x0E15,
    0x0E16,
    0x0E17,
    0x0E18,
    0x0E19,
    0x0E1A,
    0x0E1B,
    0x0E1C,
    0x0E1D,
    0x0E1E,
    0x0E1F,
    0x0E20,
    0x0E21,
    0x0E22,
    0x0E23,
    0x0E24,
    0x0E25,
    0x0E26,
    0x0E27,
    0x0E28,
    0x0E29,
    0x0E2A,
    0x0E2B,
    0x0E2C,
    0x0E2D,
    0x0E2E,
    0x0E2F,
    0x0E30,
    0x0E31,
    0x0E32,
    0x0E33,
    0x0E34,
    0x0E35,
    0x0E36,
    0x0E37,
    0x0E38,
    0x0E39,
    0x0E3A,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x0E3F,
    0x0E40,
    0x0E41,
    0x0E42,
    0x0E43,
    0x0E44,
    0x0E45,
    0x0E46,
    0x0E47,
    0x0E48,
    0x0E49,
    0x0E4A,
    0x0E4B,
    0x0E4C,
    0x0E4D,
    0x0E4E,
    0x0E4F,
    0x0E50,
    0x0E51,
    0x0E52,
    0x0E53,
    0x0E54,
    0x0E55,
    0x0E56,
    0x0E57,
    0x0E58,
    0x0E59,
    0x0E5A,
    0x0E5B,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
  ],
  1250: [
    0x20AC,
    0xFFFD,
    0x201A,
    0xFFFD,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0xFFFD,
    0x2030,
    0x0160,
    0x2039,
    0x015A,
    0x0164,
    0x017D,
    0x0179,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0xFFFD,
    0x2122,
    0x0161,
    0x203A,
    0x015B,
    0x0165,
    0x017E,
    0x017A,
    0x00A0,
    0x02C7,
    0x02D8,
    0x0141,
    0x00A4,
    0x0104,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0x015E,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x017B,
    0x00B0,
    0x00B1,
    0x02DB,
    0x0142,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00B8,
    0x0105,
    0x015F,
    0x00BB,
    0x013D,
    0x02DD,
    0x013E,
    0x017C,
    0x0154,
    0x00C1,
    0x00C2,
    0x0102,
    0x00C4,
    0x0139,
    0x0106,
    0x00C7,
    0x010C,
    0x00C9,
    0x0118,
    0x00CB,
    0x011A,
    0x00CD,
    0x00CE,
    0x010E,
    0x0110,
    0x0143,
    0x0147,
    0x00D3,
    0x00D4,
    0x0150,
    0x00D6,
    0x00D7,
    0x0158,
    0x016E,
    0x00DA,
    0x0170,
    0x00DC,
    0x00DD,
    0x0162,
    0x00DF,
    0x0155,
    0x00E1,
    0x00E2,
    0x0103,
    0x00E4,
    0x013A,
    0x0107,
    0x00E7,
    0x010D,
    0x00E9,
    0x0119,
    0x00EB,
    0x011B,
    0x00ED,
    0x00EE,
    0x010F,
    0x0111,
    0x0144,
    0x0148,
    0x00F3,
    0x00F4,
    0x0151,
    0x00F6,
    0x00F7,
    0x0159,
    0x016F,
    0x00FA,
    0x0171,
    0x00FC,
    0x00FD,
    0x0163,
    0x02D9,
  ],
  1251: [
    0x0402,
    0x0403,
    0x201A,
    0x0453,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x20AC,
    0x2030,
    0x0409,
    0x2039,
    0x040A,
    0x040C,
    0x040B,
    0x040F,
    0x0452,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0xFFFD,
    0x2122,
    0x0459,
    0x203A,
    0x045A,
    0x045C,
    0x045B,
    0x045F,
    0x00A0,
    0x040E,
    0x045E,
    0x0408,
    0x00A4,
    0x0490,
    0x00A6,
    0x00A7,
    0x0401,
    0x00A9,
    0x0404,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x0407,
    0x00B0,
    0x00B1,
    0x0406,
    0x0456,
    0x0491,
    0x00B5,
    0x00B6,
    0x00B7,
    0x0451,
    0x2116,
    0x0454,
    0x00BB,
    0x0458,
    0x0405,
    0x0455,
    0x0457,
    0x0410,
    0x0411,
    0x0412,
    0x0413,
    0x0414,
    0x0415,
    0x0416,
    0x0417,
    0x0418,
    0x0419,
    0x041A,
    0x041B,
    0x041C,
    0x041D,
    0x041E,
    0x041F,
    0x0420,
    0x0421,
    0x0422,
    0x0423,
    0x0424,
    0x0425,
    0x0426,
    0x0427,
    0x0428,
    0x0429,
    0x042A,
    0x042B,
    0x042C,
    0x042D,
    0x042E,
    0x042F,
    0x0430,
    0x0431,
    0x0432,
    0x0433,
    0x0434,
    0x0435,
    0x0436,
    0x0437,
    0x0438,
    0x0439,
    0x043A,
    0x043B,
    0x043C,
    0x043D,
    0x043E,
    0x043F,
    0x0440,
    0x0441,
    0x0442,
    0x0443,
    0x0444,
    0x0445,
    0x0446,
    0x0447,
    0x0448,
    0x0449,
    0x044A,
    0x044B,
    0x044C,
    0x044D,
    0x044E,
    0x044F,
  ],
  1253: [
    0x20AC,
    0xFFFD,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0xFFFD,
    0x2030,
    0xFFFD,
    0x2039,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0xFFFD,
    0x2122,
    0xFFFD,
    0x203A,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x00A0,
    0x0385,
    0x0386,
    0x00A3,
    0x00A4,
    0x00A5,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0xFFFD,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x2015,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x0384,
    0x00B5,
    0x00B6,
    0x00B7,
    0x0388,
    0x0389,
    0x038A,
    0x00BB,
    0x038C,
    0x00BD,
    0x038E,
    0x038F,
    0x0390,
    0x0391,
    0x0392,
    0x0393,
    0x0394,
    0x0395,
    0x0396,
    0x0397,
    0x0398,
    0x0399,
    0x039A,
    0x039B,
    0x039C,
    0x039D,
    0x039E,
    0x039F,
    0x03A0,
    0x03A1,
    0xFFFD,
    0x03A3,
    0x03A4,
    0x03A5,
    0x03A6,
    0x03A7,
    0x03A8,
    0x03A9,
    0x03AA,
    0x03AB,
    0x03AC,
    0x03AD,
    0x03AE,
    0x03AF,
    0x03B0,
    0x03B1,
    0x03B2,
    0x03B3,
    0x03B4,
    0x03B5,
    0x03B6,
    0x03B7,
    0x03B8,
    0x03B9,
    0x03BA,
    0x03BB,
    0x03BC,
    0x03BD,
    0x03BE,
    0x03BF,
    0x03C0,
    0x03C1,
    0x03C2,
    0x03C3,
    0x03C4,
    0x03C5,
    0x03C6,
    0x03C7,
    0x03C8,
    0x03C9,
    0x03CA,
    0x03CB,
    0x03CC,
    0x03CD,
    0x03CE,
    0xFFFD,
  ],
  1254: [
    0x20AC,
    0xFFFD,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0x0161,
    0x203A,
    0x0153,
    0xFFFD,
    0xFFFD,
    0x0178,
    0x00A0,
    0x00A1,
    0x00A2,
    0x00A3,
    0x00A4,
    0x00A5,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0x00AA,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x00AF,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00B8,
    0x00B9,
    0x00BA,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x00BF,
    0x00C0,
    0x00C1,
    0x00C2,
    0x00C3,
    0x00C4,
    0x00C5,
    0x00C6,
    0x00C7,
    0x00C8,
    0x00C9,
    0x00CA,
    0x00CB,
    0x00CC,
    0x00CD,
    0x00CE,
    0x00CF,
    0x011E,
    0x00D1,
    0x00D2,
    0x00D3,
    0x00D4,
    0x00D5,
    0x00D6,
    0x00D7,
    0x00D8,
    0x00D9,
    0x00DA,
    0x00DB,
    0x00DC,
    0x0130,
    0x015E,
    0x00DF,
    0x00E0,
    0x00E1,
    0x00E2,
    0x00E3,
    0x00E4,
    0x00E5,
    0x00E6,
    0x00E7,
    0x00E8,
    0x00E9,
    0x00EA,
    0x00EB,
    0x00EC,
    0x00ED,
    0x00EE,
    0x00EF,
    0x011F,
    0x00F1,
    0x00F2,
    0x00F3,
    0x00F4,
    0x00F5,
    0x00F6,
    0x00F7,
    0x00F8,
    0x00F9,
    0x00FA,
    0x00FB,
    0x00FC,
    0x0131,
    0x015F,
    0x00FF,
  ],
  1255: [
    0x20AC,
    0xFFFD,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0xFFFD,
    0x2039,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0xFFFD,
    0x203A,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x00A0,
    0x00A1,
    0x00A2,
    0x00A3,
    0x20AA,
    0x00A5,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0x00D7,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x00AF,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00B8,
    0x00B9,
    0x00F7,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x00BF,
    0x05B0,
    0x05B1,
    0x05B2,
    0x05B3,
    0x05B4,
    0x05B5,
    0x05B6,
    0x05B7,
    0x05B8,
    0x05B9,
    0xFFFD,
    0x05BB,
    0x05BC,
    0x05BD,
    0x05BE,
    0x05BF,
    0x05C0,
    0x05C1,
    0x05C2,
    0x05C3,
    0x05F0,
    0x05F1,
    0x05F2,
    0x05F3,
    0x05F4,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x05D0,
    0x05D1,
    0x05D2,
    0x05D3,
    0x05D4,
    0x05D5,
    0x05D6,
    0x05D7,
    0x05D8,
    0x05D9,
    0x05DA,
    0x05DB,
    0x05DC,
    0x05DD,
    0x05DE,
    0x05DF,
    0x05E0,
    0x05E1,
    0x05E2,
    0x05E3,
    0x05E4,
    0x05E5,
    0x05E6,
    0x05E7,
    0x05E8,
    0x05E9,
    0x05EA,
    0xFFFD,
    0xFFFD,
    0x200E,
    0x200F,
    0xFFFD,
  ],
  1256: [
    0x20AC,
    0x067E,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0679,
    0x2039,
    0x0152,
    0x0686,
    0x0698,
    0x0688,
    0x06AF,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x06A9,
    0x2122,
    0x0691,
    0x203A,
    0x0153,
    0x200C,
    0x200D,
    0x06BA,
    0x00A0,
    0x060C,
    0x00A2,
    0x00A3,
    0x00A4,
    0x00A5,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0x06BE,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x00AF,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00B8,
    0x00B9,
    0x061B,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x061F,
    0x06C1,
    0x0621,
    0x0622,
    0x0623,
    0x0624,
    0x0625,
    0x0626,
    0x0627,
    0x0628,
    0x0629,
    0x062A,
    0x062B,
    0x062C,
    0x062D,
    0x062E,
    0x062F,
    0x0630,
    0x0631,
    0x0632,
    0x0633,
    0x0634,
    0x0635,
    0x0636,
    0x00D7,
    0x0637,
    0x0638,
    0x0639,
    0x063A,
    0x0640,
    0x0641,
    0x0642,
    0x0643,
    0x00E0,
    0x0644,
    0x00E2,
    0x0645,
    0x0646,
    0x0647,
    0x0648,
    0x00E7,
    0x00E8,
    0x00E9,
    0x00EA,
    0x00EB,
    0x0649,
    0x064A,
    0x00EE,
    0x00EF,
    0x064B,
    0x064C,
    0x064D,
    0x064E,
    0x00F4,
    0x064F,
    0x0650,
    0x00F7,
    0x0651,
    0x00F9,
    0x0652,
    0x00FB,
    0x00FC,
    0x200E,
    0x200F,
    0x06D2,
  ],
  1257: [
    0x20AC,
    0xFFFD,
    0x201A,
    0xFFFD,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0xFFFD,
    0x2030,
    0xFFFD,
    0x2039,
    0xFFFD,
    0x00A8,
    0x02C7,
    0x00B8,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0xFFFD,
    0x2122,
    0xFFFD,
    0x203A,
    0xFFFD,
    0x00AF,
    0x02DB,
    0xFFFD,
    0x00A0,
    0xFFFD,
    0x00A2,
    0x00A3,
    0x00A4,
    0xFFFD,
    0x00A6,
    0x00A7,
    0x00D8,
    0x00A9,
    0x0156,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x00C6,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00F8,
    0x00B9,
    0x0157,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x00E6,
    0x0104,
    0x012E,
    0x0100,
    0x0106,
    0x00C4,
    0x00C5,
    0x0118,
    0x0112,
    0x010C,
    0x00C9,
    0x0179,
    0x0116,
    0x0122,
    0x0136,
    0x012A,
    0x013B,
    0x0160,
    0x0143,
    0x0145,
    0x00D3,
    0x014C,
    0x00D5,
    0x00D6,
    0x00D7,
    0x0172,
    0x0141,
    0x015A,
    0x016A,
    0x00DC,
    0x017B,
    0x017D,
    0x00DF,
    0x0105,
    0x012F,
    0x0101,
    0x0107,
    0x00E4,
    0x00E5,
    0x0119,
    0x0113,
    0x010D,
    0x00E9,
    0x017A,
    0x0117,
    0x0123,
    0x0137,
    0x012B,
    0x013C,
    0x0161,
    0x0144,
    0x0146,
    0x00F3,
    0x014D,
    0x00F5,
    0x00F6,
    0x00F7,
    0x0173,
    0x0142,
    0x015B,
    0x016B,
    0x00FC,
    0x017C,
    0x017E,
    0x02D9,
  ],
  1258: [
    0x20AC,
    0xFFFD,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0xFFFD,
    0x2039,
    0x0152,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0xFFFD,
    0x203A,
    0x0153,
    0xFFFD,
    0xFFFD,
    0x0178,
    0x00A0,
    0x00A1,
    0x00A2,
    0x00A3,
    0x00A4,
    0x00A5,
    0x00A6,
    0x00A7,
    0x00A8,
    0x00A9,
    0x00AA,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x00AF,
    0x00B0,
    0x00B1,
    0x00B2,
    0x00B3,
    0x00B4,
    0x00B5,
    0x00B6,
    0x00B7,
    0x00B8,
    0x00B9,
    0x00BA,
    0x00BB,
    0x00BC,
    0x00BD,
    0x00BE,
    0x00BF,
    0x00C0,
    0x00C1,
    0x00C2,
    0x0102,
    0x00C4,
    0x00C5,
    0x00C6,
    0x00C7,
    0x00C8,
    0x00C9,
    0x00CA,
    0x00CB,
    0x0300,
    0x00CD,
    0x00CE,
    0x00CF,
    0x0110,
    0x00D1,
    0x0309,
    0x00D3,
    0x00D4,
    0x01A0,
    0x00D6,
    0x00D7,
    0x00D8,
    0x00D9,
    0x00DA,
    0x00DB,
    0x00DC,
    0x01AF,
    0x0303,
    0x00DF,
    0x00E0,
    0x00E1,
    0x00E2,
    0x0103,
    0x00E4,
    0x00E5,
    0x00E6,
    0x00E7,
    0x00E8,
    0x00E9,
    0x00EA,
    0x00EB,
    0x0301,
    0x00ED,
    0x00EE,
    0x00EF,
    0x0111,
    0x00F1,
    0x0323,
    0x00F3,
    0x00F4,
    0x01A1,
    0x00F6,
    0x00F7,
    0x00F8,
    0x00F9,
    0x00FA,
    0x00FB,
    0x00FC,
    0x01B0,
    0x20AB,
    0x00FF,
  ],
};
