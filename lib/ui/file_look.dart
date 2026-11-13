import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../logic/code_highlight.dart';
import 'kit.dart';

/// A file type's look, shared by the home list and the new-file sheet: its
/// colour, its icon (or a short mark, like Word's W) and its name.
class FileLook {
  const FileLook(this.label, this.icon, this.color, this.light, {this.mark});
  final String label;
  final IconData icon;

  /// Drawn instead of [icon] when set: a letter reads faster than a tiny
  /// picture of a page.
  final String? mark;

  /// On light glass; [light] is the same hue lifted for dark mode.
  final Color color;
  final Color light;

  /// The colour behind the icon. Word is the app's own blue.
  Color base(Pal p) => identical(this, word) ? p.accent : color;

  /// The icon's and label's colour.
  Color ink(Pal p) =>
      identical(this, word) ? p.accent : (p.dark ? light : color);

  /// The badge's fill: the colour, a touch lighter at the top.
  Gradient fill(Pal p) {
    if (identical(this, word)) return p.accentFill;
    final c = base(p);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color.lerp(c, Colors.white, 0.12)!,
        Color.lerp(c, Colors.black, 0.10)!,
      ],
    );
  }

  static const word = FileLook(
    'Word',
    CupertinoIcons.doc_richtext,
    Color(0xFF2B6BE6),
    Color(0xFF7AA7FF),
    mark: 'W',
  );
  static const rtf = FileLook(
    'RTF',
    CupertinoIcons.textformat,
    Color(0xFF8E4FE0),
    Color(0xFFC39BFF),
    mark: 'Aa',
  );
  static const markdown = FileLook(
    'Markdown',
    CupertinoIcons.number,
    Color(0xFF0E9F94),
    Color(0xFF5FD6CB),
    mark: '#',
  );
  static const text = FileLook(
    'Text',
    CupertinoIcons.doc_text,
    Color(0xFFE08A12),
    Color(0xFFFFC266),
  );
  static const json = FileLook(
    'JSON',
    CupertinoIcons.chevron_left_slash_chevron_right,
    Color(0xFFE5602E),
    Color(0xFFFF9A73),
    mark: '{ }',
  );
  static const data = FileLook(
    'Data',
    CupertinoIcons.table,
    Color(0xFF3E9B3A),
    Color(0xFF86D982),
  );
  static const log = FileLook(
    'Log',
    CupertinoIcons.list_bullet,
    Color(0xFF64748B),
    Color(0xFFA5B1C2),
  );
  static const code = FileLook(
    'Code',
    CupertinoIcons.chevron_left_slash_chevron_right,
    Color(0xFFD63B79),
    Color(0xFFFF8DB8),
  );

  static FileLook of(String ext) {
    final e = ext.toLowerCase();
    switch (e) {
      case '.docx':
        return word;
      case '.rtf':
        return rtf;
      case '.md' || '.markdown':
        return markdown;
      case '.json':
        return json;
      case '.csv' || '.tsv' || '.xml' || '.yaml' || '.yml' || '.ini':
        return data;
      case '.log':
        return log;
      case '' || '.txt' || '.text' || '.note':
        return text;
    }
    final lang = codeLanguageFor(e);
    if (lang == null) return text;
    final name = e.length > 1 ? e.substring(1).toUpperCase() : 'Code';
    return FileLook(
      name.length <= 5 ? name : 'Code',
      code.icon,
      code.color,
      code.light,
    );
  }
}

/// The round badge in a file type's colour (a filled glass circle, light
/// rim, white icon or mark), drawn like the + button. [selecting] turns it
/// into a ring to tick; [selected] fills it with the tick.
class FileBadge extends StatelessWidget {
  const FileBadge({
    super.key,
    required this.look,
    required this.size,
    this.selecting = false,
    this.selected = false,
  });
  final FileLook look;
  final double size;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final c = look.base(p);
    final empty = selecting && !selected;
    final mark = look.mark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: empty ? null : look.fill(p),
        color: empty ? c.withValues(alpha: p.dark ? 0.16 : 0.12) : null,
        border: Border.all(
          color: empty
              ? c.withValues(alpha: 0.7)
              : Colors.white.withValues(alpha: p.dark ? 0.22 : 0.35),
          width: empty ? 1.6 : 1,
        ),
        boxShadow: empty
            ? null
            : [
                BoxShadow(
                  color: c.withValues(alpha: p.dark ? 0.28 : 0.22),
                  blurRadius: size * 0.22,
                  offset: Offset(0, size * 0.06),
                ),
              ],
      ),
      child: empty
          ? null
          : selecting
          ? Icon(
              CupertinoIcons.checkmark_alt,
              size: size * 0.46,
              color: Colors.white,
            )
          : mark != null
          ? Text(
              mark,
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * (mark.length > 2 ? 0.34 : 0.42),
                fontWeight: FontWeight.w800,
                height: 1,
                letterSpacing: mark.length > 2 ? -0.5 : 0,
              ),
            )
          : Icon(look.icon, size: size * 0.46, color: Colors.white),
    );
  }
}

/// The type to share a file as. Breeze's own kinds get their real type;
/// everything else Breeze can open is text, so it goes as text/plain,
/// which every app that takes a file can read.
String shareMime(String ext) => switch (ext.toLowerCase()) {
  '.docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.rtf' => 'application/rtf',
  '.pdf' => 'application/pdf',
  '.csv' => 'text/csv',
  '.html' || '.htm' => 'text/html',
  '.json' => 'application/json',
  '.xml' => 'text/xml',
  '.zip' => 'application/zip',
  _ => 'text/plain',
};
