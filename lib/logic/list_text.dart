/// The short texts on the home list: when a file was changed, and the first
/// words of it with the writing symbols taken out.
library;

import 'package:intl/intl.dart';

import 'binary_text.dart';

/// The clock as the phone shows it: 24-hour, or 12-hour with AM/PM.
String clockTime(DateTime t, {bool h24 = true}) =>
    DateFormat(h24 ? 'HH:mm' : 'h:mm a').format(t);

/// A full date with the time, for details: "5 Nov 2026, 16:21".
String fullDate(DateTime t, {bool h24 = true}) =>
    '${DateFormat('d MMM yyyy').format(t)}, ${clockTime(t, h24: h24)}';

/// "Today, 16:21", "Yesterday, 09:05", "Mon, 14:30" within the week,
/// "12 Nov" this year, "12 Nov 2025" before. [short] drops the time.
String friendlyDate(
  DateTime t, {
  DateTime? now,
  bool short = false,
  bool h24 = true,
}) {
  final n = now ?? DateTime.now();
  // Calendar days, counted in UTC: a local day across a clock change is
  // 23 or 25 hours long, and a 23-hour "yesterday" would read as today.
  final today = DateTime.utc(n.year, n.month, n.day);
  final day = DateTime.utc(t.year, t.month, t.day);
  final ago = today.difference(day).inDays;
  final time = clockTime(t, h24: h24);
  if (ago == 0) return short ? time : 'Today, $time';
  if (ago == 1) return short ? 'Yesterday' : 'Yesterday, $time';
  if (ago > 1 && ago < 7) {
    final wd = DateFormat('EEE').format(t);
    return short ? wd : '$wd, $time';
  }
  return DateFormat(t.year == n.year ? 'd MMM' : 'd MMM yyyy').format(t);
}

final _heading = RegExp(r'^\s{0,3}#{1,6}\s+');
final _item = RegExp(r'^\s*(?:[-*+]|\d{1,4}[.)])\s+');
final _marks = RegExp(
  r'\*\*|__|~~|</?u>|(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])',
);
final _escape = RegExp(r'\\([\\`*_{}\[\]()#+\-.!<>~|])');
final _aside = RegExp(
  '[${String.fromCharCode(0xE100)}-${String.fromCharCode(0xE17F)}]',
);
final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');

/// The first words of a file for its tile, read as a person would: a note's
/// heading, list and bold symbols gone; a table's commas as dots; a title
/// that only repeats the file's [name] left out. Code and other data are
/// shown as written.
String previewText(String raw, String ext, String name) {
  final e = ext.toLowerCase();
  if (e != '.docx' && looksBinary(raw)) return 'Binary file';
  var lines = raw.split(RegExp(r'\r?\n'));
  if (const {'', '.txt', '.text', '.note', '.md', '.markdown'}.contains(e)) {
    lines = [for (final l in lines) _plainLine(l)];
  } else if (e == '.csv' || e == '.tsv') {
    final sep = e == '.csv' ? ',' : '\t';
    lines = [
      for (final l in lines)
        _cells(l, sep).where((c) => c.isNotEmpty).join(' · '),
    ];
  }
  lines = [for (final l in lines) l.trim()]..removeWhere((l) => l.isEmpty);
  if (lines.isNotEmpty && _same(lines.first, name)) lines.removeAt(0);
  return lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One line of a note without its writing symbols.
String _plainLine(String l) {
  var t = l.replaceFirst(_heading, '').replaceFirst(_item, '');
  // An escaped symbol is set aside first, so it is shown, not taken for
  // formatting; not when the line already holds such a set-aside
  // character of its own, which would come back as a letter.
  final mask = t.contains(r'\') && !_aside.hasMatch(t);
  if (mask) {
    t = t.replaceAllMapped(
      _escape,
      (m) => String.fromCharCode(0xE100 + m[1]!.codeUnitAt(0)),
    );
  }
  t = t.replaceAllMapped(_link, (m) => m[1]!).replaceAll(_marks, '');
  if (mask) {
    t = t.replaceAllMapped(
      _aside,
      (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xE100),
    );
  }
  return t;
}

/// A table row's cells: a quoted cell keeps its commas ("Doe, John") and
/// a doubled quote inside it is one quote.
List<String> _cells(String line, String sep) {
  final out = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"' && cell.toString().trim().isEmpty) {
      quoted = true;
    } else if (ch == sep) {
      out.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(ch);
    }
  }
  out.add(cell.toString().trim());
  return out;
}

bool _same(String a, String b) {
  // Letters and digits of any script; spaces and punctuation between
  // words do not matter.
  String k(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\p{P}\p{S}\s]+', unicode: true), ' ')
      .trim();
  final x = k(a), y = k(b);
  // The same words, or the first whole words of the name ("Masala chai"
  // heading a file named "Masala chai recipe").
  return x.length >= 3 && (x == y || y.startsWith('$x '));
}
