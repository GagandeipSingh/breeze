/// Whether [text] is a binary file read as text (an image, an app, a zip):
/// Breeze opens anything, as Notepad and VS Code do, but such a file shows
/// as strange characters and must never be saved back, or its bytes change.
///
/// Binary when the start of it holds a NUL, or more than one character in
/// twenty is a control character. Tabs, line breaks, form feeds and the
/// escape that starts a log's colour codes are ordinary text and do not
/// count. Text in any language never trips it: letters are not controls.
bool looksBinary(String text) {
  final n = text.length < 8000 ? text.length : 8000;
  if (n == 0) return false;
  var odd = 0;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0) return true;
    final control =
        (c < 0x20 &&
            c != 0x09 &&
            c != 0x0A &&
            c != 0x0D &&
            c != 0x0C &&
            c != 0x1B) ||
        c == 0x7F ||
        (c >= 0x80 && c <= 0x9F) ||
        c == 0xFFFD;
    if (control) odd++;
  }
  return odd * 20 > n;
}

/// [text] of a binary file made readable on screen: every control
/// character (which the font has no shape for, so it drew a "no glyph"
/// box) becomes a middle dot, as a hex viewer's text column shows it.
/// Line breaks and tabs stay. For display only: a binary file is never
/// saved back.
String binaryForDisplay(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    final control =
        (r < 0x20 && r != 0x09 && r != 0x0A) ||
        r == 0x7F ||
        (r >= 0x80 && r <= 0x9F) ||
        r == 0xFFFD;
    out.writeCharCode(control ? 0x00B7 : r);
  }
  return out.toString();
}
