import 'package:flutter/gestures.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../logic/code_highlight.dart';
import '../logic/markdown_lite.dart';
import 'glass_surface.dart';
import 'kit.dart';
import 'scale.dart';
import 'motion.dart';

/// Styling of one run, shared by the editor, read mode and (in spirit) PDF.
TextStyle mdTextStyle(TextStyle base, int f, Pal p, {required bool editing}) {
  var st = base;
  final size = base.fontSize ?? 16;
  if (f & Md.heading != 0) {
    final k = f & Md.h1 != 0 ? 1.6 : (f & Md.h2 != 0 ? 1.35 : 1.15);
    st = st.copyWith(
      fontSize: size * k,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
  }
  if (f & Md.bold != 0) st = st.copyWith(fontWeight: FontWeight.w700);
  if (f & Md.italic != 0) st = st.copyWith(fontStyle: FontStyle.italic);
  final decos = <TextDecoration>[
    if (f & Md.strike != 0) TextDecoration.lineThrough,
    // While editing the field draws it (UnderlinedField).
    if (f & (Md.link | Md.underline) != 0 && !editing) TextDecoration.underline,
  ];
  if (decos.isNotEmpty) {
    st = st.copyWith(
      decoration: TextDecoration.combine(decos),
      decorationColor: st.color,
    );
  }
  if (f & Md.link != 0) {
    st = st.copyWith(color: p.accent, decorationColor: p.accent);
  }
  if (f & Md.listMarker != 0) {
    st = st.copyWith(color: p.accent, fontWeight: FontWeight.w600);
  }
  if (f & Md.marker != 0 && editing) {
    // The **, <u>, # stay in the text but are not shown: editing looks like
    // reading, and formatting is changed with the bar. Nearly no width, so
    // the cursor still steps over them (HiddenMarkerBackspace keeps a
    // backspace from silently eating one).
    st = st.copyWith(
      color: const Color(0x00000000),
      fontSize: 0.01,
      letterSpacing: 0,
      wordSpacing: 0,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
    );
  }
  return st;
}

/// [t] in [st], with characters the phone marks as emoji (U+FE0F, as in
/// the sun or heart emoji) drawn in colour. Inter has its own plain sun and
/// heart and would win over the phone's colour emoji; a family the app does
/// not bundle sends those characters to the phone's fonts, which honour the
/// marker.
List<TextSpan> emojiAwareSpans(String t, TextStyle st) {
  if (!t.contains('\u{FE0F}')) return [TextSpan(text: t, style: st)];
  final out = <TextSpan>[];
  final run = StringBuffer();
  final emoji = st.copyWith(
    fontFamily: 'sans-serif',
    fontFamilyFallback: const [],
  );
  for (final c in t.characters) {
    if (c.contains('\u{FE0F}')) {
      if (run.isNotEmpty) {
        out.add(TextSpan(text: run.toString(), style: st));
        run.clear();
      }
      out.add(TextSpan(text: c, style: emoji));
    } else {
      run.write(c);
    }
  }
  if (run.isNotEmpty) out.add(TextSpan(text: run.toString(), style: st));
  return out;
}

/// The note's text controller. With [formatting] on, the text is drawn
/// formatted as it is typed; with a [codeLanguage], in syntax colours.
class FormatController extends TextEditingController {
  bool formatting = false;

  /// A Word or RTF note: a backslash escapes punctuation (see parseMd).
  bool escapes = false;
  String? codeLanguage;
  Pal? pal;

  FormatController() {
    addListener(_tidy);
  }

  /// B (or I, U, S) tapped with nothing selected: the formatting the next
  /// letters typed at [pendingAt] get. Nothing goes into the text until a
  /// letter is typed (ContinueFormatting adds the markers around it), so
  /// nothing can be left behind, saved or printed.
  int pendingKinds = 0;
  int pendingAt = -1;

  /// Where typing must NOT carry on the formatting before it (B tapped at
  /// the end of bold words: what comes next is plain).
  int? stopAt;

  void setPending(int at, int kinds) {
    pendingKinds = kinds;
    pendingAt = at;
  }

  void clearPending() {
    pendingKinds = 0;
    pendingAt = -1;
  }

  /// Redraws what shows the bar's state, with the text unchanged.
  void touch() => notifyListeners();

  void _tidy() {
    final s = selection;
    final at = s.isValid && s.isCollapsed ? s.baseOffset : -2;
    if (stopAt != null && stopAt != at) stopAt = null;
    // The cursor moved on: what was tapped for it no longer applies.
    if (pendingAt >= 0 && pendingAt != at) clearPending();
  }

  /// Code longer than this is drawn plain (colouring it takes seconds even
  /// in the background).
  static const maxCode = 300000;

  // Code colours come from a background worker (CodeColourer), never from
  // the keystroke itself: colouring 1,000 lines of C takes up to 2 s. While
  // typing, the last colours are SHIFTED to fit the new text at once (only
  // the changed stretch is plain), and the worker re-colours the whole file
  // a moment after typing pauses.

  /// The last colouring the worker returned, and the text it was for.
  List<(String, String?)>? _done;
  String? _doneText;
  String? _doneLang;

  /// The colours fitted to the CURRENT text.
  List<(String, String?)>? _fitted;
  String? _fittedText;

  Timer? _colourTimer;
  String? _asked;
  var _gen = 0;

  /// The code's colour pieces for the current text, or null until the first
  /// colouring arrives (the text is drawn plain until then).
  List<(String, String?)>? codePieces() {
    final lang = codeLanguage;
    if (lang == null || text.length > maxCode) return null;
    if (_doneLang != lang) {
      _done = null;
      _doneText = null;
      _fitted = null;
      // Ask again for the new language, even with the same text.
      if (_askedLang != lang) _asked = null;
    }
    if (!identical(_doneText, text) && _doneText != text) _askForColours(lang);
    final done = _done, doneText = _doneText;
    if (done == null || doneText == null) return null;
    if (doneText == text) return done;
    if (identical(_fittedText, text)) return _fitted;
    _fitted = _shiftPieces(done, doneText, text);
    _fittedText = text;
    return _fitted;
  }

  String? _askedLang;

  void _askForColours(String lang) {
    if (_asked == text && _askedLang == lang) return;
    _asked = text;
    _askedLang = lang;
    _colourTimer?.cancel();
    // At once for a file just opened; after a pause while typing.
    _colourTimer = Timer(
      Duration(milliseconds: _done == null ? 0 : 350),
      () async {
        final want = text;
        final gen = ++_gen;
        final got = await CodeColourer.instance.colour(
          want,
          lang,
          latestOnly: true,
        );
        if (gen != _gen || got == null || codeLanguage != lang) return;
        _done = got;
        _doneText = want;
        _doneLang = lang;
        _fitted = null;
        _fittedText = null;
        // Redraw with the fresh colours.
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _colourTimer?.cancel();
    _gen++;
    super.dispose();
  }

  /// Past this the text is drawn plain: styling re-reads it on every key.
  static const maxStyled = 120000;

  MdDoc? _doc;
  bool _docEscapes = false;
  MdDoc get doc {
    final d = _doc;
    if (d != null && identical(d.text, text) && _docEscapes == escapes) {
      return d;
    }
    _docEscapes = escapes;
    return _doc = parseMd(text, escapes: escapes);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final p = pal;
    if (codeLanguage != null && p != null && style != null) {
      final pieces = codePieces();
      if (pieces != null) {
        final sel = selection;
        return codeSpan(
          pieces,
          style,
          p.dark,
          around: sel.isValid ? sel.extentOffset : 0,
        );
      }
    }
    if (!formatting || p == null || style == null || text.length > maxStyled) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final comp = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final children = <TextSpan>[];
    var bulletAt = -1;
    void add(int a, int b, TextStyle st) {
      if (a >= b) return;
      var t = text.substring(a, b);
      // A bullet's "-" is drawn as the • reading shows: one character for
      // one, so the text and every cursor position stay as they are.
      if (bulletAt >= a && bulletAt < b) {
        final i = bulletAt - a;
        t = '${t.substring(0, i)}•${t.substring(i + 1)}';
      }
      children.addAll(emojiAwareSpans(t, st));
    }

    for (final r in doc.runs) {
      bulletAt = -1;
      if (r.flags & Md.listMarker != 0) {
        final m = _bulletMark.firstMatch(text.substring(r.start, r.end));
        if (m != null) bulletAt = r.start + m[1]!.length;
      }
      final st = mdTextStyle(style, r.flags, p, editing: true);
      if (comp.isCollapsed || r.end <= comp.start || r.start >= comp.end) {
        add(r.start, r.end, st);
        continue;
      }
      // The word being typed keeps the keyboard's underline.
      final under = st.copyWith(
        decoration: TextDecoration.combine([
          if (st.decoration != null) st.decoration!,
          TextDecoration.underline,
        ]),
      );
      final a = r.start < comp.start ? comp.start : r.start;
      final b = r.end > comp.end ? comp.end : r.end;
      add(r.start, a, st);
      add(a, b, under);
      add(b, r.end, st);
    }
    return TextSpan(style: style, children: children);
  }
}

/// [pieces] coloured for [from], fitted to [to]: the unchanged start and
/// end keep their colours, the changed middle is plain until re-coloured.
/// The result spells [to] exactly (the text field needs that).
List<(String, String?)> _shiftPieces(
  List<(String, String?)> pieces,
  String from,
  String to,
) {
  final maxCommon = from.length < to.length ? from.length : to.length;
  var pre = 0;
  while (pre < maxCommon && from.codeUnitAt(pre) == to.codeUnitAt(pre)) {
    pre++;
  }
  var suf = 0;
  while (suf < maxCommon - pre &&
      from.codeUnitAt(from.length - 1 - suf) ==
          to.codeUnitAt(to.length - 1 - suf)) {
    suf++;
  }
  final out = <(String, String?)>[];
  var at = 0;
  final tailFrom = from.length - suf;
  final tail = <(String, String?)>[];
  for (final (t, scope) in pieces) {
    final a = at, b = at + t.length;
    at = b;
    if (a < pre) out.add((t.substring(0, (b < pre ? b : pre) - a), scope));
    if (b > tailFrom) {
      final s = a > tailFrom ? a : tailFrom;
      tail.add((t.substring(s - a), scope));
    }
  }
  final middle = to.substring(pre, to.length - suf);
  if (middle.isNotEmpty) out.add((middle, null));
  out.addAll(tail);
  return out;
}

/// A bullet line's marker: its indent, then the -, * or + drawn as •.
final _bulletMark = RegExp(r'^(\s*)[-*+](?=\s)');

/// Coloured code pieces as one span over [base].
/// Coloured runs a text field can lay out on every keystroke without lag
/// (measured: 16,800 runs for 3,600 lines of C took 0.4 s per key on a PC,
/// several seconds on a phone).
const _maxEditRuns = 2500;

/// How far either side of the cursor a long file stays coloured while
/// editing: several screens. Further away is plain until the cursor goes
/// there. Reading shows the whole file coloured.
const _editWindow = 3000;

/// [pieces] as styled text. Neighbours of one colour (and the spaces
/// between them) are one run. With [around] (editing) a file with more
/// runs than a text field lays out quickly is coloured only within
/// [_editWindow] of that offset.
TextSpan codeSpan(
  List<(String, String?)> pieces,
  TextStyle base,
  bool dark, {
  int? around,
}) {
  var from = 0, to = 1 << 62;
  if (around != null && pieces.length > _maxEditRuns) {
    from = around - _editWindow;
    to = around + _editWindow;
  }
  final out = <TextSpan>[];
  final buf = StringBuffer();
  TextStyle? cur;
  var started = false;
  var at = 0;
  for (final (t, scope) in pieces) {
    final inside = at + t.length > from && at < to;
    at += t.length;
    final st = inside ? codeStyle(scope, dark) : null;
    if (started && (st == cur || t.trim().isEmpty)) {
      buf.write(t);
      continue;
    }
    if (started) out.add(TextSpan(text: buf.toString(), style: cur));
    buf
      ..clear()
      ..write(t);
    cur = st;
    started = true;
  }
  if (started) out.add(TextSpan(text: buf.toString(), style: cur));
  return TextSpan(style: base, children: out);
}

/// Underlined text [start, end) of a read span, drawn by [UnderlinedText].
typedef Underline = ({int start, int end, double size, Color colour});

/// The note formatted for reading: syntax hidden, bullets drawn as •.
/// With [onLink], a link opens when tapped; its recognizers are added to
/// [recognizers] for the caller to dispose. With [underlines], underlined
/// text (and links) is listed there instead of underlined by the font, for
/// [UnderlinedText] to draw.
TextSpan mdReadSpan(
  MdDoc doc,
  TextStyle base,
  Pal p, {
  void Function(String url)? onLink,
  List<GestureRecognizer>? recognizers,
  List<Underline>? underlines,
}) {
  final children = <InlineSpan>[];
  var at = 0;
  for (final r in doc.runs) {
    if (r.flags & Md.marker != 0) continue;
    var t = doc.text.substring(r.start, r.end);
    if (r.flags & Md.listMarker != 0) {
      t = t.replaceFirst(RegExp(r'[-*+](?= $)'), '•');
    }
    var style = mdTextStyle(base, r.flags, p, editing: false);
    if (underlines != null && r.flags & (Md.underline | Md.link) != 0) {
      underlines.add((
        start: at,
        end: at + t.length,
        size: style.fontSize ?? 16,
        colour: style.decorationColor ?? style.color ?? p.ink,
      ));
      style = style.copyWith(
        decoration: r.flags & Md.strike != 0
            ? TextDecoration.lineThrough
            : TextDecoration.none,
      );
    }
    at += t.length;
    final url = r.flags & Md.link != 0 && onLink != null
        ? mdLinkAt(doc, r.start)
        : null;
    if (url != null) {
      final tap = TapGestureRecognizer()..onTap = () => onLink!(url);
      recognizers?.add(tap);
      children.add(TextSpan(text: t, style: style, recognizer: tap));
    } else {
      children.addAll(emojiAwareSpans(t, style));
    }
  }
  return TextSpan(style: base, children: children);
}

/// Keeps a list going: Enter after a list item starts the next one (the
/// number counts up); Enter on an empty item ends the list.
/// Backspace with formatting hidden (see mdTextStyle): over a hidden **
/// or <u> it deletes the letter before it, as the user sees it; at the
/// start of a heading it takes the heading off; a pair left with nothing in
/// it goes too (or it would show as **). If the cursor was in that pair,
/// what is typed next still gets its formatting, as in any editor. Without
/// this one press could silently break a pair and show the rest raw.
class HiddenMarkerBackspace extends TextInputFormatter {
  HiddenMarkerBackspace(this.c);
  final FormatController c;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue nw) {
    if (!c.formatting ||
        c.codeLanguage != null ||
        old.text.length > FormatController.maxStyled) {
      return nw;
    }
    final os = old.selection, ns = nw.selection;
    if (!os.isValid || !os.isCollapsed || !ns.isCollapsed) return nw;
    final c0 = ns.baseOffset, end = os.baseOffset;
    final n = old.text.length - nw.text.length;
    // Only a backspace: [c0, end) gone from just before the old cursor.
    if (n <= 0 || end - c0 != n) return nw;
    final t = old.text;
    if (t.substring(0, c0) != nw.text.substring(0, c0) ||
        t.substring(end) != nw.text.substring(c0)) {
      return nw;
    }
    final doc = parseMd(t, escapes: c.escapes);
    final runs = doc.runs;
    bool hidden(int i) {
      var lo = 0, hi = runs.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (runs[mid].end <= i) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo < runs.length &&
          runs[lo].start <= i &&
          runs[lo].flags & Md.marker != 0;
    }

    int letterBefore(int i) {
      while (i >= 0 && hidden(i)) {
        i--;
      }
      return i;
    }

    // An escaped character deleted: its backslash goes with it, or it
    // would show (or escape the next character).
    if (n == 1 && end >= 2 && hidden(end - 2)) {
      final r = runs.firstWhere((r) => r.start <= end - 2 && end - 2 < r.end);
      if (r.flags & Md.escape != 0 && r.end == end - 1) {
        return TextEditingValue(
          text: t.replaceRange(end - 2, end, ''),
          selection: TextSelection.collapsed(offset: end - 2),
        );
      }
    }
    final gone = <int>{};
    if (n == 1 && hidden(end - 1)) {
      final line = doc.lineAt(end - 1);
      if (end - 1 < line.prefixEnd && line.kind.name.startsWith('h')) {
        // "# " before a heading: the heading goes, the words stay.
        return TextEditingValue(
          text: t.replaceRange(line.start, line.prefixEnd, ''),
          selection: TextSelection.collapsed(offset: line.start),
        );
      }
      final i = letterBefore(end - 1);
      if (i < 0) return old;
      final len = t.substring(0, i + 1).characters.last.length;
      for (var k = i + 1 - len; k <= i; k++) {
        gone.add(k);
      }
    } else {
      // Word delete and the like: the letters go, the markers stay.
      for (var k = c0; k < end; k++) {
        if (!hidden(k)) gone.add(k);
      }
      if (gone.isEmpty) return old;
    }
    // Pairs left empty go too; inner ones first, so an outer pair holding
    // only an emptied inner one goes as well.
    var carry = 0;
    var emptied = false;
    var changed = true;
    final done = <MdRegion>{};
    while (changed) {
      changed = false;
      for (final r in doc.regions) {
        if (done.contains(r) || r.closeStart <= r.openEnd) continue;
        var empty = true;
        for (var k = r.openEnd; k < r.closeStart; k++) {
          if (!gone.contains(k)) {
            empty = false;
            break;
          }
        }
        if (!empty) continue;
        done.add(r);
        changed = true;
        emptied = true;
        // The cursor was in it: what is typed next keeps its formatting.
        if (r.openEnd <= end && end <= r.closeStart) carry |= r.kind;
        for (var k = r.openStart; k < r.openEnd; k++) {
          gone.add(k);
        }
        for (var k = r.closeStart; k < r.closeEnd; k++) {
          gone.add(k);
        }
      }
    }
    if (!emptied && gone.length == n && gone.every((k) => k >= c0 && k < end)) {
      return nw;
    }
    final sb = StringBuffer();
    var before = 0;
    for (var k = 0; k < t.length; k++) {
      if (gone.contains(k)) {
        if (k < end) before++;
      } else {
        sb.writeCharCode(t.codeUnitAt(k));
      }
    }
    final caret = end - before;
    carry &= ~Md.link;
    if (carry != 0) c.setPending(caret, carry);
    return TextEditingValue(
      text: sb.toString(),
      selection: TextSelection.collapsed(offset: caret),
    );
  }
}

/// Kinds the text at [p] is inside of (links aside).
int _insideKinds(MdDoc doc, int p) {
  var k = 0;
  for (final r in doc.regions) {
    if (r.openEnd <= p && p <= r.closeStart) k |= r.kind;
  }
  return k & ~Md.link;
}

/// Where typing at [p] goes: inside formatting that ends right there
/// (typing after bold words carries the bold on).
int _walkInside(MdDoc doc, int p) {
  while (true) {
    MdRegion? hit;
    for (final r in doc.regions) {
      if (r.closeEnd == p && r.kind & Md.link == 0) {
        hit = r;
        break;
      }
    }
    if (hit == null) return p;
    p = hit.closeStart;
  }
}

/// Kinds that typing at [p] carries on, from formatting ending there.
int _carriedKinds(MdDoc doc, int p) {
  final q = _walkInside(doc, p);
  return q == p ? 0 : _insideKinds(doc, q);
}

/// What typing at [at] in [c] comes out as, with nothing tapped.
int _typedKinds(FormatController c, MdDoc doc, int at) =>
    _insideKinds(doc, at) | (c.stopAt == at ? 0 : _carriedKinds(doc, at));

/// The markers for [kinds] around new text; [ital] is * or _ for italic.
(String, String) _wrapFor(int kinds, String ital) {
  final b = kinds & Md.bold != 0, i = kinds & Md.italic != 0;
  var o = '', cl = '';
  if (b && i) {
    o = ital == '*' ? '***' : '**_';
    cl = ital == '*' ? '***' : '_**';
  } else if (b) {
    o = cl = '**';
  } else if (i) {
    o = cl = ital;
  }
  if (kinds & Md.strike != 0) {
    o = '$o~~';
    cl = '~~$cl';
  }
  if (kinds & Md.underline != 0) {
    o = '$o<u>';
    cl = '</u>$cl';
  }
  return (o, cl);
}

/// Whether the letter at [pos] of [text] reads with all of [kinds].
bool _readsAs(String text, int pos, int kinds, {bool escapes = false}) {
  final ls = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
  var le = text.indexOf('\n', pos);
  if (le < 0) le = text.length;
  final d = parseMd(text.substring(ls, le), escapes: escapes);
  for (final r in d.runs) {
    if (r.start <= pos - ls && pos - ls < r.end) {
      return r.flags & Md.marker == 0 && r.flags & kinds == kinds;
    }
  }
  return false;
}

/// Typing formatted, as in any editor: right after bold words the letters
/// carry the bold on (they go inside the hidden closing markers), and after
/// B was tapped with nothing selected they come out bold (the markers are
/// put around them now). Not after a link, and never onto a new line.
class ContinueFormatting extends TextInputFormatter {
  ContinueFormatting(this.c);
  final FormatController c;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue nw) {
    if (!c.formatting ||
        c.codeLanguage != null ||
        old.text.length > FormatController.maxStyled) {
      return nw;
    }
    final os = old.selection, ns = nw.selection;
    if (!os.isValid || !os.isCollapsed || !ns.isCollapsed) return nw;
    final at = os.baseOffset;
    final n = nw.text.length - old.text.length;
    if (n <= 0 || ns.baseOffset != at + n) return nw;
    final t = old.text;
    if (nw.text.substring(0, at) != t.substring(0, at) ||
        nw.text.substring(at + n) != t.substring(at)) {
      return nw;
    }
    final ins = nw.text.substring(at, at + n);
    if (ins.contains('\n')) {
      c.clearPending();
      return nw;
    }
    final doc = c.text == t ? c.doc : parseMd(t, escapes: c.escapes);
    final p = c.stopAt == at ? at : _walkInside(doc, at);
    if (c.pendingAt == at) {
      final want = c.pendingKinds;
      final add = want & ~_insideKinds(doc, p) & ~Md.link;
      c.clearPending();
      if (add != 0) {
        var lead = 0;
        while (lead < n && ins.codeUnitAt(lead) <= 0x20) {
          lead++;
        }
        final ws = ins.substring(0, lead), rest = ins.substring(lead);
        if (rest.isEmpty) {
          // Spaces first (** x** is not bold): they go in as they are,
          // and the formatting waits on after them.
          c.setPending(p + lead, want);
          return TextEditingValue(
            text: t.replaceRange(p, p, ws),
            selection: TextSelection.collapsed(offset: p + lead),
          );
        }
        for (final ital in const ['*', '_']) {
          final (o, cl) = _wrapFor(add, ital);
          final text = t.replaceRange(p, p, '$ws$o$rest$cl');
          final s0 = p + lead + o.length;
          if (_readsAs(text, s0, add, escapes: c.escapes)) {
            final comp = nw.composing;
            return TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: s0 + rest.length),
              composing: comp.isValid && comp.start >= at
                  ? TextRange(start: s0, end: s0 + rest.length)
                  : TextRange.empty,
            );
          }
        }
        // Markers that would not read right next to what is there: the
        // letters go in plain rather than with stray stars.
      }
    }
    if (p == at) return nw;
    final shift = p - at;
    final comp = nw.composing;
    return TextEditingValue(
      text: t.replaceRange(p, p, ins),
      selection: TextSelection.collapsed(offset: p + n),
      composing: comp.isValid && comp.start >= at
          ? TextRange(start: comp.start + shift, end: comp.end + shift)
          : TextRange.empty,
    );
  }
}

class ListContinuation extends TextInputFormatter {
  ListContinuation(this.enabled);
  final bool Function() enabled;

  static final _item = RegExp(r'^( *)([-*+]|\d{1,4}[.)]) (.*)$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue nw) {
    if (!enabled()) return nw;
    final sel = nw.selection;
    if (!sel.isCollapsed || nw.text.length != old.text.length + 1) return nw;
    final c = sel.baseOffset;
    if (c < 1 || nw.text.codeUnitAt(c - 1) != 0x0A) return nw;
    if (old.text != nw.text.substring(0, c - 1) + nw.text.substring(c)) {
      return nw;
    }
    final lineStart = c - 2 < 0 ? 0 : nw.text.lastIndexOf('\n', c - 2) + 1;
    final m = _item.firstMatch(nw.text.substring(lineStart, c - 1));
    if (m == null) return nw;
    var lineEnd = nw.text.indexOf('\n', c);
    if (lineEnd < 0) lineEnd = nw.text.length;
    // Enter between the marker and the item's text splits the item; only a
    // truly empty item (nothing after the cursor either) ends the list.
    if (m[3]!.trim().isEmpty && nw.text.substring(c, lineEnd).trim().isEmpty) {
      // An empty item: the list ends here, on a plain empty line.
      final t = nw.text.substring(0, lineStart) + nw.text.substring(c);
      return TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    var marker = m[2]!;
    final num = RegExp(r'^(\d+)([.)])$').firstMatch(marker);
    if (num != null) marker = '${int.parse(num[1]!) + 1}${num[2]}';
    final ins = '${m[1]}$marker ';
    return TextEditingValue(
      text: nw.text.substring(0, c) + ins + nw.text.substring(c),
      selection: TextSelection.collapsed(offset: c + ins.length),
    );
  }
}

// -- toolbar actions ----------------------------------------------------

/// What the toolbar shows as on, for the cursor or selection.
class FormatState {
  const FormatState(this.kind, this.inline);
  final MdLineKind kind;
  final int inline; // Md.bold | Md.italic | Md.strike | Md.underline | Md.link
}

FormatState formatStateOf(FormatController c) {
  final sel = c.selection;
  if (!sel.isValid || c.text.length > FormatController.maxStyled) {
    return const FormatState(MdLineKind.plain, 0);
  }
  final doc = c.doc;
  var inline = 0;
  if (doc.regionAround(Md.link, sel.start, sel.end) != null) inline |= Md.link;
  if (sel.isCollapsed) {
    final at = sel.baseOffset;
    // What the next letters typed here will be (a tap waiting, or bold
    // carried on from the words just before).
    inline |= c.pendingAt == at ? c.pendingKinds : _typedKinds(c, doc, at);
  } else {
    for (final k in const [Md.bold, Md.italic, Md.strike, Md.underline]) {
      if (doc.regionAround(k, sel.start, sel.end) != null) inline |= k;
    }
  }
  return FormatState(doc.lineAt(sel.start).kind, inline);
}

/// Bold, italic, strikethrough or underline on or off for the selection (or,
/// with just a cursor, for the formatting around it, else a pair to type
/// into).
TextEditingValue toggleInline(TextEditingValue v, MdDoc doc, int kind) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  final t = v.text;
  final region = doc.regionAround(kind, sel.start, sel.end);
  if (region != null) {
    // Off: drop this kind's markers, keeping any other (*** -> * or **).
    final keep = region.kind & ~kind;
    final (ko, kc) = _markersFor(keep);
    final openLen = region.openEnd - region.openStart;
    final shift = openLen - ko.length;
    final text = t
        .replaceRange(region.closeStart, region.closeEnd, kc)
        .replaceRange(region.openStart, region.openEnd, ko);
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: (sel.start - shift).clamp(0, text.length),
        extentOffset: (sel.end - shift).clamp(0, text.length),
      ),
    );
  }
  final (mo, mc) = _markersFor(kind);
  if (sel.isCollapsed) {
    final c = sel.start;
    // A second tap on an empty pair takes it away again.
    if (c >= mo.length &&
        c + mc.length <= t.length &&
        t.substring(c - mo.length, c) == mo &&
        t.substring(c, c + mc.length) == mc &&
        // Not one half of another kind's pair (* inside a bold ****).
        (c - mo.length == 0 || t[c - mo.length - 1] != mo[0]) &&
        (c + mc.length == t.length || t[c + mc.length] != mc[mc.length - 1])) {
      final text = t.replaceRange(c - mo.length, c + mc.length, '');
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: c - mo.length),
      );
    }
    final text = t.replaceRange(c, c, '$mo$mc');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: c + mo.length),
    );
  }
  // Line by line: a line's bullet, number or # stays outside the markers
  // (inside them the line would stop being a list or heading), and so do
  // spaces at either end (Markdown ignores ** next to a space).
  final pieces = <(int, int)>[];
  for (final l in doc.lines) {
    if (l.end < sel.start || l.start > sel.end) continue;
    var a = sel.start > l.prefixEnd ? sel.start : l.prefixEnd;
    var b = sel.end < l.end ? sel.end : l.end;
    while (a < b && t[a].trim().isEmpty) {
      a++;
    }
    while (b > a && t[b - 1].trim().isEmpty) {
      b--;
    }
    if (a < b) pieces.add((a, b));
  }
  if (pieces.isEmpty) return v;
  // Every line already this kind (a second tap): take it off each line.
  final on = <int, MdRegion>{};
  for (final (a, b) in pieces) {
    final s = t.substring(a, b);
    final ia = s.startsWith(mo) ? a + mo.length : a;
    final ib = s.endsWith(mc) && b - mc.length >= ia ? b - mc.length : b;
    final r = doc.regionAround(kind, ia, ib) ?? _exactRegion(doc, kind, a, b);
    if (r == null) {
      on.clear();
      break;
    }
    on[r.openStart] = r;
  }
  if (on.isNotEmpty) return _removeRegions(v, on.values, kind);
  // Wrap each line that is not on yet; any of this kind already inside it
  // is dropped first, so nothing is wrapped twice (**x** never ****x****).
  var text = t;
  final grow = List<int>.filled(pieces.length, 0);
  final starts = pieces.map((x) => x.$1).toList();
  final ends = pieces.map((x) => x.$2).toList();
  final wrapped = List<bool>.filled(pieces.length, false);
  var inner1 = (0, 0);
  for (var i = pieces.length - 1; i >= 0; i--) {
    var (a, b) = pieces[i];
    // Half in bold already ("**ab** cd", "b cd" selected): the whole of it
    // is taken in, never "**a**b** cd**".
    for (final r in doc.regions) {
      if (r.kind & kind != 0 && r.openStart < b && r.closeEnd > a) {
        if (r.openStart < a) a = r.openStart;
        if (r.closeEnd > b) b = r.closeEnd;
      }
    }
    starts[i] = a;
    ends[i] = b;
    final s = t.substring(a, b);
    final ia = s.startsWith(mo) ? a + mo.length : a;
    final ib = s.endsWith(mc) && b - mc.length >= ia ? b - mc.length : b;
    if ((doc.regionAround(kind, ia, ib) ?? _exactRegion(doc, kind, a, b)) !=
        null) {
      continue;
    }
    final inside =
        doc.regions
            .where(
              (r) => r.kind & kind != 0 && r.openStart >= a && r.closeEnd <= b,
            )
            .toList()
          ..sort((x, y) => x.openStart.compareTo(y.openStart));
    var body = s;
    for (final r in inside.reversed) {
      final (ko, kc) = _markersFor(r.kind & ~kind);
      body = body
          .replaceRange(r.closeStart - a, r.closeEnd - a, kc)
          .replaceRange(r.openStart - a, r.openEnd - a, ko);
    }
    text = text.replaceRange(a, b, '$mo$body$mc');
    grow[i] = mo.length + body.length + mc.length - (b - a);
    wrapped[i] = true;
    inner1 = (a + mo.length, a + mo.length + body.length);
  }
  if (text == t) return v;
  // One line: select its words INSIDE the markers, so the bar shows it on
  // and a second tap takes it off. Several: select them all.
  if (pieces.length == 1) {
    return TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: inner1.$1, extentOffset: inner1.$2),
    );
  }
  final added = grow.fold<int>(0, (x, y) => x + y);
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      // Inside the first line's markers, so the bar shows it on.
      baseOffset: starts.first + (wrapped.first ? mo.length : 0),
      extentOffset: ends.last + added - (wrapped.last ? mc.length : 0),
    ),
  );
}

/// Bold (or another kind) from the bar, for [c]. With a selection it is
/// [toggleInline]. With just a cursor nothing is written yet: the next
/// letters typed there get it (or lose it), as in any editor. At the end of
/// bold words (past any hidden closing markers, as in **<u>both|</u>**) B
/// stops the bold for what comes next while the underline carries on; in
/// the middle of bold words it takes the bold off them.
TextEditingValue inlineAtCursor(
  FormatController c,
  TextEditingValue v,
  MdDoc doc,
  int kind,
) {
  final sel = v.selection;
  if (!sel.isCollapsed) {
    c.clearPending();
    return toggleInline(v, doc, kind);
  }
  final at = sel.baseOffset;
  var typed = _typedKinds(c, doc, at);
  final now = c.pendingAt == at ? c.pendingKinds : typed;
  final want = now ^ kind;
  if (want & kind != 0 &&
      c.stopAt == at &&
      _carriedKinds(doc, at) & kind != 0) {
    // On again where it was just stopped: it simply carries on.
    c.stopAt = null;
    typed = _typedKinds(c, doc, at);
  }
  if (want & kind == 0 && typed & kind != 0) {
    // Off, for formatting the text itself has here.
    var end = -1;
    var cur = at;
    while (true) {
      MdRegion? hit;
      for (final r in doc.regions) {
        if (r.closeStart == cur && r.kind & Md.link == 0) {
          hit = r;
          break;
        }
      }
      if (hit == null) break;
      if (hit.kind & kind != 0) {
        end = hit.closeEnd;
        break;
      }
      cur = hit.closeEnd;
    }
    if (end < 0 && _carriedKinds(doc, at) & kind != 0) end = at;
    if (end >= 0) {
      // At the end of those words: stop it for what is typed next.
      c.stopAt = end;
      c.setPending(end, want);
      return end == at
          ? v
          : v.copyWith(selection: TextSelection.collapsed(offset: end));
    }
    // In the middle of them: those words go back to plain.
    c.clearPending();
    return toggleInline(v, doc, kind);
  }
  if (want == typed) {
    c.clearPending();
  } else {
    c.setPending(at, want);
  }
  return v;
}

/// [v] with the markers of [kind] around [regions] removed (any other kind
/// kept: *** -> *), the selection kept on the same words.
TextEditingValue _removeRegions(
  TextEditingValue v,
  Iterable<MdRegion> regions,
  int kind,
) {
  final cuts = <(int, int, String)>[];
  for (final r in regions) {
    final (ko, kc) = _markersFor(r.kind & ~kind);
    cuts.add((r.openStart, r.openEnd, ko));
    cuts.add((r.closeStart, r.closeEnd, kc));
  }
  cuts.sort((x, y) => x.$1.compareTo(y.$1));
  int map(int x) {
    var d = 0;
    for (final (a, b, k) in cuts) {
      if (b <= x) {
        d += (b - a) - k.length;
      } else if (a < x) {
        d += x - a;
      }
    }
    return x - d;
  }

  var text = v.text;
  for (final (a, b, k) in cuts.reversed) {
    text = text.replaceRange(a, b, k);
  }
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: map(v.selection.start).clamp(0, text.length),
      extentOffset: map(v.selection.end).clamp(0, text.length),
    ),
  );
}

/// The region of [kind] that is exactly [a, b), markers and all.
MdRegion? _exactRegion(MdDoc doc, int kind, int a, int b) {
  for (final r in doc.regions) {
    if (r.kind & kind != 0 && r.openStart == a && r.closeEnd == b) return r;
  }
  return null;
}

/// The opening and closing markers of [kind].
(String, String) _markersFor(int kind) {
  if (kind & Md.bold != 0 && kind & Md.italic != 0) return ('***', '***');
  if (kind & Md.bold != 0) return ('**', '**');
  if (kind & Md.strike != 0) return ('~~', '~~');
  if (kind & Md.underline != 0) return ('<u>', '</u>');
  if (kind & Md.italic != 0) return ('*', '*');
  return ('', '');
}

/// Sets the lines under the selection to [kind]; if they all already are,
/// back to plain text. Numbered lists count from 1.
TextEditingValue setLineKind(TextEditingValue v, MdDoc doc, MdLineKind kind) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  final first = doc.lineAt(sel.start);
  var lastAt = sel.end;
  // Selecting whole lines often ends at the start of the next one.
  if (!sel.isCollapsed &&
      lastAt > sel.start &&
      doc.lineAt(lastAt).start == lastAt) {
    lastAt--;
  }
  final last = doc.lineAt(lastAt);
  final lines = doc.lines
      .where((l) => l.start >= first.start && l.start <= last.start)
      .toList();
  final allAlready = lines.every((l) => l.kind == kind);
  final target = allAlready ? MdLineKind.plain : kind;
  var text = v.text;
  var delta = 0, startDelta = 0;
  var n = 1;
  for (final l in lines) {
    final prefix = switch (target) {
      MdLineKind.h1 => '# ',
      MdLineKind.h2 => '## ',
      MdLineKind.h3 => '### ',
      MdLineKind.bullet => '${l.indent}- ',
      MdLineKind.numbered => '${l.indent}${n++}. ',
      MdLineKind.plain =>
        (l.kind == MdLineKind.bullet || l.kind == MdLineKind.numbered)
            ? l.indent
            : '',
    };
    final a = l.start + delta, b = l.prefixEnd + delta;
    text = text.replaceRange(a, b, prefix);
    final d = prefix.length - (l.prefixEnd - l.start);
    if (l.start == first.start) startDelta = d;
    delta += d;
  }
  final base = sel.isCollapsed
      ? sel.start + startDelta
      : sel.start + startDelta;
  final ext = sel.isCollapsed ? base : sel.end + delta;
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: base.clamp(first.start, text.length),
      extentOffset: ext.clamp(first.start, text.length),
    ),
  );
}

/// Heading: none -> 1 -> 2 -> 3 -> none, for the cursor's line.
MdLineKind nextHeading(MdLineKind k) => switch (k) {
  MdLineKind.h1 => MdLineKind.h2,
  MdLineKind.h2 => MdLineKind.h3,
  MdLineKind.h3 => MdLineKind.plain,
  _ => MdLineKind.h1,
};

/// Plain text again for the lines under the selection.
TextEditingValue clearFormatting(TextEditingValue v, MdDoc doc) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  final first = doc.lineAt(sel.start);
  final last = doc.lineAt(sel.end);
  final buf = StringBuffer();
  for (final r in doc.runs) {
    if (r.start < first.start || r.end > last.end) continue;
    // An escape stays: without it the character would read as formatting.
    if (r.flags & Md.escape == 0 &&
        r.flags & (Md.marker | Md.listMarker) != 0) {
      continue;
    }
    buf.write(doc.text.substring(r.start, r.end));
  }
  final plain = buf.toString();
  final text = v.text.replaceRange(first.start, last.end, plain);
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: first.start,
      extentOffset: first.start + plain.length,
    ),
  );
}

/// [label](url) in place of the selection.
TextEditingValue insertLink(TextEditingValue v, String url) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  // ] would end the label early and ( ) the address, so neither link
  // would work.
  final label = sel
      .textInside(v.text)
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\[\]]'), '');
  final safeUrl = url
      .replaceAll('(', '%28')
      .replaceAll(')', '%29')
      .replaceAll(' ', '%20');
  final md = '[${label.isEmpty ? url : label}]($safeUrl)';
  final text = v.text.replaceRange(sel.start, sel.end, md);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: sel.start + md.length),
  );
}

// -- the toolbar -------------------------------------------------------

/// The formatting bar above the keyboard, as in Notepad: heading, bold,
/// italic, strikethrough, underline, bulleted and numbered lists, link,
/// clear. Each
/// shows when it applies where the cursor is.
///
/// Only what the file's own format can store is offered: Markdown (and so
/// Notepad, which saves its formatting as Markdown) has no underline, so
/// [underline] is false there and the button is absent rather than writing
/// `<u>` tags that every other app shows as text.
class FormatBar extends StatelessWidget {
  const FormatBar({
    super.key,
    required this.state,
    required this.onAction,
    this.underline = true,
  });
  final FormatState state;
  final void Function(String action) onAction;
  final bool underline;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final headingLabel = switch (state.kind) {
      MdLineKind.h1 => 'H1',
      MdLineKind.h2 => 'H2',
      MdLineKind.h3 => 'H3',
      _ => null,
    };
    Widget btn(
      String action,
      IconData icon,
      String label,
      bool on, {
      String? text,
    }) => Expanded(
      child: _BarButton(
        label: label,
        on: on,
        onTap: () => onAction(action),
        child: text != null
            ? Text(
                text,
                style: TextStyle(
                  color: on ? Colors.white : p.ink,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w700,
                ),
              )
            : Icon(icon, size: 22.dp, color: on ? Colors.white : p.ink),
      ),
    );
    // Liquid glass, like the buttons at the top: a floating pill.
    // Safe-inset bottom padding ensures Android's navigation bar never overlaps the buttons.
    // Constrained width centers the toolbar ergonomically on tablets/foldables.
    final viewInsetBottom = MediaQuery.viewInsetsOf(context).bottom;
    final bottomPad = viewInsetBottom > 0
        ? 8.dp
        : MediaQuery.paddingOf(context).bottom + 8.dp;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620.dp),
        child: Padding(
          padding: EdgeInsets.fromLTRB(10.dp, 4.dp, 10.dp, bottomPad),
          child: GlassSurface(
            radius: 25.dp,
            thick: true,
            padding: EdgeInsets.symmetric(horizontal: 5.dp, vertical: 5.dp),
            child: Row(
          children: [
            btn(
              'heading',
              Icons.title_rounded,
              'Heading',
              headingLabel != null,
              text: headingLabel,
            ),
            btn(
              'bold',
              Icons.format_bold_rounded,
              'Bold',
              state.inline & Md.bold != 0,
            ),
            btn(
              'italic',
              Icons.format_italic_rounded,
              'Italic',
              state.inline & Md.italic != 0,
            ),
            if (underline)
              btn(
                'underline',
                Icons.format_underlined_rounded,
                'Underline',
                state.inline & Md.underline != 0,
              ),
            btn(
              'strike',
              Icons.format_strikethrough_rounded,
              'Strikethrough',
              state.inline & Md.strike != 0,
            ),
            btn(
              'bullet',
              Icons.format_list_bulleted_rounded,
              'Bulleted list',
              state.kind == MdLineKind.bullet,
            ),
            btn(
              'numbered',
              Icons.format_list_numbered_rounded,
              'Numbered list',
              state.kind == MdLineKind.numbered,
            ),
            btn(
              'link',
              CupertinoIcons.link,
              'Link',
              state.inline & Md.link != 0,
            ),
            btn('clear', Icons.format_clear_rounded, 'Clear formatting', false),
          ],
        ),
      ),
    ),
  ),
);
  }
}

/// [span] with [lines] underlined by hand: one straight line per text line,
/// at the same depth under the baseline whatever font each word is in. The
/// font's own underline sits where that font says, so under an emoji it
/// dropped lower than under the words beside it and the line broke.
class UnderlinedText extends StatelessWidget {
  const UnderlinedText(this.span, this.lines, {super.key});
  final InlineSpan span;
  final List<Underline> lines;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    final def = DefaultTextStyle.of(context);
    final align = def.textAlign ?? TextAlign.start;
    // What Text.rich lays out: the span under the default text style.
    final full = TextSpan(style: def.style, children: [span]);
    // Its own layer, so scrolling past does not lay the text out again.
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (_, box) => CustomPaint(
          foregroundPainter: _UnderPainter(
            full,
            lines,
            scaler,
            dir,
            box.maxWidth,
            align,
            def.textHeightBehavior,
          ),
          child: Text.rich(
            span,
            textScaler: scaler,
            textAlign: align,
            textHeightBehavior: def.textHeightBehavior,
          ),
        ),
      ),
    );
  }
}

class _UnderPainter extends CustomPainter {
  _UnderPainter(
    this.span,
    this.lines,
    this.scaler,
    this.dir,
    this.maxWidth,
    this.align,
    this.heights,
  );
  final InlineSpan span;
  final List<Underline> lines;
  final TextScaler scaler;
  final TextDirection dir;
  final double maxWidth;
  final TextAlign align;
  final TextHeightBehavior? heights;

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: span,
      textDirection: dir,
      textScaler: scaler,
      textAlign: align,
      textHeightBehavior: heights,
    )..layout(maxWidth: maxWidth.isFinite ? maxWidth : size.width);
    try {
      _paintUnders(
        canvas,
        tp,
        lines,
        scaler,
        Offset.zero,
        (Offset.zero & size).inflate(8),
      );
    } finally {
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_UnderPainter old) =>
      old.span != span ||
      old.lines != lines ||
      old.scaler != scaler ||
      old.dir != dir ||
      old.align != align ||
      old.heights != heights ||
      old.maxWidth != maxWidth;
}

/// [child] (the text field of [controller]) with its underlines drawn by
/// hand, as the read view draws them: the font's own underline dropped
/// lower under an emoji and broke. The field's own layout is read back, so
/// the lines sit exactly under its words, wherever it is scrolled.
class UnderlinedField extends StatefulWidget {
  const UnderlinedField({
    super.key,
    required this.controller,
    this.scroll,
    required this.child,
  });
  final FormatController controller;
  final ScrollController? scroll;
  final Widget child;

  @override
  State<UnderlinedField> createState() => _UnderlinedFieldState();
}

class _UnderlinedFieldState extends State<UnderlinedField> {
  final _key = GlobalKey();
  final _cache = _FieldLayout();

  @override
  void dispose() {
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: _key,
    foregroundPainter: _FieldUnderPainter(
      _key,
      widget.controller,
      widget.scroll,
      _cache,
    ),
    child: widget.child,
  );
}

/// The field's text laid out again, kept while it has not changed (the
/// cursor blinking repaints, and must not lay a long note out each time).
class _FieldLayout {
  InlineSpan? span;
  double width = -1;
  TextScaler? scaler;
  TextPainter? tp;

  TextPainter of(RenderEditable re, InlineSpan text) {
    // RenderEditable lays its text out this much narrower, for the cursor.
    final w = re.size.width - 1 - re.cursorWidth;
    final old = tp;
    if (old != null &&
        identical(span, text) &&
        width == w &&
        scaler == re.textScaler) {
      return old;
    }
    clear();
    span = text;
    width = w;
    scaler = re.textScaler;
    return tp = TextPainter(
      text: text,
      textDirection: re.textDirection,
      textAlign: re.textAlign,
      textScaler: re.textScaler,
      strutStyle: re.strutStyle,
      textHeightBehavior: re.textHeightBehavior,
      textWidthBasis: re.textWidthBasis,
      locale: re.locale,
    )..layout(minWidth: w < 0 ? 0 : w, maxWidth: w < 0 ? 0 : w);
  }

  void clear() {
    tp?.dispose();
    tp = null;
    span = null;
  }
}

class _FieldUnderPainter extends CustomPainter {
  _FieldUnderPainter(this.key, this.c, ScrollController? scroll, this.cache)
    : super(repaint: Listenable.merge([c, ?scroll]));
  final GlobalKey key;
  final FormatController c;
  final _FieldLayout cache;

  static RenderEditable? _find(RenderObject o) {
    if (o is RenderEditable) return o;
    RenderEditable? hit;
    o.visitChildren((k) => hit ??= _find(k));
    return hit;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = c.pal;
    if (!c.formatting || p == null || c.codeLanguage != null) return;
    if (c.text.length > FormatController.maxStyled) return;
    final root = key.currentContext?.findRenderObject();
    if (root == null) return;
    final re = _find(root);
    final text = re?.text;
    if (re == null || text == null || !re.hasSize || !re.attached) return;
    final base = (text is TextSpan ? text.style : null) ?? const TextStyle();
    final lines = <Underline>[];
    for (final r in c.doc.runs) {
      if (r.flags & Md.marker != 0 || r.flags & (Md.underline | Md.link) == 0) {
        continue;
      }
      final st = mdTextStyle(base, r.flags, p, editing: true);
      lines.add((
        start: r.start,
        end: r.end,
        size: st.fontSize ?? 16,
        colour: st.color ?? p.ink,
      ));
    }
    if (lines.isEmpty) return;
    final tp = cache.of(re, text);
    // The text's own spelling must be the field's, or the places are wrong.
    if (tp.plainText.length != c.text.length) return;
    final origin = re.localToGlobal(Offset.zero, ancestor: root as RenderBox?);
    final view = origin & re.size;
    canvas.save();
    canvas.clipRect(view);
    try {
      _paintUnders(
        canvas,
        tp,
        lines,
        re.textScaler,
        origin + Offset(0, -re.offset.pixels),
        view,
      );
    } finally {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FieldUnderPainter old) => old.c != c || old.key != key;
}

/// [lines] of [tp] (laid out text, drawn at [at]) underlined by hand,
/// within [area]: one straight line per text line, a little below the
/// baseline whatever font each word is in, broken only where a letter
/// hangs through it (g, y, ू), as Google Docs and browsers do.
void _paintUnders(
  Canvas canvas,
  TextPainter tp,
  List<Underline> lines,
  TextScaler scaler,
  Offset at,
  Rect area,
) {
  var halo = 1.0;
  // The lines go on a layer of their own, so the letters can then cut them.
  canvas.saveLayer(area, Paint());
  try {
    final metrics = tp.computeLineMetrics();
    final text = tp.plainText;
    final paint = Paint();
    for (final u in lines) {
      var e = u.end.clamp(0, text.length);
      // Not under a trailing line break or space.
      while (e > u.start && text.codeUnitAt(e - 1) <= 0x20) {
        e--;
      }
      if (u.start >= e) continue;
      final px = scaler.scale(u.size);
      if (px * 0.08 > halo) halo = px * 0.08;
      paint
        ..color = u.colour
        ..strokeWidth = px / 16 < 1 ? 1 : px / 16;
      // Line by line, so a line that wraps is not underlined under the
      // space it wrapped at.
      var s = u.start;
      while (s < e) {
        final lb = tp.getLineBoundary(TextPosition(offset: s));
        var le = lb.end > s && lb.end < e ? lb.end : e;
        final next = le;
        while (le > s && text.codeUnitAt(le - 1) <= 0x20) {
          le--;
        }
        for (final b in tp.getBoxesForSelection(
          TextSelection(baseOffset: s, extentOffset: le),
        )) {
          final mid = (b.top + b.bottom) / 2;
          final m = metrics.firstWhere(
            (m) =>
                mid >= m.baseline - m.ascent && mid <= m.baseline + m.descent,
            orElse: () => metrics.last,
          );
          final y = m.baseline + px * 0.2;
          canvas.drawLine(
            at + Offset(b.left, y),
            at + Offset(b.right, y),
            paint,
          );
        }
        s = next;
        while (s < e && text.codeUnitAt(s) <= 0x20) {
          s++;
        }
      }
    }
    // The text again, a little fatter, rubbing the line out under it.
    canvas.saveLayer(
      area,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..imageFilter = ui.ImageFilter.dilate(radiusX: halo, radiusY: halo),
    );
    try {
      tp.paint(canvas, at);
    } finally {
      canvas.restore();
    }
  } finally {
    canvas.restore();
  }
}

/// One button of the format bar. When on it sits in a round glass bubble
/// (a soft light at the top, a thin bright edge), as a selected tab does in
/// a liquid glass bar; a tap presses it in a little.
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.label,
    required this.on,
    required this.onTap,
    required this.child,
  });
  final String label;
  final bool on;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final face = SizedBox(
      height: 40.dp,
      child: Center(child: widget.child),
    );
    return Semantics(
      button: true,
      label: widget.label,
      selected: widget.on,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapCancel: () => _press(false),
        onTapUp: (_) => _press(false),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _down && !still ? 0.86 : 1,
          duration: Duration(milliseconds: _down ? 120 : kSpringMs),
          curve: _down ? Curves.easeOutCubic : kSpring,
          child: Padding(
            // Equal shares of the width: every button fits on any phone,
            // with nothing hidden behind a scroll.
            padding: EdgeInsets.symmetric(horizontal: 1.dp),
            // On: the same accent glass as the Save (tick) button.
            // A small circle, not the whole slot.
            child: widget.on
                ? SizedBox(
                    height: 40.dp,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 34.dp,
                        child: GlassSurface(
                          radius: 17.dp,
                          lit: _down,
                          gradient: p.accentFill,
                          child: Center(child: widget.child),
                        ),
                      ),
                    ),
                  )
                : face,
          ),
        ),
      ),
    );
  }
}
