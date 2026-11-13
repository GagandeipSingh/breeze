/// Word documents (.docx), read and written by hand on top of the zip
/// library the app already has.
///
/// The editor works on Markdown-lite (markdown_lite.dart). A .docx note goes
/// through the same paragraph model as RTF ([RtfPara], rtf.dart), so both
/// formats keep the same things - headings, bulleted and numbered lists,
/// links, bold, italic, underline, strikethrough - and the same promise:
///  * [readDocx] lists what Breeze cannot keep (tables, pictures, comments,
///    colours, fonts...). A document holding any of it is shown, never
///    edited in place.
///  * [writeDocx] reads its own output back and throws if it differs, so a
///    save never replaces a file with something other than what was typed.
///
/// What Breeze writes is native Word: real Heading 1-3 styles, real Word
/// lists (each numbered so that Word's own counting shows the note's
/// numbers), real hyperlinks, Calibri 11 on an A4 page.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'markdown_lite.dart';
import 'rtf.dart';

/// Whether [bytes] are a zip (a .docx is one). A text file named .docx is
/// not, and stays text.
bool looksLikeDocx(List<int> bytes) =>
    bytes.length > 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

// -- a small XML reader --------------------------------------------------

const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _wStrict = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
const _rNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _rStrict = 'http://purl.oclc.org/ooxml/officeDocument/relationships';
const _xmlNs = 'http://www.w3.org/XML/1998/namespace';

/// One element. [name] is the local name for Word's own namespace and
/// `{uri}local` for any other. Attributes the same way, with `r:` for the
/// relationships namespace and `xml:` for XML's.
class _El {
  _El(this.name);
  final String name;
  final attrs = <String, String>{};

  /// Elements and text (String) in order.
  final children = <Object>[];

  Iterable<_El> get els => children.whereType<_El>();
  _El? child(String n) {
    for (final c in children) {
      if (c is _El && c.name == n) return c;
    }
    return null;
  }

  String get text {
    final b = StringBuffer();
    for (final c in children) {
      b.write(c is String ? c : (c as _El).text);
    }
    return b.toString();
  }

  /// w:val, or null.
  String? get val => attrs['val'];
}

class _XmlError implements Exception {}

/// [s] as a tree. Throws [_XmlError] on damage.
_El _parseXml(String s) {
  final root = _El('#root');
  final stack = <_El>[root];
  final nsStack = <Map<String, String>>[
    {'xml': _xmlNs},
  ];
  var i = 0;
  final n = s.length;

  String qualify(String raw, Map<String, String> ns, {bool attr = false}) {
    final c = raw.indexOf(':');
    final prefix = c < 0 ? '' : raw.substring(0, c);
    final local = c < 0 ? raw : raw.substring(c + 1);
    // An unprefixed attribute has no namespace.
    final uri = attr && c < 0 ? '' : (ns[prefix] ?? '');
    if (uri == _wNs || uri == _wStrict) return local;
    if (uri == _rNs || uri == _rStrict) return 'r:$local';
    if (uri == _xmlNs) return 'xml:$local';
    if (uri.isEmpty) return local;
    return '{$uri}$local';
  }

  String decode(String t) {
    if (!t.contains('&')) return t;
    return t.replaceAllMapped(RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|\w+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#x')) {
        return String.fromCharCode(int.parse(e.substring(2), radix: 16));
      }
      if (e.startsWith('#')) {
        return String.fromCharCode(int.parse(e.substring(1)));
      }
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      throw _XmlError();
    });
  }

  while (i < n) {
    final lt = s.indexOf('<', i);
    if (lt < 0) {
      if (s.substring(i).trim().isNotEmpty) throw _XmlError();
      break;
    }
    if (lt > i) stack.last.children.add(decode(s.substring(i, lt)));
    if (s.startsWith('<?', lt)) {
      final e = s.indexOf('?>', lt);
      if (e < 0) throw _XmlError();
      i = e + 2;
    } else if (s.startsWith('<!--', lt)) {
      final e = s.indexOf('-->', lt);
      if (e < 0) throw _XmlError();
      i = e + 3;
    } else if (s.startsWith('<![CDATA[', lt)) {
      final e = s.indexOf(']]>', lt);
      if (e < 0) throw _XmlError();
      stack.last.children.add(s.substring(lt + 9, e));
      i = e + 3;
    } else if (s.startsWith('<!', lt)) {
      final e = s.indexOf('>', lt);
      if (e < 0) throw _XmlError();
      i = e + 1;
    } else if (s.startsWith('</', lt)) {
      final e = s.indexOf('>', lt);
      if (e < 0 || stack.length < 2) throw _XmlError();
      stack.removeLast();
      nsStack.removeLast();
      i = e + 1;
    } else {
      // A start tag: its name, then attributes, quoted values may hold '>'.
      var j = lt + 1;
      while (j < n && !' \t\r\n/>'.contains(s[j])) {
        j++;
      }
      final rawName = s.substring(lt + 1, j);
      final rawAttrs = <(String, String)>[];
      var selfClose = false;
      while (true) {
        while (j < n && ' \t\r\n'.contains(s[j])) {
          j++;
        }
        if (j >= n) throw _XmlError();
        if (s[j] == '>') {
          j++;
          break;
        }
        if (s[j] == '/') {
          if (j + 1 >= n || s[j + 1] != '>') throw _XmlError();
          selfClose = true;
          j += 2;
          break;
        }
        final eq = s.indexOf('=', j);
        if (eq < 0) throw _XmlError();
        final an = s.substring(j, eq).trim();
        var q = eq + 1;
        while (q < n && ' \t\r\n'.contains(s[q])) {
          q++;
        }
        if (q >= n || (s[q] != '"' && s[q] != "'")) throw _XmlError();
        final close = s.indexOf(s[q], q + 1);
        if (close < 0) throw _XmlError();
        rawAttrs.add((an, decode(s.substring(q + 1, close))));
        j = close + 1;
      }
      final ns = Map<String, String>.of(nsStack.last);
      for (final (k, v) in rawAttrs) {
        if (k == 'xmlns') ns[''] = v;
        if (k.startsWith('xmlns:')) ns[k.substring(6)] = v;
      }
      final el = _El(qualify(rawName, ns));
      for (final (k, v) in rawAttrs) {
        if (k == 'xmlns' || k.startsWith('xmlns:')) continue;
        el.attrs[qualify(k, ns, attr: true)] = v;
      }
      stack.last.children.add(el);
      if (!selfClose) {
        stack.add(el);
        nsStack.add(ns);
      }
      i = j;
    }
  }
  if (stack.length != 1) throw _XmlError();
  final top = root.els.toList();
  if (top.length != 1) throw _XmlError();
  return top.single;
}

String _xmlEsc(String t) => t
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

// -- reading -------------------------------------------------------------

/// A toggle such as w:b: on unless its val says off.
bool _on(_El e) {
  final v = e.val;
  return v == null || !(v == '0' || v == 'false' || v == 'off');
}

/// Run look, resolved through styles: null means "not said here".
class _RunProps {
  bool? b, i, strike, dstrike, caps, smallCaps, hidden, effects, sup, rtl;
  bool? raised,
      shaded,
      scaled; // position, shd, w (beside sup, marked, spacing)
  String? u; // 'single', 'none', or another style
  String? color; // hex, or 'auto'
  String? colorHex; // the hex Word draws, theme colours included
  bool? marked; // highlight or shading
  int? sz; // half-points
  String? font; // ascii (U+0000-007F) family, lower case
  String? fontH; // hAnsi family: the other Latin characters (é, ü...)
  bool? spacing;
  int? kern; // w:kern: kerned from this size (half-points) up

  // What Word draws complex scripts (Hindi, Arabic, Thai...) with: their
  // own bold, italic, size and font. And w:hint="cs", which draws digits
  // and punctuation in that font too.
  bool? bCs, iCs, csHint;

  /// w:cs: the whole run is drawn as complex script.
  bool? csRun;
  int? szCs;
  String? fontCs;

  /// A formatting change recorded by track changes.
  bool? tracked;

  /// The properties Word TOGGLES between a paragraph style and a character
  /// style (italic in both reads upright), by name.
  static const toggles = [
    'b',
    'i',
    'bCs',
    'iCs',
    'strike',
    'dstrike',
    'caps',
    'smallCaps',
    'hidden',
  ];

  bool? toggle(String n) => switch (n) {
    'b' => b,
    'i' => i,
    'bCs' => bCs,
    'iCs' => iCs,
    'strike' => strike,
    'dstrike' => dstrike,
    'caps' => caps,
    'smallCaps' => smallCaps,
    _ => hidden,
  };

  void setToggle(String n, bool v) {
    switch (n) {
      case 'b':
        b = v;
      case 'i':
        i = v;
      case 'bCs':
        bCs = v;
      case 'iCs':
        iCs = v;
      case 'strike':
        strike = v;
      case 'dstrike':
        dstrike = v;
      case 'caps':
        caps = v;
      case 'smallCaps':
        smallCaps = v;
      default:
        hidden = v;
    }
  }

  void over(_RunProps o) {
    bCs = o.bCs ?? bCs;
    iCs = o.iCs ?? iCs;
    csHint = o.csHint ?? csHint;
    csRun = o.csRun ?? csRun;
    szCs = o.szCs ?? szCs;
    fontCs = o.fontCs ?? fontCs;
    tracked = o.tracked ?? tracked;
    b = o.b ?? b;
    i = o.i ?? i;
    strike = o.strike ?? strike;
    dstrike = o.dstrike ?? dstrike;
    caps = o.caps ?? caps;
    smallCaps = o.smallCaps ?? smallCaps;
    raised = o.raised ?? raised;
    shaded = o.shaded ?? shaded;
    scaled = o.scaled ?? scaled;
    hidden = o.hidden ?? hidden;
    effects = o.effects ?? effects;
    sup = o.sup ?? sup;
    rtl = o.rtl ?? rtl;
    u = o.u ?? u;
    color = o.color ?? color;
    kern = o.kern ?? kern;
    colorHex = o.colorHex ?? colorHex;
    marked = o.marked ?? marked;
    sz = o.sz ?? sz;
    font = o.font ?? font;
    fontH = o.fontH ?? fontH;
    spacing = o.spacing ?? spacing;
  }

  _RunProps copy() => _RunProps()..over(this);
}

/// Paragraph look, resolved through styles.
class _ParaProps {
  int? outline; // 0-based
  String? jc;
  bool? indent; // a left, first-line or hanging indent
  bool? bidi, border, frame, pageBefore;
  int? numId, ilvl;
  bool? oddTabs;

  /// w:spacing, attribute by attribute (before, after, line, lineRule...).
  Map<String, String> spacing = const {};
  bool? contextual;

  void over(_ParaProps o) {
    outline = o.outline ?? outline;
    jc = o.jc ?? jc;
    indent = o.indent ?? indent;
    bidi = o.bidi ?? bidi;
    border = o.border ?? border;
    frame = o.frame ?? frame;
    pageBefore = o.pageBefore ?? pageBefore;
    numId = o.numId ?? numId;
    ilvl = o.ilvl ?? ilvl;
    oddTabs = o.oddTabs ?? oddTabs;
    if (o.spacing.isNotEmpty) spacing = {...spacing, ...o.spacing};
    contextual = o.contextual ?? contextual;
  }
}

class _Style {
  String? basedOn;
  String name = '';
  String type = 'paragraph';
  final run = _RunProps();
  final para = _ParaProps();
}

class _Level {
  String fmt = 'decimal';
  String text = '';
  int start = 1;

  /// w:lvlRestart: null restarts after any higher level, 0 never, k after
  /// an item at a level above k (0-based level < k).
  int? restart;

  /// The number itself styled (bold, coloured, sized): Breeze cannot.
  bool styled = false;

  /// The level indents its paragraphs.
  bool indented = false;

  /// The level's own indent (w:ind attributes).
  Map<String, String> ind = const {};

  /// The font the bullet or number is drawn in (Symbol, Wingdings...).
  String font = '';
}

/// Word's own list counting, one counter per abstract list. Checked
/// against Word: a level counts on across every w:num of one abstract list;
/// an item whose parent levels have not been used counts them as used
/// (level 1 "a" then level 0 "b" shows b as 2.); an item resets the levels
/// below it unless their lvlRestart says otherwise, bullets included; a
/// num's startOverride applies once, at its first paragraph, and is where
/// that level starts again whenever it restarts inside that num.
class _WordCounter {
  final _c = List<int>.filled(9, 0);
  final _used = List<bool>.filled(9, false);

  _WordCounter copy() => _WordCounter()
    .._c.setAll(0, _c)
    .._used.setAll(0, _used);

  void restartAt(int l, int value) {
    _c[l] = value - 1;
    _used[l] = true;
  }

  /// The number the next item at [l] would show.
  int peek(int l, int Function(int) start) => _used[l] ? _c[l] + 1 : start(l);

  int item(int l, int Function(int) start, int? Function(int) restart) {
    for (var parent = 0; parent < l; parent++) {
      // A level that never restarts is not counted by a deeper item.
      if (!_used[parent] && restart(parent) != 0) {
        _used[parent] = true;
        _c[parent] = start(parent);
      }
    }
    _c[l] = peek(l, start);
    _used[l] = true;
    for (var d = l + 1; d < 9; d++) {
      final r = restart(d);
      if (r == null || (r != 0 && l < r)) _used[d] = false;
    }
    return _c[l];
  }
}

class _Num {
  _Num(this.abstractId);
  final String abstractId;
  final starts = <int, int>{};
}

const _bulletChars = {
  0x2022, // bullet
  0x00B7, // middle dot
  0x006F, // o (Courier New)
  0x00A7, // section sign (Wingdings square)
  0x25AA, // small black square
  0x25E6, // white bullet
  0x25CF, // black circle (Google Docs)
  0x25CB, // white circle (Google Docs)
  0x25A0, // black square (Google Docs)
  // Google Docs' other bullet presets, kept as they are on save.
  0x002D, // hyphen (its dash list)
  0x27A2, // arrowhead
  0x2756, // diamond minus white X
  0x2605, // black star
  0x2794, // heavy wide-headed arrow
  0x2192, // arrow
  0x2714, // heavy check mark
  0x25C6, // black diamond
  0xF0B7, // Symbol bullet
  0xF06F, // Wingdings circle
  0xF0A7, // Wingdings square
};

class _Docx {
  _Docx(this.files);
  final Map<String, List<int>> files;
  final paras = <RtfPara>[];
  final problems = <String>[];
  final styles = <String, _Style>{};
  final abstracts = <String, Map<int, _Level>>{};
  final abstractStyleLinked = <String>{};
  final nums = <int, _Num>{};
  final rels = <String, String>{};
  // What Word uses when a document names no font or size at all.
  final defaults = _RunProps()
    ..sz = 20
    ..szCs = 20
    ..font = 'times new roman'
    ..fontH = 'times new roman'
    ..fontCs = 'times new roman';
  final defaultPara = _ParaProps();
  String? normalStyle;
  String minorFont = 'calibri', majorFont = 'calibri light';
  String minorFontCs = '', majorFontCs = '';

  /// The theme's per-script fonts (see [_readTheme]).
  final scriptFonts = <String, String>{}; // script tag -> font

  /// Font names as the document spells them, by lower-case name.
  final faceSpelling = <String, String>{'times new roman': 'Times New Roman'};
  bool breeze = false;

  // Counting, as Word does: per abstract list (see [_WordCounter]).
  final counters = <String, _WordCounter>{};
  final _startedNums = <int>{};

  void problem(String w) {
    if (!problems.contains(w)) problems.add(w);
  }

  String? part(String path) {
    final b = files[path];
    if (b == null) return null;
    try {
      return utf8.decode(b);
    } catch (_) {
      // UTF-16 parts are allowed by the standard; Word writes UTF-8.
      problem('content Breeze cannot read');
      return null;
    }
  }

  _El? xml(String path) {
    final t = part(path);
    if (t == null) return null;
    try {
      return _parseXml(t);
    } catch (_) {
      problem('content Breeze cannot read');
      return null;
    }
  }

  String _relsPath(String path) {
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1);
    return '${dir}_rels/${path.substring(slash + 1)}.rels';
  }

  String _resolve(String from, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final slash = from.lastIndexOf('/');
    final parts = [
      if (slash >= 0) ...from.substring(0, slash).split('/'),
      ...target.split('/'),
    ];
    final out = <String>[];
    for (final p in parts) {
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else if (p.isNotEmpty && p != '.') {
        out.add(p);
      }
    }
    return out.join('/');
  }

  bool run() {
    // The main part, by the package's own relationship.
    var main = 'word/document.xml';
    final top = xml('_rels/.rels');
    for (final r in top?.els ?? const <_El>[]) {
      if ((r.attrs['Type'] ?? '').endsWith('/officeDocument')) {
        main = _resolve('', r.attrs['Target'] ?? main);
      }
    }
    final doc = xml(main);
    if (doc == null) return false;
    // Hyperlink targets and the other parts.
    String? stylesPath, numberingPath, themePath, settingsPath;
    for (final r in xml(_relsPath(main))?.els ?? const <_El>[]) {
      final type = r.attrs['Type'] ?? '';
      final id = r.attrs['Id'] ?? '';
      final target = r.attrs['Target'] ?? '';
      if (type.endsWith('/hyperlink')) {
        rels[id] = r.attrs['TargetMode'] == 'External' ? target : '#internal';
      } else if (type.endsWith('/styles')) {
        stylesPath = _resolve(main, target);
      } else if (type.endsWith('/numbering')) {
        numberingPath = _resolve(main, target);
      } else if (type.endsWith('/theme')) {
        themePath = _resolve(main, target);
      } else if (type.endsWith('/settings')) {
        settingsPath = _resolve(main, target);
      } else if (type.endsWith('/header') || type.endsWith('/footer')) {
        _headerParts[id] = _resolve(main, target);
      }
    }
    final app = part('docProps/app.xml');
    breeze =
        app != null &&
        RegExp(r'<Application>Breeze</Application>').hasMatch(app);
    if (themePath != null) _readTheme(themePath);
    final odd = settingsPath == null
        ? null
        : xml(settingsPath)?.child('evenAndOddHeaders');
    _evenHeaders = odd != null && _on(odd);
    if (stylesPath != null) _readStyles(stylesPath);
    if (numberingPath != null) _readNumbering(numberingPath);
    // A page colour.
    if (doc.child('background') != null) problem('page colour');
    final body = doc.child('body');
    if (body == null) {
      problem('content Breeze cannot read');
      return true;
    }
    _blocks(body, top: true);
    // A field never ended: Word shows its text, Breeze has hidden it.
    if (_fields.isNotEmpty) problem('content Breeze cannot read');
    _judgeLooks();
    return true;
  }

  void _readTheme(String path) {
    final t = part(path);
    if (t == null) return;
    String? face(String which) {
      final m = RegExp(
        '<a:$which>.*?<a:latin typeface="([^"]*)"',
        dotAll: true,
      ).firstMatch(t);
      final raw = m?[1]?.trim();
      if (raw != null && raw.isNotEmpty) faceSpelling[raw.toLowerCase()] = raw;
      return raw?.toLowerCase();
    }

    minorFont = face('minorFont') ?? minorFont;
    majorFont = face('majorFont') ?? majorFont;
    String? cs(String which) {
      final m = RegExp(
        '<a:$which>.*?<a:cs typeface="([^"]*)"',
        dotAll: true,
      ).firstMatch(t);
      return m?[1]?.toLowerCase();
    }

    minorFontCs = cs('minorFont') ?? minorFontCs;
    majorFontCs = cs('majorFont') ?? majorFontCs;
    // With no cs face, Word picks one per script from the theme's list
    // (Mangal for Devanagari...): those are the body font too.
    final minor = RegExp(
      '<a:minorFont>(.*?)</a:minorFont>',
      dotAll: true,
    ).firstMatch(t)?[1];
    if (minor != null) {
      for (final m in RegExp(
        '<a:font script="([^"]*)" typeface="([^"]*)"',
      ).allMatches(minor)) {
        scriptFonts[m[1]!] = m[2]!.toLowerCase();
        faceSpelling[m[2]!.toLowerCase()] = m[2]!;
      }
    }
  }

  _RunProps _runProps(_El? rPr) {
    final r = _RunProps();
    if (rPr == null) return r;
    for (final e in rPr.els) {
      switch (e.name) {
        case 'b':
          r.b = _on(e);
        case 'i':
          r.i = _on(e);
        case 'bCs':
          r.bCs = _on(e);
        case 'iCs':
          r.iCs = _on(e);
        case 'szCs':
          r.szCs = int.tryParse(e.val ?? '');
        case 'cs':
          r.csRun = _on(e);
        case 'rPrChange':
          r.tracked = true;
        case 'bdr':
          r.effects = true;
        case 'effect':
          r.effects = r.effects == true || (e.val ?? 'none') != 'none';
        case 'strike':
          r.strike = _on(e);
        case 'dstrike':
          r.dstrike = _on(e);
        case 'caps':
          r.caps = _on(e);
        case 'smallCaps':
          r.smallCaps = _on(e);
        case 'vanish' || 'specVanish':
          // (webHidden hides only in Word's web view.)
          r.hidden = _on(e);
        case 'emboss' || 'imprint' || 'outline' || 'shadow':
          r.effects = r.effects == true || _on(e);
        case 'em':
          r.effects = r.effects == true || (e.val ?? 'none') != 'none';
        case 'vertAlign':
          r.sup = e.val == 'superscript' || e.val == 'subscript';
        case 'position':
          r.raised = (int.tryParse(e.val ?? '0') ?? 0) != 0;
        case 'rtl':
          r.rtl = _on(e);
        case 'u':
          r.u = e.val ?? 'single';
          final uc = (e.attrs['color'] ?? 'auto').toLowerCase();
          // A coloured underline is a look Breeze cannot write.
          if (r.u != 'none' && uc != 'auto' && uc != '000000') {
            r.u = 'coloured';
          }
        case 'color':
          final themed = e.attrs['themeColor'];
          // Black from the theme is black; tinted or shaded ("Lighter 50%")
          // it is grey, a colour.
          final shaded =
              e.attrs['themeTint'] != null || e.attrs['themeShade'] != null;
          r.color = themed != null
              ? ((themed == 'text1' || themed == 'dark1') && !shaded
                    ? '000000'
                    : 'theme')
              : (e.val ?? 'auto').toLowerCase();
          final hex = (e.val ?? 'auto').toUpperCase();
          r.colorHex = RegExp(r'^[0-9A-F]{6}$').hasMatch(hex) ? hex : 'auto';
        case 'highlight':
          r.marked = (e.val ?? 'none') != 'none';
        case 'shd':
          final fill = (e.attrs['fill'] ?? 'auto').toLowerCase();
          r.shaded =
              !(fill == 'auto' || fill == 'ffffff') ||
              (e.val != null && e.val != 'clear' && e.val != 'nil');
        case 'sz':
          r.sz = int.tryParse(e.val ?? '');
        case 'rFonts':
          final a = e.attrs;
          String? named(String themeKey, String key) {
            final theme = a[themeKey];
            if (theme != null) {
              return theme.startsWith('major') ? majorFont : minorFont;
            }
            final raw = a[key]?.trim();
            if (raw == null) return null;
            faceSpelling[raw.toLowerCase()] = raw;
            return raw.toLowerCase();
          }

          r.font = named('asciiTheme', 'ascii') ?? r.font;
          r.fontH = named('hAnsiTheme', 'hAnsi') ?? r.fontH;
          final csTheme = a['cstheme'];
          if (csTheme != null) {
            r.fontCs = csTheme.startsWith('major') ? majorFontCs : minorFontCs;
          } else if (a['cs'] != null) {
            r.fontCs = a['cs']!.trim().toLowerCase();
            faceSpelling[r.fontCs!] = a['cs']!.trim();
          }
          if (a['hint'] != null) r.csHint = a['hint'] == 'cs';
        case 'spacing' || 'w' || 'kern' || 'fitText':
          if (e.name == 'kern') {
            r.kern = int.tryParse(e.val ?? '');
            break;
          }
          final v = int.tryParse(e.val ?? '0') ?? 0;
          if (e.name == 'w') {
            r.scaled = v != 100;
          } else {
            r.spacing = v != 0;
          }
        default:
          // Word 2010 text effects (glow, shadow, reflection, outline...).
          if (e.name.startsWith('{') && _effectNames.hasMatch(e.name)) {
            r.effects = true;
          }
      }
    }
    return r;
  }

  static final _effectNames = RegExp(
    '(glow|shadow|reflection|textOutline|textFill|props3d|scene3d)\$',
  );

  _ParaProps _paraProps(_El? pPr) {
    final p = _ParaProps();
    if (pPr == null) return p;
    for (final e in pPr.els) {
      switch (e.name) {
        case 'outlineLvl':
          p.outline = int.tryParse(e.val ?? '');
        case 'jc':
          p.jc = e.val;
        case 'ind':
          final a = e.attrs;
          int v(String k) => int.tryParse(a[k] ?? '0') ?? 0;
          p.indent =
              v('left') != 0 ||
              v('start') != 0 ||
              v('right') != 0 ||
              v('end') != 0 ||
              v('firstLine') != 0 ||
              v('hanging') != 0;
        case 'bidi':
          p.bidi = _on(e);
        case 'pBdr':
          // A border is drawn only by a side with a line.
          final drawn = e.els.any(
            (side) => !const {'none', 'nil'}.contains(side.val ?? 'none'),
          );
          p.border = p.border == true || drawn;
        case 'shd':
          final fill = (e.attrs['fill'] ?? 'auto').toLowerCase();
          p.border =
              p.border == true ||
              !(fill == 'auto' || fill == 'ffffff') ||
              (e.val != null && e.val != 'clear' && e.val != 'nil');
        case 'spacing':
          p.spacing = Map.of(e.attrs);
        case 'contextualSpacing':
          p.contextual = _on(e);
        case 'framePr':
          p.frame = true;
        case 'pageBreakBefore':
          p.pageBefore = _on(e);
        case 'numPr':
          final id = e.child('numId')?.val;
          final lvl = e.child('ilvl')?.val;
          if (id != null) p.numId = int.tryParse(id);
          if (lvl != null) p.ilvl = int.tryParse(lvl);
        case 'tabs':
          for (final t in e.els) {
            final kind = t.val ?? 'left';
            final pos = int.tryParse(t.attrs['pos'] ?? '0') ?? 0;
            final leader = t.attrs['leader'] ?? 'none';
            if (kind == 'clear') continue;
            if (kind != 'left' || leader != 'none' || pos % 720 != 0) {
              p.oddTabs = true;
            }
          }
      }
    }
    return p;
  }

  void _readStyles(String path) {
    final x = xml(path);
    if (x == null) return;
    final dd = x.child('docDefaults');
    defaults.over(_runProps(dd?.child('rPrDefault')?.child('rPr')));
    defaultPara.over(_paraProps(dd?.child('pPrDefault')?.child('pPr')));
    for (final s in x.els.where((e) => e.name == 'style')) {
      final id = s.attrs['styleId'];
      if (id == null) continue;
      final st = _Style()
        ..type = s.attrs['type'] ?? 'paragraph'
        ..basedOn = s.child('basedOn')?.val
        ..name = (s.child('name')?.val ?? '').toLowerCase();
      st.run.over(_runProps(s.child('rPr')));
      st.para.over(_paraProps(s.child('pPr')));
      styles[id] = st;
      if (st.type == 'paragraph' && s.attrs['default'] == '1') {
        normalStyle = id;
      }
    }
  }

  void _readNumbering(String path) {
    final x = xml(path);
    if (x == null) return;
    for (final a in x.els.where((e) => e.name == 'abstractNum')) {
      final id = a.attrs['abstractNumId'] ?? '';
      if (a.child('numStyleLink') != null || a.child('styleLink') != null) {
        abstractStyleLinked.add(id);
      }
      final levels = <int, _Level>{};
      for (final l in a.els.where((e) => e.name == 'lvl')) {
        final n = int.tryParse(l.attrs['ilvl'] ?? '') ?? 0;
        final restart = l.child('lvlRestart')?.val;
        final rPr = l.child('rPr');
        levels[n] = _Level()
          ..fmt = l.child('numFmt')?.val ?? 'decimal'
          ..text = l.child('lvlText')?.val ?? ''
          ..start = int.tryParse(l.child('start')?.val ?? '1') ?? 1
          ..restart = restart == null ? null : int.tryParse(restart)
          ..styled = rPr != null && _numberStyled(rPr)
          ..indented = _paraProps(l.child('pPr')).indent == true
          ..ind = l.child('pPr')?.child('ind')?.attrs ?? const {}
          ..font = (rPr?.child('rFonts')?.attrs['ascii'] ?? '').trim();
      }
      abstracts[id] = levels;
    }
    for (final n in x.els.where((e) => e.name == 'num')) {
      final id = int.tryParse(n.attrs['numId'] ?? '');
      final abs = n.child('abstractNumId')?.val;
      if (id == null || abs == null) continue;
      final num = _Num(abs);
      for (final o in n.els.where((e) => e.name == 'lvlOverride')) {
        final l = int.tryParse(o.attrs['ilvl'] ?? '') ?? 0;
        final st = o.child('startOverride')?.val;
        if (st != null) num.starts[l] = int.tryParse(st) ?? 1;
        if (o.child('lvl') != null) abstractStyleLinked.add('num$id');
      }
      nums[id] = num;
    }
  }

  /// The style chain of [id], deepest base first.
  List<_Style> _chain(String? id) {
    final out = <_Style>[];
    final seen = <String>{};
    var cur = id;
    while (cur != null && seen.add(cur)) {
      final st = styles[cur];
      if (st == null) break;
      out.insert(0, st);
      cur = st.basedOn;
    }
    return out;
  }

  _RunProps _effective(String? pStyle, String? rStyle, _RunProps direct) {
    final para = _RunProps();
    for (final s in _chain(pStyle ?? normalStyle)) {
      para.over(s.run);
    }
    final char = _RunProps();
    for (final s in _chain(rStyle)) {
      char.over(s.run);
    }
    final r = defaults.copy()
      ..over(para)
      ..over(char);
    // A toggle set by both styles cancels out (ECMA-376 17.7.3): italic
    // text in an italic paragraph style shows upright in Word.
    for (final n in _RunProps.toggles) {
      final a = para.toggle(n), b = char.toggle(n);
      if (a != null && b != null) r.setToggle(n, a != b);
    }
    r.over(direct);
    return r;
  }

  void _blocks(_El parent, {bool top = false}) {
    for (final e in parent.els) {
      switch (e.name) {
        case 'p':
          _paragraph(e);
        case 'tbl':
          problem('tables');
        case 'sdt':
          // A content control (Word's table of contents, a cover page...).
          problem('content controls');
          final c = e.child('sdtContent');
          if (c != null) _blocks(c);
        case 'customXml' || 'smartTag':
          _blocks(e);
        case 'customXmlPr' || 'smartTagPr':
          break;
        case 'sectPr':
          _section(e);
        case 'bookmarkStart' ||
            'bookmarkEnd' ||
            'proofErr' ||
            'permStart' ||
            'permEnd':
          break;
        case 'ins' || 'del' || 'moveFrom' || 'moveTo':
          problem('tracked changes');
          if (e.name == 'ins' || e.name == 'moveTo') _blocks(e);
        case 'altChunk':
          problem('embedded documents');
        default:
          if (e.name.contains('oMath')) {
            problem('equations');
          } else if (e.name.contains('AlternateContent')) {
            // Word's wrapper for drawings, text boxes and the like.
            problem('pictures');
          } else {
            problem('content Breeze cannot read');
          }
      }
    }
  }

  final _headerParts = <String, String>{};

  static bool _hasContent(_El e) {
    for (final c in e.els) {
      switch (c.name) {
        case 't' || 'delText' || 'instrText':
          if (c.text.trim().isNotEmpty) return true;
        case 'drawing' ||
            'pict' ||
            'object' ||
            'fldChar' ||
            'fldSimple' ||
            'sdt' ||
            'tbl' ||
            'sym' ||
            'tab' ||
            'ptab' ||
            'pgNum' ||
            'pBdr':
          return true;
        default:
          if (c.name.contains('AlternateContent') || _hasContent(c)) {
            return true;
          }
      }
    }
    return false;
  }

  bool _evenHeaders = false;

  // The page: size, orientation and margins, kept on save.
  Map<String, String>? pageSize, pageMargins;

  void _section(_El s) {
    final firstOn = s.child('titlePg') != null && _on(s.child('titlePg')!);
    pageSize = s.child('pgSz')?.attrs;
    pageMargins = s.child('pgMar')?.attrs;
    for (final e in s.els) {
      switch (e.name) {
        case 'vAlign':
          if ((e.val ?? 'top') != 'top') problem('page layout');
        case 'headerReference' || 'footerReference':
          // A first-page or even-page header Word does not show (the option
          // was turned off) stays in the file; it is not lost.
          final kind = e.attrs['type'] ?? 'default';
          if (kind == 'first' && !firstOn) continue;
          if (kind == 'even' && !_evenHeaders) continue;
          // Word keeps a header the user emptied: only one with something
          // in it is lost.
          final path = _headerParts[e.attrs['r:id'] ?? ''];
          final part = path == null ? null : xml(path);
          if (part == null || _hasContent(part)) problem('headers and footers');
        case 'cols':
          if ((int.tryParse(e.attrs['num'] ?? '1') ?? 1) > 1) {
            problem('columns');
          }
        case 'pgBorders':
          problem('borders or shading');
        case 'lnNumType':
          problem('line numbers');
      }
    }
  }

  // The paragraph being read.
  RtfPara? _cur;
  String? _pStyle;
  bool _heading = false;
  final _headingColours = <String>{};
  int _headingBold = 0, _headingPlain = 0;
  bool _inList = false;
  bool _oddTabs = false;

  void _paragraph(_El p) {
    final pPr = p.child('pPr');
    _pStyle = pPr?.child('pStyle')?.val;
    final props = _ParaProps()..over(defaultPara);
    for (final s in _chain(_pStyle ?? normalStyle)) {
      props.over(s.para);
    }
    final direct = _paraProps(pPr);
    props.over(direct);
    if (pPr?.child('sectPr') != null) problem('page breaks');
    final markPr = pPr?.child('rPr');
    if (markPr?.child('del') != null ||
        markPr?.child('ins') != null ||
        markPr?.child('rPrChange') != null ||
        pPr?.child('pPrChange') != null) {
      problem('tracked changes');
    }
    // A hidden paragraph mark: Word joins this paragraph to the next. One
    // with nothing visible in it is simply not there: not shown, and its
    // list item not counted (checked against Word).
    final mark = markPr?.child('vanish');
    final markHidden = mark != null && _on(mark);
    if (markHidden) problem('hidden text');
    final before = markHidden
        ? (counters.map((k, c) => MapEntry(k, c.copy())), Set.of(_startedNums))
        : null;
    if (props.pageBefore == true) problem('page breaks');
    if (props.frame == true) problem('text frames');
    if (props.bidi == true) problem('right-to-left text');
    if (props.border == true) problem('borders or shading');
    final jc = props.jc;
    if (jc != null && jc != 'left' && jc != 'start') problem('alignment');
    final name = styles[_pStyle]?.name ?? '';
    if (name == 'title' || name == 'subtitle') problem('title styles');

    // Heading: the paragraph's outline level, else its style's name.
    var outline = props.outline;
    if (outline == null || outline > 8) {
      final m = RegExp(r'^heading\s*(\d)$').firstMatch(name);
      outline = m == null ? null : int.parse(m[1]!) - 1;
    }
    if (outline != null && (outline < 0 || outline > 8)) outline = null;
    var kind = MdLineKind.plain;
    if (outline != null) {
      if (outline > 2) {
        problem('smaller headings');
      } else {
        kind = [MdLineKind.h1, MdLineKind.h2, MdLineKind.h3][outline];
      }
    }
    // A list item.
    var level = 0, number = 0;
    final numId = props.numId ?? 0;
    if (numId > 0) {
      final num = nums[numId];
      final lvl = (props.ilvl ?? 0).clamp(0, 8);
      final def = num == null ? null : abstracts[num.abstractId]?[lvl];
      if (def != null && def.fmt == 'none' && def.text.isEmpty) {
        // Numbering that draws nothing (LibreOffice's heading outline):
        // counted, as Word does, and otherwise not there. Its indent stays.
        _count(numId, num!, lvl);
        if (def.indented || props.indent == true) problem('indents');
      } else if (num == null || def == null) {
        problem('list styles');
      } else {
        if (abstractStyleLinked.contains(num.abstractId) ||
            abstractStyleLinked.contains('num$numId')) {
          problem('list styles');
        }
        if (kind != MdLineKind.plain) problem('numbered headings');
        level = lvl;
        // A level indented from the right: Breeze writes none.
        final defRight =
            int.tryParse(def.ind['right'] ?? def.ind['end'] ?? '') ?? 0;
        if (defRight != 0) problem('indents');
        // An item indented on its own (not by its level) is drawn further
        // in than Breeze will put it.
        final own = pPr?.child('ind')?.attrs;
        if (own != null) {
          int v(Map<String, String> a, String k, [String? k2]) =>
              int.tryParse(a[k] ?? (k2 == null ? '' : a[k2] ?? '')) ?? 0;
          var differs = false;
          for (final (k, k2) in [
            ('left', 'start'),
            ('hanging', null),
            ('firstLine', null),
          ]) {
            final mine =
                own.containsKey(k) || (k2 != null && own.containsKey(k2));
            if (mine && v(own, k, k2) != v(def.ind, k, k2)) differs = true;
          }
          // A right indent Breeze never writes.
          if (v(own, 'right', 'end') != v(def.ind, 'right', 'end')) {
            problem('indents');
          }
          if (differs) {
            // A bullet pushed in by hand to exactly where another level of
            // the same list draws, with the same bullet, is that level in
            // all but name: read (and saved) as that level, nothing moves.
            // Only in a list with no numbered level, so no count can
            // shift. Anything else stays as found.
            final levels = abstracts[num.abstractId]!;
            int? same;
            if (levels.values.every((l) => l.fmt == 'bullet') && !def.styled) {
              int at(Map<String, String> a) => v(a, 'left', 'start');
              int hang(Map<String, String> a) =>
                  v(a, 'hanging') - v(a, 'firstLine');
              final ownAt = own.containsKey('left') || own.containsKey('start')
                  ? at(own)
                  : at(def.ind);
              final ownHang =
                  own.containsKey('hanging') || own.containsKey('firstLine')
                  ? hang(own)
                  : hang(def.ind);
              for (final e in levels.entries) {
                final o = e.value;
                if (e.key == lvl || o.styled) continue;
                if (o.text != def.text || o.font != def.font) continue;
                // Where Breeze writes that level, too (Word's own 0.5 inch
                // steps): then the item is where it was before the save.
                if (at(o.ind) == ownAt &&
                    hang(o.ind) == ownHang &&
                    ownAt == 720 * (e.key + 1) &&
                    ownHang == 360) {
                  same = e.key;
                  break;
                }
              }
            }
            if (same == null) {
              problem('indents');
            } else {
              level = same;
            }
          }
        }
        final counted = _count(numId, num, level);
        if (def.styled) problem('list numbering styles');
        if (def.fmt == 'bullet') {
          final t = def.text.runes.toList();
          if (t.length != 1 || !_bulletChars.contains(t.single)) {
            problem('bullet styles');
          } else {
            final m = _bulletLooks.putIfAbsent(level, () => {});
            final k = '${def.text}|${def.font}';
            m[k] = (m[k] ?? 0) + 1;
          }
          if (kind == MdLineKind.plain) kind = MdLineKind.bullet;
        } else if (def.fmt == 'decimal' && def.text == '%${lvl + 1}.') {
          if (kind == MdLineKind.plain) {
            kind = MdLineKind.numbered;
            number = counted;
          }
        } else {
          problem('list numbering styles');
        }
      }
    } else if (props.indent == true) {
      problem('indents');
    }
    _inList = kind == MdLineKind.bullet || kind == MdLineKind.numbered;
    _heading = outline != null;
    _oddTabs = props.oddTabs == true;
    _headingColours.clear();
    _headingLatin.clear();
    _headingCs.clear();
    _headingBold = 0;
    _headingPlain = 0;
    _cur = RtfPara(kind, level, number);
    // The paragraph spacing, by kind of paragraph, kept on save.
    final space = _spacingKey(props.spacing, props.contextual == true);
    final spaces = outline != null
        ? _headingSpacing.putIfAbsent(outline, () => {})
        : _inList
        ? _listSpacing
        : _bodySpacing;
    if (p.els.any((e) => e.name == 'r' || e.name == 'hyperlink')) {
      spaces[space] = (spaces[space] ?? 0) + 1;
    }
    _inline(p, null);
    if (before != null && (_cur?.units.isEmpty ?? false)) {
      counters
        ..clear()
        ..addAll(before.$1);
      _startedNums
        ..clear()
        ..addAll(before.$2);
      _cur = null;
      _csFlags.clear();
      _paraOutside.clear();
      _paraHasCs = false;
    }
    _end();
  }

  // Paragraph spacing seen, as "key=value;..." strings, by kind.
  final _bodySpacing = <String, int>{}, _listSpacing = <String, int>{};
  final _headingSpacing = <int, Map<String, int>>{};

  // Bullet glyph|font used, by list level.
  final _bulletLooks = <int, Map<String, int>>{};

  // Heading text looks (font|size|colour|bold), by level.
  final _headingLooks = <int, Map<String, int>>{};

  static const _spacingAttrs = {
    'before',
    'after',
    'line',
    'lineRule',
    'beforeAutospacing',
    'afterAutospacing',
  };

  static String _spacingKey(Map<String, String> a, bool contextual) {
    final keys = a.keys.where(_spacingAttrs.contains).toList()..sort();
    return [
      for (final k in keys) '$k=${a[k]}',
      if (contextual) 'contextual',
    ].join(';');
  }

  /// The number Word shows for an item at [lvl] of list [numId] (bullets
  /// count too: they reset the levels below them).
  int _count(int numId, _Num num, int lvl) {
    final levels = abstracts[num.abstractId] ?? const <int, _Level>{};
    final c = counters.putIfAbsent(num.abstractId, _WordCounter.new);
    if (_startedNums.add(numId)) {
      // Word applies a restart at a level above the num's first item only
      // later, by rules Breeze does not model: such a list is not edited.
      if (num.starts.keys.any((l) => l < lvl)) problem('list styles');
      num.starts.forEach(c.restartAt);
    }
    return c.item(
      lvl,
      (l) => num.starts[l] ?? levels[l]?.start ?? 1,
      (l) => levels[l]?.restart,
    );
  }

  /// Whether a list level's own run look changes how its number shows.
  bool _numberStyled(_El rPr) {
    for (final e in rPr.els) {
      switch (e.name) {
        case 'b' || 'i' || 'strike' || 'dstrike' || 'caps' || 'smallCaps':
          if (_on(e)) return true;
        case 'u':
          if ((e.val ?? 'single') != 'none') return true;
        case 'sz':
          return true;
        case 'color':
          final v = (e.val ?? 'auto').toLowerCase();
          if (v != 'auto' && v != '000000') return true;
        case 'highlight' || 'shd' || 'vertAlign':
          return true;
      }
    }
    return false;
  }

  void _end() {
    if (_paraHasCs) {
      _paraOutside.forEach(
        (u, n) => _outsideNearCs[u] = (_outsideNearCs[u] ?? 0) + n,
      );
    }
    _paraHasCs = false;
    _paraOutside.clear();
    final p = _cur;
    if (p == null) {
      _csFlags.clear();
      return;
    }
    // Which characters were in Hindi (w:cs) runs, by the paragraph's text:
    // a paragraph saved unchanged is written back exactly so.
    if (_csFlags.length == p.units.length && _csFlags.contains(true)) {
      paraCs.putIfAbsent(
        String.fromCharCodes(p.units),
        () => List.of(_csFlags),
      );
    }
    _csFlags.clear();
    if (_oddTabs && p.units.contains(0x09)) problem('tab stops');
    if (_heading) {
      for (final keys in [_headingLatin, _headingCs]) {
        String part(String k, bool face) {
          final cut = k.lastIndexOf('|');
          return face ? k.substring(0, cut) : k.substring(cut + 1);
        }

        if (keys.map((k) => part(k, true)).toSet().length > 1) {
          problem('fonts');
        }
        if (keys.map((k) => part(k, false)).toSet().length > 1) {
          problem('text sizes');
        }
      }
    }
    if (_heading && _headingBold > 0 && _headingPlain > 0) {
      problem('bold inside headings');
    }
    paras.add(p);
    _cur = null;
  }

  /// A line break inside a paragraph: Markdown has none, so the rest is a
  /// paragraph of its own (lost structure in a list item or a heading).
  void _lineBreak() {
    if (_inList || _heading) problem('line breaks in lists or headings');
    _end();
    _cur = RtfPara(MdLineKind.plain, 0, 0);
    _inList = false;
    _heading = false;
  }

  // A complex field in progress (fldChar begin ... separate ... end).
  final _fields = <_Field>[];

  String? get _fieldLink {
    for (final f in _fields.reversed) {
      if (f.result) return f.link;
    }
    return null;
  }

  bool get _inFieldCode => _fields.isNotEmpty && !_fields.last.result;

  void _inline(_El parent, String? link) {
    for (final e in parent.els) {
      switch (e.name) {
        case 'pPr':
          break;
        case 'r':
          _run(e, link);
        case 'hyperlink':
          final id = e.attrs['r:id'];
          String? url;
          if (id != null) {
            url = rels[id];
            if (url == null) {
              problem('broken links');
            } else if (url == '#internal') {
              url = null;
              problem('links inside the document');
            }
          }
          if (e.attrs['anchor'] != null) {
            problem('links inside the document');
          }
          if (e.attrs['tooltip'] != null) problem('link tooltips');
          _inline(e, url ?? link);
        case 'fldSimple':
          final f = _Field()..code = e.attrs['instr'] ?? '';
          final url = f.judge(this);
          _inline(e, url ?? link);
        case 'ins' || 'moveTo':
          problem('tracked changes');
          _inline(e, link);
        case 'del' || 'moveFrom':
          problem('tracked changes');
        case 'smartTag' || 'customXml' || 'dir' || 'bdo':
          if (e.name == 'dir' || e.name == 'bdo') problem('right-to-left text');
          _inline(e, link);
        case 'sdt':
          problem('content controls');
          final c = e.child('sdtContent');
          if (c != null) _inline(c, link);
        case 'bookmarkStart' ||
            'bookmarkEnd' ||
            'proofErr' ||
            'permStart' ||
            'permEnd' ||
            'lastRenderedPageBreak':
          break;
        case 'commentRangeStart' || 'commentRangeEnd':
          problem('comments');
        case 'customXmlPr' || 'smartTagPr':
          break;
        default:
          if (e.name.contains('oMath')) {
            problem('equations');
          } else {
            problem('content Breeze cannot read');
          }
      }
    }
  }

  void _run(_El r, String? link) {
    final rPr = r.child('rPr');
    if (rPr?.child('del') != null || rPr?.child('ins') != null) {
      problem('tracked changes');
    }
    final props = _effective(
      _pStyle,
      rPr?.child('rStyle')?.val,
      _runProps(rPr),
    );
    for (final e in r.els) {
      switch (e.name) {
        case 'rPr':
          break;
        case 't':
          if (_inFieldCode) break;
          // Without xml:space="preserve" Word drops the spaces at either
          // end of the text, so they are not there.
          var text = e.text;
          if (e.attrs['xml:space'] != 'preserve') {
            text = text.replaceAll(RegExp(r'^[ \t\r\n]+|[ \t\r\n]+$'), '');
          }
          for (final u in text.codeUnits) {
            _char(u, props, link);
          }
        case 'tab':
          if (!_inFieldCode) _char(0x09, props, link);
        case 'noBreakHyphen':
          _char(0x2011, props, link);
        case 'softHyphen':
          _char(0x00AD, props, link);
        case 'br' || 'cr':
          final type = e.attrs['type'];
          if (type == 'page') {
            problem('page breaks');
          } else if (type == 'column') {
            problem('columns');
          } else {
            _lineBreak();
          }
        case 'sym':
          problem('symbols');
        case 'drawing' || 'pict' || 'object':
          problem('pictures');
        case 'footnoteReference' || 'endnoteReference':
          problem('footnotes');
        case 'commentReference' || 'annotationRef':
          problem('comments');
        case 'fldChar':
          final t = e.attrs['fldCharType'];
          if (t == 'begin') {
            _fields.add(_Field());
          } else if (t == 'separate' && _fields.isNotEmpty) {
            final f = _fields.last..result = true;
            f.link = f.judge(this);
          } else if (t == 'end' && _fields.isNotEmpty) {
            final f = _fields.removeLast();
            // A field with no result part still has to be judged.
            if (!f.result) f.judge(this);
          }
        case 'instrText':
          if (_fields.isNotEmpty) _fields.last.code += e.text;
        case 'delText' || 'delInstrText':
          problem('tracked changes');
        case 'lastRenderedPageBreak':
          break;
        case 'ptab':
          problem('tab stops');
        default:
          if (e.name.contains('AlternateContent') || e.name.contains('}')) {
            problem('pictures');
          } else {
            problem('content Breeze cannot read');
          }
      }
    }
  }

  void _char(int u, _RunProps c, String? fieldOrLink) {
    final p = _cur;
    if (p == null) return;
    final link = fieldOrLink ?? _fieldLink;
    if (c.hidden == true) {
      if (u != 0x20) problem('hidden text');
      return;
    }
    if (u < 0x20 && u != 0x09) {
      problem('content Breeze cannot read');
      return;
    }
    // Word draws a run with the complex-script properties (bCs, szCs, the
    // cs font) only when it is marked w:cs or w:rtl, whatever its script:
    // Hindi typed in Word is marked; unmarked Hindi uses b, sz, hAnsi.
    final complex = c.csRun == true || c.rtl == true;
    final bold = complex ? c.bCs == true : c.b == true;
    final italic = complex ? c.iCs == true : c.i == true;
    var a = 0;
    if (bold) a |= Md.bold;
    if (italic) a |= Md.italic;
    final ul = c.u ?? 'none';
    if (ul != 'none') a |= Md.underline;
    if (c.strike == true || c.dstrike == true) a |= Md.strike;
    p.add(u, a, link);
    _csFlags.add(complex);
    final shows = !(u == 0x20 || u == 0x09 || u == 0xA0);
    if (!shows) return;
    if (ul != 'none' && ul != 'single') problem('underline styles');
    if (c.dstrike == true) problem('double strikethrough');
    if (c.caps == true ||
        c.smallCaps == true ||
        c.effects == true ||
        c.spacing == true ||
        c.scaled == true) {
      problem('text effects');
    }
    if (c.sup == true || c.raised == true) {
      problem('superscript or subscript');
    }
    if (c.rtl == true) problem('right-to-left text');
    if (c.marked == true || c.shaded == true) problem('highlighting');
    if (c.tracked == true) problem('tracked changes');
    // Wingdings and the like: a picture stored as a private character.
    if (u >= 0xE000 && u <= 0xF8FF) problem('symbols');
    if (_heading) {
      if (bold) {
        _headingBold++;
      } else {
        _headingPlain++;
      }
    }
    // Colour: black in body text; one colour per heading; a link blue.
    final col = c.color ?? 'auto';
    final plainColour = col == 'auto' || col == '000000';
    if (link != null) {
      if (!plainColour && !_blue(col)) problem('colours');
    } else if (_heading) {
      if (!plainColour) _headingColours.add(col);
      if (_headingColours.length > 1) problem('colours');
    } else if (!plainColour) {
      problem('colours');
    }
    // Font and size, against the body text's, in the slot Word draws this
    // character with: complex scripts (and, under a "cs" hint, digits and
    // punctuation) with the cs font and size, the rest with the Latin ones.
    // Emoji, joiners and East Asian text Word sets in fonts of its own
    // choosing, so they are not judged.
    if (!_selfFonted(u)) {
      final letterCs = _complexScript(u);
      final inCs = complex || (c.csHint == true && !_letter(u));
      if (letterCs) _paraHasCs = true;
      if (!letterCs && inCs && !_letter(u)) {
        // A digit or punctuation mark drawn with a Hindi run's look. Word
        // puts some inside the run as it types (: ( ) -) and some outside
        // (digits , ?); Breeze writes each character the way this document
        // mostly has it (DocxLook.neutralsInCs). Its font follows the
        // letters, so it is not judged.
        _inCs[u] = (_inCs[u] ?? 0) + 1;
        return;
      }
      if (!letterCs && !_letter(u)) {
        _paraOutside[u] = (_paraOutside[u] ?? 0) + 1;
      }
      // Hindi letters go in the cs slot whether or not their run is marked
      // (Breeze writes them all marked): an unmarked run draws them with
      // its Latin size and hAnsi font.
      final cs = letterCs;
      final size = (complex ? (c.szCs ?? c.sz) : c.sz) ?? 22;
      var face = _family(complex ? c.fontCs : (u < 0x80 ? c.font : c.fontH));
      // The theme's own font for this script is what an unnamed cs font
      // draws with anyway.
      if (complex && cs) {
        final tag = _scriptTag(u);
        if (tag != null && scriptFonts[tag] == face) {
          face = '';
          _themeScripts[tag] = (_themeScripts[tag] ?? 0) + 1;
        }
      }
      final key = '$face|$size';
      if (_heading && !cs) {
        final level = switch (_cur?.kind) {
          MdLineKind.h1 => 0,
          MdLineKind.h2 => 1,
          MdLineKind.h3 => 2,
          _ => null,
        };
        if (level != null) {
          final look =
              '${faceSpelling[face] ?? face}|$size|'
              '${c.colorHex ?? 'auto'}|${c.b == true}';
          final m = _headingLooks.putIfAbsent(level, () => {});
          m[look] = (m[look] ?? 0) + 1;
        }
      }
      if (_heading) {
        // A heading is written in Breeze's heading style, so its own look
        // goes; only a mix inside one heading is a loss worth naming.
        (cs ? _headingCs : _headingLatin).add(key);
      } else {
        final looks = cs ? _csLooks : _latinLooks;
        looks[key] = (looks[key] ?? 0) + 1;
      }
    }
  }

  final _headingLatin = <String>{}, _headingCs = <String>{};

  // Where digits and punctuation beside Hindi sit: inside its runs, or in
  // runs of their own (as Word types them).
  final _inCs = <int, int>{}, _outsideNearCs = <int, int>{};
  final _csFlags = <bool>[];
  final paraCs = <String, List<bool>>{};
  final _paraOutside = <int, int>{};
  bool _paraHasCs = false;

  // Text drawn in the theme's font for its script, by script.
  final _themeScripts = <String, int>{};

  // How much body text is in each font and size (Latin and cs slots).
  // A document set in one font and size throughout (Ctrl+A, Arial 12) is
  // that document's body look and is kept on save; only a MIX is lost.
  final _latinLooks = <String, int>{};
  final _csLooks = <String, int>{};

  static (String, int)? _dominant(Map<String, int> looks) {
    if (looks.isEmpty) return null;
    final best = looks.entries.reduce((a, b) => b.value > a.value ? b : a);
    final cut = best.key.lastIndexOf('|');
    return (best.key.substring(0, cut), int.parse(best.key.substring(cut + 1)));
  }

  // The Normal style's run properties, document defaults included.
  _RunProps get _normalRun {
    final r = _RunProps()..over(defaults);
    for (final st in _chain(normalStyle)) {
      r.over(st.run);
    }
    return r;
  }

  static String? _top(Map<String, int> counts) => counts.isEmpty
      ? null
      : counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;

  void _judgeLooks() {
    // One bullet per list level is what a save keeps: two at one level
    // would quietly become the commoner one.
    if (_bulletLooks.values.any((m) => m.length > 1)) problem('bullet styles');
    for (final looks in [_latinLooks, _csLooks]) {
      final faces = looks.keys.map((k) => k.substring(0, k.lastIndexOf('|')));
      final sizes = looks.keys.map((k) => k.substring(k.lastIndexOf('|') + 1));
      if (faces.toSet().length > 1) problem('fonts');
      if (sizes.toSet().length > 1) problem('text sizes');
    }
  }

  /// The document's body font and size, as Breeze writes them back.
  DocxLook get look {
    final latin = _dominant(_latinLooks);
    final cs = _dominant(_csLooks);
    String? spell(String? f) =>
        f == null || f.isEmpty ? null : (faceSpelling[f] ?? f);
    Map<String, int>? ints(Map<String, String>? a) {
      if (a == null) return null;
      final out = <String, int>{};
      a.forEach((k, v) {
        final n = int.tryParse(v);
        if (n != null) out[k] = n;
      });
      return out;
    }

    return DocxLook(
      font: spell(latin?.$1),
      size: latin?.$2,
      // An unnamed cs font is the theme's font for the script (Mangal for
      // Hindi); Breeze writes no theme, so it names that font.
      fontCs:
          spell(cs?.$1) ??
          (_themeScripts.isEmpty
              ? null
              : spell(
                  scriptFonts[_themeScripts.entries
                      .reduce((a, b) => b.value > a.value ? b : a)
                      .key],
                )),
      sizeCs: cs?.$2,
      pageSize: ints(pageSize),
      landscape: pageSize?['orient'] == 'landscape',
      pageMargins: ints(pageMargins),
      bodySpacing: _top(_bodySpacing),
      listSpacing: _top(_listSpacing),
      headingSpacing: {
        for (final e in _headingSpacing.entries)
          if (_top(e.value) != null) e.key: _top(e.value)!,
      },
      headings: {
        for (final e in _headingLooks.entries)
          if (_top(e.value) != null) e.key: _top(e.value)!,
      },
      bullets: {
        for (final e in _bulletLooks.entries)
          if (_top(e.value) != null) e.key: _top(e.value)!,
      },
      kern: _normalRun.kern,
      paraCs: paraCs,
      neutralsInCs: {
        for (final e in _inCs.entries)
          if (e.value > (_outsideNearCs[e.key] ?? 0)) e.key,
      },
    );
  }

  /// The theme's script tag of [u] (Deva for Hindi...), if it has one.
  static String? _scriptTag(int u) {
    const ranges = [
      (0x0590, 0x05FF, 'Hebr'),
      (0x0600, 0x06FF, 'Arab'),
      (0x0700, 0x074F, 'Syrc'),
      (0x0750, 0x077F, 'Arab'),
      (0x0780, 0x07BF, 'Thaa'),
      (0x08A0, 0x08FF, 'Arab'),
      (0x0900, 0x097F, 'Deva'),
      (0x0980, 0x09FF, 'Beng'),
      (0x0A00, 0x0A7F, 'Guru'),
      (0x0A80, 0x0AFF, 'Gujr'),
      (0x0B00, 0x0B7F, 'Orya'),
      (0x0B80, 0x0BFF, 'Taml'),
      (0x0C00, 0x0C7F, 'Telu'),
      (0x0C80, 0x0CFF, 'Knda'),
      (0x0D00, 0x0D7F, 'Mlym'),
      (0x0D80, 0x0DFF, 'Sinh'),
      (0x0E00, 0x0E7F, 'Thai'),
      (0x0E80, 0x0EFF, 'Laoo'),
      (0x0F00, 0x0FFF, 'Tibt'),
      (0x1000, 0x109F, 'Mymr'),
      (0x1780, 0x17FF, 'Khmr'),
      (0xA8E0, 0xA8FF, 'Deva'),
      (0xFB1D, 0xFB4F, 'Hebr'),
      (0xFB50, 0xFDFF, 'Arab'),
      (0xFE70, 0xFEFF, 'Arab'),
    ];
    for (final (lo, hi, tag) in ranges) {
      if (u >= lo && u <= hi) return tag;
    }
    return null;
  }

  static bool _complexScript(int u) =>
      (u >= 0x0590 && u <= 0x08FF) || // Hebrew, Arabic, Syriac, Thaana
      (u >= 0x0900 && u <= 0x0DFF) || // Indic scripts
      (u >= 0x0E00 && u <= 0x0FFF) || // Thai, Lao, Tibetan
      (u >= 0x1000 && u <= 0x109F) || // Myanmar
      (u >= 0x1780 && u <= 0x17FF) || // Khmer
      (u >= 0xA8E0 && u <= 0xA8FF) || // Devanagari extended
      (u >= 0xFB1D && u <= 0xFDFF) || // Hebrew and Arabic forms
      (u >= 0xFE70 && u <= 0xFEFF);

  /// Characters Word draws in a font of its own choosing (emoji, joiners,
  /// variation selectors, symbols) or in the East Asian slot.
  static bool _selfFonted(int u) =>
      (u >= 0xD800 && u <= 0xDFFF) ||
      (u >= 0x200B && u <= 0x200F) ||
      (u >= 0x20D0 && u <= 0x20FF) || // combining marks for symbols (keycaps)
      (u >= 0x2100 && u <= 0x218F) || // letterlike symbols, number forms
      (u >= 0xFE00 && u <= 0xFE0F) ||
      (u >= 0x2190 && u <= 0x2BFF) ||
      (u >= 0x2E80 && u <= 0xA4CF) ||
      (u >= 0xAC00 && u <= 0xD7AF) ||
      (u >= 0xF900 && u <= 0xFAFF) ||
      (u >= 0xFF00 && u <= 0xFFEF) ||
      (u >= 0xE000 && u <= 0xF8FF);

  static bool _letter(int u) =>
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      (u >= 0xC0 && u <= 0x24F && u != 0xD7 && u != 0xF7) ||
      (u >= 0x370 && u <= 0x3FF) ||
      (u >= 0x400 && u <= 0x4FF) ||
      _complexScript(u);

  static bool _blue(String hex) {
    if (hex.length != 6) return hex == 'theme';
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return false;
    final r = v >> 16, g = (v >> 8) & 0xFF, b = v & 0xFF;
    return b > 100 && b > r + 40 && b > g + 20;
  }

  static String _family(String? f) => (f ?? '').trim().toLowerCase();
}

class _Field {
  String code = '';
  bool result = false;
  String? link;

  /// The address of a HYPERLINK field, or null (other fields are noted).
  String? judge(_Docx d) {
    final c = code.trim();
    final m = RegExp(r'^HYPERLINK\b(.*)$', dotAll: true).firstMatch(c);
    if (m == null) {
      if (c.isNotEmpty) d.problem('fields');
      return null;
    }
    // Switches outside quotes: \l is a place in this document, \o a tooltip.
    final rest = m[1]!;
    final outside = rest.replaceAll(RegExp(r'"[^"]*"'), '');
    if (RegExp(r'\\l\b').hasMatch(outside)) {
      d.problem('links inside the document');
      return null;
    }
    if (RegExp(r'\\o\b').hasMatch(outside)) d.problem('link tooltips');
    final q = RegExp(r'"([^"]*)"').firstMatch(rest);
    final url = q != null
        ? q[1]!
        : outside
              .trim()
              .split(RegExp(r'\s+'))
              .firstWhere(
                (w) => w.isNotEmpty && !w.startsWith(r'\'),
                orElse: () => '',
              );
    return url.isEmpty ? null : url;
  }
}

Map<String, List<int>>? _unzip(List<int> bytes) {
  try {
    final a = ZipDecoder().decodeBytes(bytes);
    final out = <String, List<int>>{};
    for (final f in a.files) {
      // Only the XML parts are read: pictures and fonts stay packed.
      if (!f.isFile || !(f.name.endsWith('.xml') || f.name.endsWith('.rels'))) {
        continue;
      }
      out[f.name] = f.content;
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// [bytes] (a .docx) as Markdown-lite, with what could not be kept.
RtfRead readDocx(List<int> bytes) {
  final files = _unzip(bytes);
  if (files == null) {
    return const RtfRead('', ['content Breeze cannot read'], native: false);
  }
  final d = _Docx(files);
  try {
    if (!d.run()) {
      return const RtfRead('', ['content Breeze cannot read'], native: false);
    }
  } catch (_) {
    return const RtfRead('', ['content Breeze cannot read'], native: false);
  }
  // Word ends every document with a paragraph; Breeze's text has no
  // trailing empty line unless it was typed. Nothing else is trimmed.
  return finishRead(d.paras, d.problems, native: d.breeze);
}

/// A document's body font and size (null: Breeze's own Calibri 11).
class DocxLook {
  const DocxLook({
    this.font,
    this.size,
    this.fontCs,
    this.sizeCs,
    this.pageSize,
    this.landscape = false,
    this.bodySpacing,
    this.listSpacing,
    this.headingSpacing = const {},
    this.headings = const {},
    this.bullets = const {},
    this.kern,
    this.pageMargins,
    this.neutralsInCs = const {},
    this.paraCs = const {},
  });
  final String? font, fontCs;
  final int? size, sizeCs; // half-points

  /// The page (twentieths of a point): w and h; top, right, bottom, left,
  /// header, footer, gutter.
  final Map<String, int>? pageSize, pageMargins;
  final bool landscape;

  /// Paragraph spacing ("after=160;line=259;lineRule=auto;contextual") of
  /// body text, list items and each heading level (0-2).
  final String? bodySpacing, listSpacing;
  final Map<int, String> headingSpacing;

  /// Each heading level's text look: "font|size|colour|bold".
  final Map<int, String> headings;

  /// Each list level's bullet: "glyph|font" (font may be empty).
  final Map<int, String> bullets;

  /// The document's default kerning threshold (w:kern), if any.
  final int? kern;

  /// The digits and punctuation that sat inside the Hindi (w:cs) runs
  /// beside Hindi more often than outside them.
  final Set<int> neutralsInCs;

  /// Per paragraph text: which characters sat in Hindi (w:cs) runs.
  final Map<String, List<bool>> paraCs;
}

/// The body look of [bytes] (a .docx), or null if it cannot be read.
DocxLook? docxLook(List<int> bytes) {
  final files = _unzip(bytes);
  if (files == null) return null;
  final d = _Docx(files);
  try {
    return d.run() ? d.look : null;
  } catch (_) {
    return null;
  }
}

/// The visible text of [bytes] (a .docx), for previews and search.
String docxPlainText(List<int> bytes) {
  final files = _unzip(bytes);
  final doc = files?['word/document.xml'];
  if (doc == null) return '';
  try {
    final root = _parseXml(utf8.decode(doc));
    final out = StringBuffer();
    void walk(_El e) {
      for (final c in e.els) {
        if (c.name == 'p') {
          walk(c);
          out.write('\n');
        } else if (c.name == 't') {
          out.write(c.text);
        } else if (c.name == 'tab') {
          out.write('\t');
        } else if (c.name == 'br' || c.name == 'cr') {
          out.write('\n');
        } else if (c.name == 'delText' || c.name == 'instrText') {
          continue;
        } else {
          walk(c);
        }
      }
    }

    walk(root);
    return out.toString().trimRight();
  } catch (_) {
    return '';
  }
}

// -- writing -------------------------------------------------------------

/// [md] (the editor's text) as a .docx. Read back before it is returned:
/// a document that does not read as exactly [md] throws [StateError], so a
/// save never writes something other than what was typed.
Uint8List writeDocx(String md, {DocxLook? look}) {
  final paras = mdToModel(md);
  final out = _write(paras, md, look);
  final back = readDocx(out);
  if (!back.editable) {
    throw StateError('Word round trip refused: ${back.unsupported}');
  }
  if (!sameModel(mdToModel(back.markdown), paras)) {
    throw StateError('Word round trip differs');
  }
  return out;
}

/// [writeDocx] in the body font and size of [a].$2 (the file being saved
/// over), for `compute`.
Uint8List writeDocxKeeping((String, List<int>?) a) =>
    writeDocx(a.$1, look: a.$2 == null ? null : docxLook(a.$2!));

/// For a paragraph edited since it was read: which of its characters were
/// in Hindi (w:cs) runs, taken from the old paragraph it keeps most of -
/// the same start and the same end; null for what was typed in between.
/// Null when no old paragraph keeps at least half of it.
List<bool?>? _editedCs(DocxLook? look, List<int> units) {
  if (look == null || look.paraCs.isEmpty) return null;
  final n = units.length;
  List<bool?>? best;
  var bestKept = 0;
  var tried = 0;
  for (final e in look.paraCs.entries) {
    if (++tried > 5000) break;
    final old = e.key.codeUnits;
    final flags = e.value;
    final m = old.length;
    if (flags.length != m) continue;
    var pre = 0;
    while (pre < n && pre < m && old[pre] == units[pre]) {
      pre++;
    }
    var suf = 0;
    while (suf < n - pre &&
        suf < m - pre &&
        old[m - 1 - suf] == units[n - 1 - suf]) {
      suf++;
    }
    final kept = pre + suf;
    if (kept > bestKept) {
      bestKept = kept;
      best = [
        for (var i = 0; i < n; i++)
          i < pre
              ? flags[i]
              : i >= n - suf
              ? flags[m - (n - i)]
              : null,
      ];
    }
  }
  return bestKept > 0 && bestKept * 2 >= n ? best : null;
}

/// A character Word's XML cannot hold (a control character, a lone half of
/// an emoji): the save stops rather than change the text.
void _checkChar(int u, int next, int prev) {
  final bad =
      (u < 0x20 && u != 0x09) ||
      u == 0xFFFE ||
      u == 0xFFFF ||
      (u >= 0xD800 && u <= 0xDBFF && !(next >= 0xDC00 && next <= 0xDFFF)) ||
      (u >= 0xDC00 && u <= 0xDFFF && !(prev >= 0xD800 && prev <= 0xDBFF));
  if (bad) {
    throw StateError('a character Word cannot store');
  }
}

Uint8List _write(List<RtfPara> paras, String md, DocxLook? look) {
  final body = StringBuffer();
  final links = <String>[];
  // Numbered lists: one Word list per run that Word's own counting
  // ([_WordCounter], the reader's) shows with the note's numbers. Each has
  // its own abstract list, so no two count on together; a new one starts
  // wherever Word would show a different number.
  final numbered = <List<int>>[]; // per list: start per level
  List<int>? curStarts;
  _WordCounter? counter;

  void newList(int level, int number) {
    curStarts = List.filled(9, 1)..[level] = number;
    counter = _WordCounter();
    numbered.add(curStarts!);
  }

  for (final p in paras) {
    body.write('<w:p>');
    final pPr = StringBuffer();
    var numId = 0;
    switch (p.kind) {
      case MdLineKind.h1:
        pPr.write('<w:pStyle w:val="Heading1"/>');
      case MdLineKind.h2:
        pPr.write('<w:pStyle w:val="Heading2"/>');
      case MdLineKind.h3:
        pPr.write('<w:pStyle w:val="Heading3"/>');
      case MdLineKind.bullet:
        numId = 1;
      case MdLineKind.numbered:
        final l = p.level;
        int start(int k) => curStarts![k];
        final c = counter;
        if (c == null || c.peek(l, start) != p.number) newList(l, p.number);
        final shown = counter!.item(l, start, (_) => null);
        assert(shown == p.number);
        numId = numbered.length + 1;
      default:
        break;
    }
    if (numId > 0) {
      pPr.write(
        '<w:pStyle w:val="ListParagraph"/><w:numPr>'
        '<w:ilvl w:val="${p.level}"/><w:numId w:val="$numId"/></w:numPr>',
      );
    }
    if (pPr.isNotEmpty) body.write('<w:pPr>$pPr</w:pPr>');
    final known =
        look?.paraCs[String.fromCharCodes(p.units)] ?? _editedCs(look, p.units);
    // Runs: characters with the same look and link together; the runs of
    // one link in one w:hyperlink, so Word sees one link.
    String? openLink;
    StringBuffer? openRuns;
    void closeLink() {
      if (openRuns == null) return;
      body.write(
        '<w:hyperlink r:id="rIdL${links.length}" w:history="1">'
        '$openRuns</w:hyperlink>',
      );
      openRuns = null;
      openLink = null;
    }

    var i = 0;
    final n = p.units.length;
    while (i < n) {
      final a = p.attrs[i];
      final link = p.links[i];
      // Hindi, Arabic, Thai... go in runs marked w:cs, as Word writes them
      // when they are typed: Word then draws them with bCs, szCs and the cs
      // font. Spaces, digits and punctuation join the run they are in.
      int script(int at) {
        final u = p.units[at];
        if (_Docx._complexScript(u)) return 1;
        // A paragraph the user did not change: as it was.
        // An edited one: as it was where it was kept.
        if (known != null) {
          if (_Docx._letter(u)) return 0;
          final was = known[at];
          if (was != null) return was ? 1 : 0;
        }
        // Spaces, joiners and marks join the run they are in; digits and
        // punctuation are Latin, as Word types them, unless the document
        // being saved over had them inside its Hindi runs.
        if (u == 0x20 ||
            u == 0xA0 ||
            u == 0x09 ||
            u == 0x200C ||
            u == 0x200D ||
            (u >= 0x0300 && u <= 0x036F) ||
            (u >= 0xFE00 && u <= 0xFE0F)) {
          return -1;
        }
        if (look != null && look.neutralsInCs.contains(u)) return -1;
        return 0;
      }

      var cs = -1;
      var j = i;
      while (j < n && p.attrs[j] == a && p.links[j] == link) {
        final k = script(j);
        if (k != -1) {
          if (cs == -1) {
            cs = k;
          } else if (k != cs) {
            break;
          }
        }
        j++;
      }
      final rPr = StringBuffer();
      if (link != null) rPr.write('<w:rStyle w:val="Hyperlink"/>');
      // The cs twins too: Word draws Hindi, Arabic and Thai with them.
      if (a & Md.bold != 0) rPr.write('<w:b/><w:bCs/>');
      if (a & Md.italic != 0) rPr.write('<w:i/><w:iCs/>');
      if (a & Md.strike != 0) rPr.write('<w:strike/>');
      if (a & Md.underline != 0) rPr.write('<w:u w:val="single"/>');
      if (cs == 1) rPr.write('<w:cs/>');
      final run = StringBuffer('<w:r>');
      if (rPr.isNotEmpty) run.write('<w:rPr>$rPr</w:rPr>');
      final t = StringBuffer();
      void flush() {
        if (t.isEmpty) return;
        run.write('<w:t xml:space="preserve">${_xmlEsc(t.toString())}</w:t>');
        t.clear();
      }

      for (var k = i; k < j; k++) {
        final u = p.units[k];
        _checkChar(
          u,
          k + 1 < n ? p.units[k + 1] : 0,
          k > 0 ? p.units[k - 1] : 0,
        );
        if (u == 0x09) {
          flush();
          run.write('<w:tab/>');
        } else {
          t.writeCharCode(u);
        }
      }
      flush();
      run.write('</w:r>');
      if (link != null) {
        // The address goes into XML too: a character it cannot hold
        // would make Word call the whole file corrupted.
        for (var k = 0; k < link.length; k++) {
          _checkChar(
            link.codeUnitAt(k),
            k + 1 < link.length ? link.codeUnitAt(k + 1) : 0,
            k > 0 ? link.codeUnitAt(k - 1) : 0,
          );
        }
        if (link == openLink && openRuns != null) {
          openRuns!.write(run);
        } else {
          closeLink();
          links.add(link);
          openLink = link;
          openRuns = StringBuffer('$run');
        }
      } else {
        closeLink();
        body.write(run);
      }
      i = j;
    }
    closeLink();
    body.write('</w:p>');
  }

  const w =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  const head = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  final document =
      '$head<w:document $w><w:body>$body'
      '<w:sectPr>${_page(look)}</w:sectPr>'
      '</w:body></w:document>';

  final rels = StringBuffer(
    '$head<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '<Relationship Id="rIdN" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
    '<Relationship Id="rIdT" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>',
  );
  for (var k = 0; k < links.length; k++) {
    rels.write(
      '<Relationship Id="rIdL${k + 1}" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" '
      'Target="${_xmlEsc(links[k])}" TargetMode="External"/>',
    );
  }
  rels.write('</Relationships>');

  final files = <String, String>{
    '[Content_Types].xml':
        '$head<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
        '<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        '</Types>',
    '_rels/.rels':
        '$head<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>'
        '</Relationships>',
    'docProps/app.xml':
        '$head<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
        '<Application>Breeze</Application></Properties>',
    'word/document.xml': document,
    'word/_rels/document.xml.rels': rels.toString(),
    'word/styles.xml': _styles(head, w, look),
    // Without settings Word opens the file in Compatibility Mode.
    'word/settings.xml':
        '$head<w:settings $w><w:defaultTabStop w:val="720"/>'
        '<w:characterSpacingControl w:val="doNotCompress"/>'
        '<w:compat><w:compatSetting w:name="compatibilityMode" '
        'w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>'
        '</w:compat></w:settings>',
    'word/numbering.xml': _numbering(head, w, numbered, look),
  };
  final archive = Archive();
  for (final e in files.entries) {
    final data = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// The page: A4 with 2.5 cm margins, or the saved-over document's own.
String _page(DocxLook? look) {
  final size = look?.pageSize;
  final w = size?['w'] ?? 11906, h = size?['h'] ?? 16838;
  final m = {
    'top': 1440,
    'right': 1440,
    'bottom': 1440,
    'left': 1440,
    'header': 708,
    'footer': 708,
    'gutter': 0,
    ...?look?.pageMargins,
  };
  final orient = look?.landscape == true ? ' w:orient="landscape"' : '';
  return '<w:pgSz w:w="$w" w:h="$h"$orient/>'
      '<w:pgMar w:top="${m['top']}" w:right="${m['right']}" '
      'w:bottom="${m['bottom']}" w:left="${m['left']}" '
      'w:header="${m['header']}" w:footer="${m['footer']}" '
      'w:gutter="${m['gutter']}"/>';
}

/// Paragraph spacing from a DocxLook key ("after=160;line=259;...;
/// contextual"), as w:spacing (+ w:contextualSpacing). Only numbers and
/// Word's own words go into the XML.
String _spacingXml(String key) {
  final attrs = StringBuffer();
  var contextual = false;
  for (final part in key.split(';')) {
    if (part == 'contextual') {
      contextual = true;
      continue;
    }
    final eq = part.indexOf('=');
    if (eq < 1) continue;
    final k = part.substring(0, eq), v = part.substring(eq + 1);
    final ok = switch (k) {
      'before' || 'after' || 'line' => int.tryParse(v) != null,
      'lineRule' => const {'auto', 'exact', 'atLeast'}.contains(v),
      'beforeAutospacing' || 'afterAutospacing' => const {
        '0',
        '1',
        'true',
        'false',
        'on',
        'off',
      }.contains(v),
      _ => false,
    };
    if (ok) attrs.write(' w:$k="$v"');
  }
  return '${attrs.isEmpty ? '' : '<w:spacing$attrs/>'}'
      '${contextual ? '<w:contextualSpacing/>' : ''}';
}

String _styles(String head, String w, DocxLook? look) {
  // The body font and size: the document's own when saving over one.
  final face = _xmlEsc(look?.font ?? 'Calibri');
  final faceCs = _xmlEsc(look?.fontCs ?? look?.font ?? 'Calibri');
  final size = look?.size ?? 22;
  final sizeCs = look?.sizeCs ?? size;
  // A heading in Breeze's look, or the saved-over document's own: its
  // font, size, colour, boldness and spacing.
  String heading(int n, int size, String colour) {
    final own = look?.headings[n - 1]?.split('|');
    final ownFace = own != null && own.length == 4 ? own[0] : '';
    final ownSize = own != null && own.length == 4
        ? int.tryParse(own[1])
        : null;
    final ownColour = own != null && own.length == 4 ? own[2] : null;
    final bold = own == null || own.length != 4 || own[3] == 'true';
    final hue = ownColour ?? colour;
    final sz = ownSize ?? size;
    final spacing = _spacingXml(
      look?.headingSpacing[n - 1] ?? 'before=${n == 1 ? 360 : 160};after=80',
    );
    return '<w:style w:type="paragraph" w:styleId="Heading$n">'
        '<w:name w:val="heading $n"/><w:basedOn w:val="Normal"/>'
        '<w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:keepLines/>$spacing'
        '<w:outlineLvl w:val="${n - 1}"/></w:pPr><w:rPr>'
        '${ownFace.isEmpty ? '' : '<w:rFonts w:ascii="${_xmlEsc(ownFace)}" w:hAnsi="${_xmlEsc(ownFace)}"/>'}'
        '${bold ? '<w:b/><w:bCs/>' : ''}'
        '${RegExp(r'^[0-9A-F]{6}$').hasMatch(hue) ? '<w:color w:val="$hue"/>' : ''}'
        '<w:sz w:val="$sz"/><w:szCs w:val="$sz"/></w:rPr></w:style>';
  }

  return '$head<w:styles $w>'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="$face" w:hAnsi="$face" w:eastAsia="$face" w:cs="$faceCs"/>'
      '${look?.kern != null && look!.kern! > 0 && look.kern! < 400 ? '<w:kern w:val="${look.kern}"/>' : ''}'
      '<w:sz w:val="$size"/><w:szCs w:val="$sizeCs"/><w:lang w:val="en-US"/>'
      '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>'
      '${_spacingXml(look?.bodySpacing ?? 'after=120;line=276;lineRule=auto')}'
      '</w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/><w:qFormat/></w:style>'
      '${heading(1, 36, "1F3864")}${heading(2, 30, "1F3864")}${heading(3, 26, "1F3864")}'
      '<w:style w:type="paragraph" w:styleId="ListParagraph">'
      '<w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>'
      '<w:uiPriority w:val="34"/><w:qFormat/>'
      '<w:pPr>${_spacingXml(look?.listSpacing ?? 'after=40;contextual')}'
      '</w:pPr></w:style>'
      '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
      '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/>'
      '<w:semiHidden/></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink">'
      '<w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/>'
      '<w:uiPriority w:val="99"/><w:unhideWhenUsed/>'
      '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
      '</w:styles>';
}

String _numbering(
  String head,
  String w,
  List<List<int>> numbered, [
  DocxLook? look,
]) {
  final b = StringBuffer('$head<w:numbering $w>');
  // Bullets: one list for every bulleted line.
  const glyphs = [0x2022, 0x25E6, 0x25AA];
  b.write(
    '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>',
  );
  for (var l = 0; l < 9; l++) {
    // The saved-over document's own bullet for this level (Word's Symbol
    // dot is taller than a plain one, so lines would move).
    var glyph = String.fromCharCode(glyphs[l % 3]);
    var font = '';
    final own = look?.bullets[l];
    final bar = own?.lastIndexOf('|') ?? -1;
    if (own != null && bar > 0) {
      final g = own.substring(0, bar).runes.toList();
      final f = own.substring(bar + 1);
      if (g.length == 1 &&
          _bulletChars.contains(g.single) &&
          RegExp(r'^[A-Za-z0-9 ]{0,40}$').hasMatch(f)) {
        glyph = String.fromCharCode(g.single);
        font = f;
      }
    }
    b.write(
      '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
      '<w:lvlText w:val="${_xmlEsc(glyph)}"/>'
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="${720 * (l + 1)}" '
      'w:hanging="360"/></w:pPr>'
      '${font.isEmpty ? '' : '<w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:hint="default"/></w:rPr>'}'
      '</w:lvl>',
    );
  }
  b.write('</w:abstractNum>');
  for (var k = 0; k < numbered.length; k++) {
    b.write(
      '<w:abstractNum w:abstractNumId="${k + 1}">'
      '<w:multiLevelType w:val="hybridMultilevel"/>',
    );
    for (var l = 0; l < 9; l++) {
      b.write(
        '<w:lvl w:ilvl="$l"><w:start w:val="${numbered[k][l]}"/>'
        '<w:numFmt w:val="decimal"/><w:lvlText w:val="%${l + 1}."/>'
        '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="${720 * (l + 1)}" '
        'w:hanging="360"/></w:pPr></w:lvl>',
      );
    }
    b.write('</w:abstractNum>');
  }
  b.write('<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>');
  for (var k = 0; k < numbered.length; k++) {
    b.write(
      '<w:num w:numId="${k + 2}"><w:abstractNumId w:val="${k + 1}"/></w:num>',
    );
  }
  b.write('</w:numbering>');
  return b.toString();
}
