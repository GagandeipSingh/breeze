import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic/code_highlight.dart' show codeLanguageFor;
import 'ext_picker.dart';
import 'file_look.dart';
import 'kit.dart';
import 'scale.dart';
import 'sheets.dart';

/// What a new file will be, asked before the editor opens.
///
/// Each kind is saved in its own real format, so it looks native where it is
/// opened: a note and Markdown as Markdown (Windows 11 Notepad saves its own
/// formatting as Markdown), a Word document as .docx, data and code as
/// exactly what was typed. (RTF is not offered: few people want it beside
/// Word. It still opens and saves, and a title ending .rtf makes one.) The toolbar then offers only what
/// that format can store, and each choice here draws those buttons, so what
/// the user picks is what they get.
class FileKind {
  const FileKind(this.ext, this.title, this.where, this.tools);

  /// The extension, with its dot.
  final String ext;
  final String title;

  /// Where it opens natively, in a few words.
  final String where;

  /// The toolbar buttons this format can store (empty: no formatting).
  final List<IconData> tools;
}

const _markdownTools = [
  Icons.title_rounded,
  Icons.format_bold_rounded,
  Icons.format_italic_rounded,
  Icons.format_strikethrough_rounded,
  Icons.format_list_bulleted_rounded,
  Icons.format_list_numbered_rounded,
  CupertinoIcons.link,
];

const _documentTools = [
  Icons.title_rounded,
  Icons.format_bold_rounded,
  Icons.format_italic_rounded,
  Icons.format_underlined_rounded,
  Icons.format_strikethrough_rounded,
  Icons.format_list_bulleted_rounded,
  Icons.format_list_numbered_rounded,
  CupertinoIcons.link,
];

const fileKindNote = FileKind(
  '.txt',
  'Note',
  'Opens anywhere.',
  _markdownTools,
);
const fileKindMarkdown = FileKind(
  '.md',
  'Markdown',
  'For Obsidian, GitHub, VS Code.',
  _markdownTools,
);
const fileKindWord = FileKind(
  '.docx',
  'Word document',
  'For Word, Google Docs, Pages.',
  _documentTools,
);

/// A short name for the kind of file [ext] makes: the label on the pill
/// under a new note's title.
String fileKindName(String ext) {
  switch (ext.toLowerCase()) {
    case '':
    case '.txt':
    case '.text':
    case '.note':
      return 'Note';
    case '.md':
    case '.markdown':
      return 'Markdown';
    case '.rtf':
      return 'Document';
    case '.docx':
      return 'Word document';
    default:
      // A known type by its name ("Kotlin"), any other code as Code.
      final e = ext.toLowerCase();
      for (final k in knownExts) {
        if (k.$1 == e) return k.$2;
      }
      return codeLanguageFor(e) != null ? 'Code' : 'Plain text';
  }
}

/// Asks what the new file is. Returns its extension (with the dot), or null
/// when dismissed. [last] is marked as the one used last time.
/// The kinds with a row of their own; anything else is data or code.
const _kindExts = {
  '',
  '.txt',
  '.text',
  '.note',
  '.md',
  '.markdown',
  '.docx',
  '.rtf',
};

Future<String?> showNewFileKind(BuildContext context, {String? last}) {
  final lastExt = (last ?? '.txt').toLowerCase();
  // Whether the sheet shows the full Data or code list; outside the
  // builder so a rebuild does not reset it.
  final more = ValueNotifier(false);
  return showGlassSheet<String>(
    context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final p = Pal.of(ctx);
          void pick(String ext) {
            HapticFeedback.selectionClick();
            Navigator.of(ctx).pop(ext);
          }

          Widget badge(FileLook look) => FileBadge(look: look, size: 38.dp);

          // The data or code type used last, shown on its row.
          const kinds = _kindExts;
          final codeLast = kinds.contains(lastExt) ? null : cleanExt(lastExt);
          if (more.value) {
            void back() => setSheet(() => more.value = false);
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) back();
              },
              child: ExtPicker(last: codeLast, onPick: pick, onBack: back),
            );
          }

          Widget tools(List<IconData> icons) => icons.isEmpty
              ? Text(
                  'No formatting: saved exactly as typed',
                  style: TextStyle(color: p.sub, fontSize: 11.5.sp),
                )
              : Wrap(
                  spacing: 6.dp,
                  children: [
                    for (final i in icons)
                      Icon(
                        i,
                        size: 15.dp,
                        color: p.accent.withValues(alpha: 0.85),
                      ),
                  ],
                );

          Widget row({
            required Widget lead,
            required String title,
            String ext = '',
            required String where,
            required Widget below,
            required bool marked,
            required VoidCallback onTap,
            Widget? trailing,
          }) => Semantics(
            button: true,
            label: '$title. $where',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                margin: EdgeInsets.symmetric(vertical: 3.dp),
                padding: EdgeInsets.fromLTRB(10.dp, 8.dp, 10.dp, 8.dp),
                decoration: BoxDecoration(
                  color: marked
                      ? p.accent.withValues(alpha: p.dark ? 0.16 : 0.10)
                      : p.ink.withValues(alpha: p.dark ? 0.04 : 0.03),
                  borderRadius: BorderRadius.circular(15.dp),
                  border: Border.all(
                    color: marked
                      ? p.accent.withValues(alpha: 0.85)
                      : p.ink.withValues(alpha: 0.08),
                    width: marked ? 1.6 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    lead,
                    SizedBox(width: 10.dp),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(text: title),
                                      if (ext.isNotEmpty)
                                        TextSpan(
                                          text: '  $ext',
                                          style: TextStyle(
                                            color: p.sub,
                                            fontSize: 12.sp,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                    ],
                                  ),
                                  style: TextStyle(
                                    color: p.ink,
                                    fontSize: 15.sp,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (marked) ...[
                                SizedBox(width: 8.dp),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 7.dp,
                                    vertical: 1.5.dp,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: p.accentFill,
                                    borderRadius: BorderRadius.circular(10.dp),
                                  ),
                                  child: Text(
                                    'Last used',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5.sp,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          SizedBox(height: 1.dp),
                          Text(
                            where,
                            style: TextStyle(
                              color: p.sub,
                              fontSize: 12.sp,
                              height: 1.25,
                            ),
                          ),
                          if (below is! SizedBox) ...[
                            SizedBox(height: 4.dp),
                            below,
                          ],
                        ],
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          );

          // More turns this same sheet into the full list (one sheet, one
          // handle); its back arrow, or Back, returns to the file types.
          void openOther() {
            HapticFeedback.selectionClick();
            setSheet(() => more.value = true);
          }

          // One look for every chip; More differs only by its arrow, so
          // the row reads as one set and not as a set plus a button.
          Widget codeChip(
            String label, {
            bool marked = false,
            bool other = false,
          }) => Semantics(
            button: true,
            label: other ? 'More file types' : label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: other ? openOther : () => pick(label),
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  10.dp,
                  5.dp,
                  other ? 6.dp : 10.dp,
                  5.dp,
                ),
                decoration: BoxDecoration(
                  gradient: marked ? p.accentFill : null,
                  color: marked
                      ? null
                      : p.ink.withValues(alpha: p.dark ? 0.08 : 0.05),
                  borderRadius: BorderRadius.circular(12.dp),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      other ? 'More' : label,
                      style: TextStyle(
                        color: marked ? Colors.white : p.ink,
                        fontSize: 12.5.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (other) ...[
                      SizedBox(width: 2.dp),
                      Icon(
                        CupertinoIcons.chevron_right,
                        size: 12.dp,
                        color: p.sub,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );

          Widget kind(FileKind k) => row(
            lead: badge(FileLook.of(k.ext)),
            title: k.title,
            ext: k.ext,
            where: k.where,
            below: tools(k.tools),
            trailing: Padding(
              padding: EdgeInsets.only(top: 12.dp, left: 4.dp),
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 18.dp,
                color: p.accent,
              ),
            ),
            marked:
                lastExt == k.ext ||
                (k.ext == '.txt' &&
                    const {'', '.text', '.note'}.contains(lastExt)) ||
                (k.ext == '.md' && lastExt == '.markdown'),
            onTap: () => pick(k.ext),
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(12.dp, 4.dp, 12.dp, 8.dp),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(4.dp, 2.dp, 4.dp, 1.dp),
                    child: Text(
                      'What are you making?',
                      style: TextStyle(
                        color: p.ink,
                        fontSize: 18.sp,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(4.dp, 0, 4.dp, 4.dp),
                    child: Text(
                      'Blue icons: the formatting it keeps.',
                      style: TextStyle(color: p.sub, fontSize: 12.sp),
                    ),
                  ),
                  kind(fileKindNote),
                  kind(fileKindWord),
                  kind(fileKindMarkdown),
                  // Three common types one tap away; every other type is
                  // behind Other, a list of its own searched as typed.
                  row(
                    lead: badge(_codeLook),
                    title: 'Data or code',
                    where: 'Any extension: .py, .kt, .cpp…',
                    below: Wrap(
                      spacing: 6.dp,
                      runSpacing: 6.dp,
                      children: [
                        for (final e in mainCodeExts(codeLast))
                          codeChip(e, marked: e == codeLast),
                        codeChip('', other: true),
                      ],
                    ),
                    marked: codeLast != null,
                    onTap: openOther,
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// The three chips on the data-or-code row: the common ones, with the type
/// used last taking the first place when it is not one of them.
List<String> mainCodeExts(String? last) {
  const main = ['.json', '.html', '.py'];
  if (last == null || main.contains(last)) return main;
  return [last, ...main.take(2)];
}

/// The data-or-code row's badge: code's colour, braces for a mark.
const _codeLook = FileLook(
  'Code',
  CupertinoIcons.chevron_left_slash_chevron_right,
  Color(0xFFD63B79),
  Color(0xFFFF8DB8),
  mark: '{ }',
);
