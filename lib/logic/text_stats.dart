/// Counts for the File info dialog: words, characters with and without spaces,
/// lines. Matches what txtpad reports.
class TextStats {
  TextStats(String text)
    : words = _words(text),
      characters = text.characters0,
      charactersNoSpaces = text.replaceAll(RegExp(r'\s'), '').characters0,
      lines = text.isEmpty ? 0 : text.split('\n').length;

  final int words;
  final int characters;
  final int charactersNoSpaces;
  final int lines;

  static int _words(String t) {
    final m = RegExp(r'\S+').allMatches(t);
    return m.length;
  }
}

extension on String {
  /// Character count by Unicode scalar runes, so an emoji counts as one.
  int get characters0 => runes.length;
}

/// A human file size: 940 B, 12.4 kB, 3.1 MB.
String humanSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(2)} kB';
  return '${(bytes / 1000 / 1000).toStringAsFixed(2)} MB';
}

/// All match ranges of [query] in [text], case-insensitive. Used to highlight
/// in-file search hits.
List<(int, int)> findRanges(String text, String query) {
  if (query.isEmpty) return const [];
  final out = <(int, int)>[];
  final lower = _foldSameLength(text);
  final q = _foldSameLength(query);
  var i = lower.indexOf(q);
  while (i >= 0) {
    out.add((i, i + q.length));
    i = lower.indexOf(q, i + q.length);
  }
  return out;
}

/// [s] lowercased letter by letter, keeping every letter's length. Plain
/// toLowerCase turns the Turkish "İ" into two characters, so every match
/// after one pointed past where it was, and the last could point past the
/// end of the note (finding "stanbul" in "İstanbul" crashed the read view).
String _foldSameLength(String s) {
  final lower = s.toLowerCase();
  if (lower.length == s.length) return lower;
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final l = ch.toLowerCase();
    b.write(l.length == ch.length ? l : ch);
  }
  return b.toString();
}

/// [text] cut into pieces of about [size] characters, as (start, end)
/// offsets that cover it exactly. A cut prefers a line end, then a space or
/// comma, and never splits a surrogate pair. Used to draw a huge file a
/// piece at a time.
List<(int, int)> readChunks(String text, {int size = 4000}) {
  final out = <(int, int)>[];
  var start = 0;
  while (start < text.length) {
    var end = start + size;
    if (end >= text.length) {
      out.add((start, text.length));
      break;
    }
    final floor = start + size ~/ 4;
    var cut = text.lastIndexOf('\n', end - 1);
    if (cut >= floor) {
      end = cut + 1;
    } else {
      cut = -1;
      for (var i = end - 1; i >= floor; i--) {
        final c = text.codeUnitAt(i);
        if (c == 0x20 || c == 0x2C) {
          cut = i + 1;
          break;
        }
      }
      if (cut > start) end = cut;
      // Never between the halves of a surrogate pair (an emoji).
      final prev = text.codeUnitAt(end - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) end--;
    }
    out.add((start, end));
    start = end;
  }
  return out;
}

/// [text] with piece [i] of [chunks] replaced by [part], and the pieces
/// moved to match: piece [i] now spans [part], every later one shifts by the
/// change in length. Editing a huge file a piece at a time goes through
/// here, so a wrong offset would put text in the wrong place.
(String, List<(int, int)>) replaceChunk(
  String text,
  List<(int, int)> chunks,
  int i,
  String part,
) {
  final (a, b) = chunks[i];
  final next = text.substring(0, a) + part + text.substring(b);
  final delta = part.length - (b - a);
  final out = List<(int, int)>.of(chunks);
  out[i] = (a, a + part.length);
  for (var k = i + 1; k < out.length; k++) {
    out[k] = (out[k].$1 + delta, out[k].$2 + delta);
  }
  return (next, out);
}
