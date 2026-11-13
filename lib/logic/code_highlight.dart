import 'dart:async';
import 'dart:isolate';

import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// Syntax colours for code files, as a code editor shows them.
///
/// highlight.js's language set (about 190), chosen by the file's extension.
/// The colours are Atom One, light or dark with the app. Nothing is written
/// to the file: the colours are only how the text is drawn.
///
/// The result is FLAT: (text, scope) pieces that join back to exactly the
/// code. The editor draws its text field from them, and a field whose spans
/// do not spell its text breaks the cursor, so anything that does not join
/// back is thrown away and the code is drawn plain.
final Highlight _hl = Highlight()..registerLanguages(builtinAllLanguages);

/// Extensions whose highlight.js name differs from the extension itself.
/// Everything else is tried as an alias (py, js, ts, rs, kt, rb, sh, ...).
const _byExt = {
  '.h': 'cpp',
  '.hpp': 'cpp',
  '.cc': 'cpp',
  '.cxx': 'cpp',
  '.htm': 'xml',
  '.html': 'xml',
  '.xhtml': 'xml',
  '.svg': 'xml',
  '.plist': 'xml',
  '.vue': 'xml',
  '.jsx': 'javascript',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.tsx': 'typescript',
  '.yml': 'yaml',
  '.toml': 'ini',
  '.cfg': 'ini',
  '.conf': 'ini',
  '.env': 'bash',
  '.zsh': 'bash',
  '.bat': 'dos',
  '.cmd': 'dos',
  '.ps1': 'powershell',
  '.gradle': 'groovy',
  '.kts': 'kotlin',
  '.sql': 'sql',
  '.asm': 'x86asm',
  '.s': 'x86asm',
  '.ino': 'cpp',
  '.cu': 'cpp',
  '.mm': 'objectivec',
  '.pyw': 'python',
};

/// Extensions never coloured: prose, or data with nothing to colour.
const _never = {
  '',
  '.txt',
  '.md',
  '.markdown',
  '.text',
  '.note',
  '.csv',
  '.tsv',
  '.rtf',
  '.log',
};

/// The language for a file extension (with its dot), or null for none.
String? codeLanguageFor(String ext) {
  final e = ext.toLowerCase();
  if (_never.contains(e)) return null;
  final named = _byExt[e];
  if (named != null) return named;
  final bare = e.startsWith('.') ? e.substring(1) : e;
  return _hl.getLanguage(bare) != null ? bare : null;
}

/// [code] in coloured pieces: (text, scope). Null when it could not be
/// coloured (the caller draws it plain).
List<(String, String?)>? highlightCode(String code, String language) {
  try {
    final result = _hl.highlight(code: code, language: language);
    final r = _FlatRenderer();
    result.render(r);
    // The pieces must spell the code exactly, or the cursor breaks.
    final joined = StringBuffer();
    for (final p in r.out) {
      joined.write(p.$1);
    }
    if (joined.length != code.length || joined.toString() != code) return null;
    return r.out;
  } catch (_) {
    return null;
  }
}

class _FlatRenderer implements HighlightRenderer {
  final out = <(String, String?)>[];
  final _scopes = <String?>[];

  @override
  void addText(String text) {
    String? scope;
    for (var i = _scopes.length - 1; i >= 0; i--) {
      if (_scopes[i] != null) {
        scope = _scopes[i];
        break;
      }
    }
    out.add((text, scope));
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }
}

/// The colour (and italic/bold) of a scope, for light or dark. A scope like
/// "title.function_" falls back to "title".
TextStyle? codeStyle(String? scope, bool dark) {
  if (scope == null) return null;
  final theme = dark ? atomOneDarkTheme : atomOneLightTheme;
  var s = scope;
  while (true) {
    final st = theme[s];
    if (st != null) return st;
    final dot = s.lastIndexOf('.');
    if (dot < 0) return null;
    s = s.substring(0, dot);
  }
}

/// Plain code colour (the theme's root), for light or dark.
Color codeInk(bool dark) =>
    (dark ? atomOneDarkTheme : atomOneLightTheme)['root']!.color!;

/// Colours code on a background isolate that lives as long as the app, so
/// each language is prepared once (up to 0.9 s on first use) and a long
/// file (up to 2 s for 1,000 lines of C, measured) never stalls typing.
/// One job at a time; a newer [colour] call with `latestOnly` (the editor,
/// after each pause in typing) replaces such calls still waiting, so typing
/// never builds a queue of whole-file jobs that a PDF would wait behind.
class CodeColourer {
  CodeColourer._() {
    final inbox = ReceivePort();
    inbox.listen((m) {
      if (m is SendPort) {
        _send = m;
        _pump();
      } else if (m is List) {
        final job = _running;
        _running = null;
        job?.done.complete(m[1] as List<(String, String?)>?);
        _pump();
      }
    });
    Isolate.spawn(_worker, inbox.sendPort).then(
      (_) {},
      onError: (_) {
        _failed = true;
        for (final j in _queue) {
          j.done.complete(null);
        }
        _queue.clear();
      },
    );
  }
  static final CodeColourer instance = CodeColourer._();

  SendPort? _send;
  var _failed = false;
  _Job? _running;
  final _queue = <_Job>[];

  /// The colour pieces of [code], or null (unknown language, or no worker).
  Future<List<(String, String?)>?> colour(
    String code,
    String language, {
    bool latestOnly = false,
  }) {
    if (_failed) return Future.value(null);
    if (latestOnly) {
      _queue.removeWhere((j) {
        if (!j.latestOnly) return false;
        j.done.complete(null);
        return true;
      });
    }
    final job = _Job(code, language, latestOnly);
    _queue.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    final send = _send;
    if (send == null || _running != null || _queue.isEmpty) return;
    final job = _running = _queue.removeAt(0);
    send.send([0, job.code, job.language]);
  }

  static void _worker(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    inbox.listen((m) {
      final r = m as List;
      List<(String, String?)>? got;
      try {
        got = highlightCode(r[1] as String, r[2] as String);
      } catch (_) {
        // Never leave a job unanswered: it is drawn plain.
      }
      out.send([r[0], got]);
    });
  }
}

class _Job {
  _Job(this.code, this.language, this.latestOnly);
  final String code;
  final String language;
  final bool latestOnly;
  final done = Completer<List<(String, String?)>?>();
}
