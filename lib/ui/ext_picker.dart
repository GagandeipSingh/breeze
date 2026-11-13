import 'dart:ui' show BoxWidthStyle;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic/code_highlight.dart' show codeLanguageFor;
import 'file_look.dart';
import 'kit.dart';
import 'scale.dart';
import 'sheets.dart';

/// Known file types for the "Other" picker: extension and what it is.
/// Suggestions only; any extension can be typed.
const knownExts = <(String, String)>[
  // The common ones first: what most people come here for.
  ('.json', 'JSON data'),
  ('.csv', 'Table (CSV)'),
  ('.html', 'Web page'),
  ('.xml', 'XML data'),
  ('.py', 'Python'),
  ('.js', 'JavaScript'),
  ('.ts', 'TypeScript'),
  ('.java', 'Java'),
  ('.kt', 'Kotlin'),
  ('.c', 'C'),
  ('.cpp', 'C++'),
  ('.dart', 'Dart'),
  ('.rs', 'Rust'),
  ('.go', 'Go'),
  ('.swift', 'Swift'),
  ('.cs', 'C#'),
  ('.php', 'PHP'),
  ('.rb', 'Ruby'),
  ('.sql', 'SQL'),
  ('.sh', 'Shell script'),
  ('.yaml', 'YAML'),
  ('.css', 'CSS'),
  ('.h', 'C header'),
  ('.hpp', 'C++ header'),
  ('.kts', 'Kotlin script'),
  ('.m', 'Objective-C'),
  ('.jsx', 'React (JSX)'),
  ('.tsx', 'React (TSX)'),
  ('.lua', 'Lua'),
  ('.r', 'R'),
  ('.scala', 'Scala'),
  ('.pl', 'Perl'),
  ('.hs', 'Haskell'),
  ('.ex', 'Elixir'),
  ('.erl', 'Erlang'),
  ('.clj', 'Clojure'),
  ('.asm', 'Assembly'),
  ('.bat', 'Windows batch'),
  ('.ps1', 'PowerShell'),
  ('.scss', 'SCSS'),
  ('.vue', 'Vue'),
  ('.svg', 'SVG image source'),
  ('.toml', 'TOML'),
  ('.ini', 'Settings (INI)'),
  ('.env', 'Environment file'),
  ('.gradle', 'Gradle'),
  ('.proto', 'Protocol Buffers'),
  ('.tex', 'LaTeX'),
  ('.tsv', 'Table (TSV)'),
  ('.log', 'Log'),
];

/// What a typed extension is, with its dot, or null when it cannot be one:
/// letters and digits only, up to 8, at least one letter (the rule the
/// store reads a file's type by, so the file keeps it).
String? cleanExt(String typed) {
  var t = typed.trim().toLowerCase();
  while (t.startsWith('.')) {
    t = t.substring(1);
  }
  if (!RegExp(r'^(?=[a-z0-9]*[a-z])[a-z0-9]{1,8}$').hasMatch(t)) return null;
  return '.$t';
}

/// The suggestions for [typed]: extensions starting with it first, then
/// types whose name contains it.
List<(String, String)> extMatches(String typed) {
  final q = typed.trim().toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
  if (q.isEmpty) return knownExts;
  return [
    ...knownExts.where((k) => k.$1.substring(1).startsWith(q)),
    ...knownExts.where(
      (k) => !k.$1.substring(1).startsWith(q) && k.$2.toLowerCase().contains(q),
    ),
  ];
}

/// "Other" file type: type any extension, with the known ones suggested as
/// it is typed. Returns the extension with its dot, or null.
Future<String?> showExtensionPicker(BuildContext context, {String? last}) =>
    showGlassSheet<String>(context, builder: (_) => ExtPicker(last: last));

/// The picker's body. It owns its text field, released when the sheet is
/// gone: released any earlier, the closing slide still drew it.
class ExtPicker extends StatefulWidget {
  const ExtPicker({super.key, this.last, this.onPick, this.onBack});

  /// Shown inside another sheet: a pick goes here instead of closing the
  /// sheet, and [onBack] (drawn as a back arrow) returns to that sheet.
  final ValueChanged<String>? onPick;
  final VoidCallback? onBack;

  /// The type used last: it leads the list, marked.
  final String? last;

  @override
  State<ExtPicker> createState() => _ExtPickerState();
}

class _ExtPickerState extends State<ExtPicker> {
  final field = TextEditingController();

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  void setSheet(VoidCallback f) => setState(f);

  @override
  Widget build(BuildContext ctx) {
    final p = Pal.of(ctx);
    final ext = cleanExt(field.text);
    final typed = field.text.trim().replaceFirst(RegExp(r'^\.+'), '');
    final bad = typed.isNotEmpty && ext == null;
    final found = extMatches(field.text);
    final last = widget.last;
    // The one used last leads the list, even one of the user's own.
    final matches = field.text.trim().isEmpty && last != null
        ? [
            (
              last,
              found.where((k) => k.$1 == last).firstOrNull?.$2 ??
                  'Used last time',
            ),
            ...found.where((k) => k.$1 != last),
          ]
        : found;
    final known = {for (final k in knownExts) k.$1: k.$2};
    final what = ext == null
        ? null
        : known[ext] ?? (codeLanguageFor(ext) != null ? 'Code' : 'Plain text');
    void done(String e) {
      HapticFeedback.selectionClick();
      final onPick = widget.onPick;
      onPick == null ? Navigator.of(ctx).pop(e) : onPick(e);
    }

    Widget suggestion((String, String) k) {
      final look = FileLook.of(k.$1);
      final colours = codeLanguageFor(k.$1) != null;
      final isLast = k.$1 == widget.last;
      return Semantics(
        button: true,
        label: '${k.$1}, ${k.$2}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => done(k.$1),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 7.dp, horizontal: 6.dp),
            child: Row(
              children: [
                FileBadge(look: look, size: 32.dp),
                SizedBox(width: 12.dp),
                SizedBox(
                  width: 72.dp,
                  child: Text(
                    k.$1,
                    style: TextStyle(
                      color: look.ink(p),
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    k.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.ink, fontSize: 14.5.sp),
                  ),
                ),
                if (isLast)
                  Container(
                    margin: EdgeInsets.only(left: 8.dp),
                    padding: EdgeInsets.symmetric(
                      horizontal: 8.dp,
                      vertical: 3.dp,
                    ),
                    decoration: BoxDecoration(
                      gradient: p.accentFill,
                      borderRadius: BorderRadius.circular(10.dp),
                    ),
                    child: Text(
                      'Last used',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (colours)
                  Padding(
                    padding: EdgeInsets.only(left: 8.dp),
                    child: Icon(
                      CupertinoIcons.paintbrush,
                      size: 15.dp,
                      color: p.accent.withValues(alpha: 0.85),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      child: Padding(
        padding: EdgeInsets.fromLTRB(14.dp, 6.dp, 14.dp, 12.dp),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(6.dp, 6.dp, 6.dp, 2.dp),
                    child: Row(
                      children: [
                        if (widget.onBack != null)
                          Semantics(
                            button: true,
                            label: 'Back to file types',
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onBack,
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  0,
                                  4.dp,
                                  10.dp,
                                  4.dp,
                                ),
                                child: Icon(
                                  CupertinoIcons.chevron_left,
                                  size: 20.dp,
                                  color: p.ink,
                                ),
                              ),
                            ),
                          ),
                        Text(
                          'Data or code',
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 20.sp,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(6.dp, 0, 6.dp, 10.dp),
                    child: Text(
                      'Type any extension, or pick one.',
                      style: TextStyle(color: p.sub, fontSize: 13.sp),
                    ),
                  ),
                  TextField(
                    selectionWidthStyle: BoxWidthStyle.tight,
                    controller: field,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    maxLength: 9,
                    onChanged: (_) => setSheet(() {}),
                    onSubmitted: (_) {
                      if (ext != null) done(ext);
                    },
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16.dp,
                        vertical: 13.dp,
                      ),
                      counterText: '',
                      hintText: 'kt, rs, cpp…',
                      hintStyle: TextStyle(color: p.sub),
                      prefixText: '.',
                      prefixStyle: TextStyle(
                        color: p.accent,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w700,
                      ),
                      errorText: bad
                          ? 'Letters and numbers only, up to 8, with a letter'
                          : null,
                      filled: true,
                      fillColor: p.ink.withValues(alpha: p.dark ? 0.06 : 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14.dp),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  SizedBox(height: 8.dp),
                  Flexible(
                    child: matches.isEmpty
                        ? Padding(
                            padding: EdgeInsets.all(8.dp),
                            child: Text(
                              bad
                                  ? ''
                                  : 'Not one Breeze knows. It still works: saved '
                                        'as plain text with that extension.',
                              style: TextStyle(color: p.sub, fontSize: 13.sp),
                            ),
                          )
                        : ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: MediaQuery.sizeOf(ctx).height * 0.3,
                            ),
                            child: ListView(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              children: [
                                for (final k in matches) suggestion(k),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10.dp),
            // Quiet until there is something to use; then the accent button.
            Semantics(
              button: true,
              enabled: ext != null,
              child: GestureDetector(
                onTap: ext == null ? null : () => done(ext),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 50.dp,
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: 12.dp),
                  decoration: BoxDecoration(
                    gradient: ext == null ? null : p.accentFill,
                    color: ext == null
                        ? p.ink.withValues(alpha: p.dark ? 0.06 : 0.05)
                        : null,
                    borderRadius: BorderRadius.circular(16.dp),
                  ),
                  child: Text(
                    ext == null ? 'Type an extension' : 'Use $ext  ·  $what',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ext == null ? p.sub : Colors.white,
                      fontSize: 15.5.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
