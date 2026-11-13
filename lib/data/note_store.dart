import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'samples.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/code_highlight.dart' show codeLanguageFor;
import '../logic/docx.dart';
import '../logic/rtf.dart';

/// One text document on disk. Breeze is a Notepad, not a .txt-only app: a note
/// can be any file the device will hand us — `.txt`, `.json`, `.md`, `.log`, a
/// config file with no extension at all — and we read and write it as text.
class Note {
  Note({
    required this.file,
    required this.modified,
    required this.size,
    this.pinned = false,
    this.tags = const [],
    this.external = false,
    this.locked = false,
    this.uri,
    this.charset = 'UTF-8',
  });

  /// Encoding of a picked document, kept for the write-back: a Latin-1 or
  /// UTF-16 file rewritten as UTF-8 would be corrupted.
  final String charset;

  /// The ORIGINAL document for a file picked with "Open file" (a content://
  /// URI). [file] is then a working copy; every save is also written back
  /// to this, which is what changes the user's real file.
  final String? uri;

  /// The file on disk. For [external] notes this is an absolute path the user
  /// picked from anywhere; otherwise it lives in the Breeze folder.
  final File file;
  final DateTime modified;
  final int size;
  final bool pinned;
  final List<String> tags;

  /// True when opened from outside the Breeze folder (like Notepad opening an
  /// arbitrary file). It still edits and saves in place when the path is
  /// writable.
  final bool external;

  /// Locked individually: opening it requires a fingerprint, independent of the
  /// global "Lock all files" setting.
  final bool locked;

  String get path => file.path;
  String get fullName => p.basename(file.path);

  /// Display name without the trailing extension (`notes` for `notes.txt`).
  String get name {
    final b = p.basename(file.path);
    final e = NoteStore.realExt(b);
    return e.isEmpty ? b : b.substring(0, b.length - e.length);
  }

  /// `.txt`, `.json`, … lowercased, or '' when there is none.
  String get ext => NoteStore.realExt(file.path).toLowerCase();

  Note copyWith({bool? pinned, List<String>? tags, bool? locked}) => Note(
    file: file,
    modified: modified,
    size: size,
    pinned: pinned ?? this.pinned,
    tags: tags ?? this.tags,
    external: external,
    locked: locked ?? this.locked,
    uri: uri,
    charset: charset,
  );
}

/// A file waiting in the trash with the moment it was deleted.
class TrashedNote {
  TrashedNote(this.file, this.originalName, this.deletedAt);
  final File file;
  final String originalName;
  final DateTime deletedAt;
  int get size => file.existsSync() ? file.lengthSync() : 0;
  Duration get remaining =>
      const Duration(days: 30) - DateTime.now().difference(deletedAt);
}

/// Reads and writes the Breeze folder of text files, plus the sidecar index
/// that remembers pins and tags (the filesystem has nowhere to store them) and
/// a 30-day trash. A [ChangeNotifier] so the list rebuilds on any change.
///
/// Encoding: files are read as UTF-8 and, when that fails on a binary or
/// legacy file, fall back to Latin-1 so *something* always opens — the same
/// "open anything" contract Notepad gives. Writes are always UTF-8.
///
/// The index is keyed by file NAME inside the Breeze folder. Every operation
/// that creates, renames, deletes, trashes or restores a file moves or clears
/// its key, so a pin, tag or LOCK never lands on a different file that later
/// takes the same name. Trashed files park their entry under `.trash/<name>`.
class NoteStore extends ChangeNotifier {
  NoteStore._(this.dir, this.trashDir, this._indexFile);

  final Directory dir;
  final Directory trashDir;
  final File _indexFile;

  List<Note> _notes = [];
  List<Note> get notes => _notes;

  /// filename -> {pinned, tags, locked}. Persisted to .index.json.
  Map<String, _Meta> _index = {};

  /// The index exists but cannot be read. Its locks are unknown, so every
  /// note is treated as LOCKED and the index is never overwritten (a save
  /// would replace it with an empty one and drop every lock for good).
  bool _indexBroken = false;

  /// Every tag the user has created, including empty ones.
  List<String> _allTags = [];
  List<String> get allTags => _allTags;

  bool _loading = true;
  bool get loading => _loading;

  /// Every change runs ONE AT A TIME. Two overlapping changes (an autosave
  /// rename while a shared file is imported) could otherwise swap a stale
  /// index in between another's edit and its save, dropping a lock or tags.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    // Re-read the index first: something outside this store (Save to Breeze,
    // or a second copy of the app) may have written it since.
    final run = _queue.then((_) async {
      await _loadIndex();
      return op();
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<NoteStore> open() async =>
      openIn(await getApplicationDocumentsDirectory(), samples: true);

  /// A store under [base] (tests point it at a temporary folder). With
  /// [samples], a first run into an empty folder starts with the sample
  /// files (lib/data/samples.dart).
  @visibleForTesting
  static Future<NoteStore> openIn(
    Directory base, {
    bool samples = false,
  }) async {
    final dir = Directory(p.join(base.path, 'Breeze'));
    final trash = Directory(p.join(base.path, 'Breeze', '.trash'));
    await dir.create(recursive: true);
    await trash.create(recursive: true);
    final store = NoteStore._(
      dir,
      trash,
      File(p.join(dir.path, '.index.json')),
    );
    await store.refresh();
    if (samples) {
      try {
        await store._addSamples();
      } catch (_) {
        // Samples are a welcome, never a reason not to start.
      }
    }
    return store;
  }

  /// Once per install: the sample files, into an empty folder only (someone
  /// updating, or who already has notes, gets none). A marker remembers it,
  /// so deleted samples never come back.
  Future<void> _addSamples() async {
    final marker = File(p.join(dir.path, '.samples'));
    if (await marker.exists()) return;
    await marker.writeAsString('1', flush: true);
    if (_notes.isNotEmpty) return;
    // Oldest first, a minute apart, so the list shows them in this order.
    final now = DateTime.now();
    final n = sampleFiles.length;
    for (var i = 0; i < n; i++) {
      final (name, text) = sampleFiles[i];
      final note = await create(name, content: text, rtf: true);
      try {
        await note.file.setLastModified(now.subtract(Duration(minutes: i)));
      } catch (_) {}
      if (name == sampleWelcome) await setPinned(note, true);
    }
    await refresh();
  }

  /// The folder shown under Settings › Path to files.
  String get folderPath => dir.path;

  // -- index -----------------------------------------------------------
  /// Builds the new maps and only THEN swaps them in: clearing first left a
  /// window, across the file read, where a pin or tag change saved an index
  /// holding nothing but itself and wiped every other file's metadata.
  Future<void> _loadIndex() async {
    if (!await _indexFile.exists()) {
      _index = {};
      _allTags = [];
      return;
    }
    try {
      final data = jsonDecode(await _indexFile.readAsString());
      final next = <String, _Meta>{};
      final files = (data['files'] as Map?) ?? {};
      files.forEach((k, v) {
        next[k as String] = _Meta(
          pinned: (v['pinned'] as bool?) ?? false,
          tags: ((v['tags'] as List?) ?? const []).cast<String>(),
          locked: (v['locked'] as bool?) ?? false,
        );
      });
      _index = next;
      _allTags = ((data['tags'] as List?) ?? const []).cast<String>();
      _indexBroken = false;
    } on FileSystemException {
      // Could not read it this time (busy, permissions): fail closed for now,
      // every file counts as locked, and try again on the next refresh.
      _indexBroken = true;
    } catch (_) {
      // Unreadable contents (a bad restore, a truncated copy). Which files
      // were locked is unknown, so EVERY file, the trash too, comes back
      // locked: nothing is exposed, and each one opens with the PIN or
      // fingerprint as usual. Pins and tags are lost; the damaged file is
      // kept beside it as .bad. Staying "broken" instead left every note
      // locked for good, with no way to unlock any of them.
      try {
        await _indexFile.copy('${_indexFile.path}.bad');
      } catch (_) {}
      final next = <String, _Meta>{};
      for (final folder in [dir, trashDir]) {
        try {
          if (!await folder.exists()) continue;
          await for (final e in folder.list()) {
            if (e is! File) continue;
            final base = p.basename(e.path);
            if (base.startsWith('.')) continue;
            final key = folder.path == trashDir.path ? _trashKey(base) : base;
            next[key] = _Meta(pinned: false, tags: const [], locked: true);
          }
        } catch (_) {}
      }
      _index = next;
      _allTags = [];
      _indexBroken = false;
      try {
        await _saveIndex();
      } catch (_) {
        _indexBroken = true;
      }
    }
  }

  Future<void> _saveIndex() async {
    if (_indexBroken) return;
    final files = <String, dynamic>{};
    _index.forEach((k, v) {
      if (v.pinned || v.tags.isNotEmpty || v.locked) {
        files[k] = {'pinned': v.pinned, 'tags': v.tags, 'locked': v.locked};
      }
    });
    // Temp file then rename: a reader never sees a half-written index, and a
    // crash mid-write leaves the old one whole.
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'files': files, 'tags': _allTags}),
      flush: true,
    );
    await tmp.rename(_indexFile.path);
  }

  /// Index key of a trashed file, so its pin/tags/lock come back on restore.
  static String _trashKey(String trashBase) => '.trash/$trashBase';

  // -- listing ---------------------------------------------------------
  Future<void> refresh() => _serial(_refresh);

  Future<void> _refresh() async {
    _loading = true;
    await _loadIndex();
    final out = <Note>[];
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final base = p.basename(e.path);
        if (base.startsWith('.')) continue; // .index.json, hidden sidecars
        final stat = await e.stat();
        final meta = _index[base];
        out.add(
          Note(
            file: e,
            modified: stat.modified,
            size: stat.size,
            pinned: meta?.pinned ?? false,
            tags: meta?.tags ?? const [],
            locked: _indexBroken || (meta?.locked ?? false),
          ),
        );
      }
    }
    // An entry whose file is gone (deleted outside the app, or a crash
    // between a delete and the index save) would attach its lock and tags
    // to the next file that takes the name. Drop it.
    if (!_indexBroken && await dir.exists()) {
      final names = out.map((n) => p.basename(n.file.path)).toSet();
      final stale = _index.keys
          .where((k) => !k.startsWith('.trash/') && !names.contains(k))
          .toList();
      if (stale.isNotEmpty) {
        stale.forEach(_index.remove);
        await _saveIndex();
      }
    }
    _notes = out;
    _loading = false;
    notifyListeners();
  }

  // -- reading / writing ----------------------------------------------
  /// Read any file as the text Breeze shows: an RTF document as its
  /// formatted text, anything else as it is. UTF-8 first; on failure,
  /// Latin-1 so a binary or mis-encoded file still opens instead of throwing.
  Future<String> read(Note note) async => (await readText(note)).text;

  /// [read], with the encoding and, for an RTF document, what it holds that
  /// Breeze cannot keep.
  Future<NoteText> readText(Note note) async {
    if (isDocx(note.file.path)) {
      final bytes = await note.file.readAsBytes();
      // A text file named .docx is not a Word document, and stays text.
      if (looksLikeDocx(bytes)) {
        final r = await compute(readDocx, bytes);
        return NoteText(r.markdown, 'UTF-8', r);
      }
    }
    final (raw, charset) = await readWithCharset(note);
    if (isRtf(note.file.path) && looksLikeRtf(raw)) {
      final r = await compute(readRtf, raw);
      return NoteText(r.markdown, charset, r);
    }
    return NoteText(raw, charset, null);
  }

  /// An .rtf name. Its text is RTF only when the file really holds RTF
  /// ([looksLikeRtf]); a plain text file with that name stays plain.
  static bool isRtf(String name) => realExt(name).toLowerCase() == '.rtf';

  /// A .docx name. It is a Word document only when the file really is one
  /// ([looksLikeDocx]).
  static bool isDocx(String name) => realExt(name).toLowerCase() == '.docx';

  /// 'rtf' or 'docx' for a document name, '' for anything else: two names
  /// of one kind hold the same bytes, so between them a rename is enough.
  static String docKind(String name) =>
      isRtf(name) ? 'rtf' : (isDocx(name) ? 'docx' : '');

  /// The bytes of a Word document that Android handed over as text. Android
  /// decodes a file that is not UTF-8 as Latin-1, one character per byte,
  /// so the bytes come back exactly; text it did read as UTF-8 goes back
  /// through UTF-8, which also gives back exactly what was read.
  static List<int> bytesOfHandedText(String text, String? charset) =>
      charset != null
      ? encodeText(text, charset)
      : (text.codeUnits.every((c) => c <= 0xFF)
            ? latin1.encode(text)
            : utf8.encode(text));

  /// The text and the encoding it was read in, to save it back the same way
  /// (a Latin-1 or UTF-16 file rewritten as UTF-8 changed every accented
  /// byte, and a binary file was mangled).
  Future<(String, String)> readWithCharset(Note note) async =>
      decodeText(await note.file.readAsBytes());

  static const _docs = MethodChannel('breeze/open');

  /// A document picked with the system picker, opened through a working
  /// copy in the cache that every save writes back to [uri].
  Future<Note> openDocument(
    String uri,
    String name,
    String content, {
    String charset = 'UTF-8',
  }) async {
    final tmp = await getTemporaryDirectory();
    final folder = Directory(
      p.join(tmp.path, 'docs', uri.hashCode.toRadixString(16)),
    );
    await folder.create(recursive: true);
    final f = File(p.join(folder.path, _sanitize(name)));
    if (isDocx(name)) {
      // A Word document's own bytes, not its text.
      await f.writeAsBytes(bytesOfHandedText(content, charset), flush: true);
    } else {
      await f.writeAsString(content, flush: true);
    }
    final stat = await f.stat();
    return Note(
      file: f,
      modified: stat.modified,
      size: stat.size,
      external: true,
      uri: uri,
      charset: charset,
    );
  }

  /// Save [content] to a note's file (UTF-8). Returns the refreshed note, or a
  /// new one if the name changed. [newName] may include an extension; without
  /// one the file keeps its own (`.txt` if it had none).
  ///
  /// With [rtf], [content] is the editor's text, written as an RTF document
  /// when the file is (or becomes) .rtf. The document is read back and
  /// compared before anything is written; a difference throws, so a save
  /// never replaces a file with something other than what was typed.
  Future<Note> save(
    Note note,
    String content, {
    String? newName,
    String charset = 'UTF-8',
    bool rtf = false,
  }) => _serial(
    () => _save(note, content, newName: newName, charset: charset, rtf: rtf),
  );

  Future<Note> _save(
    Note note,
    String content, {
    String? newName,
    String charset = 'UTF-8',
    bool rtf = false,
  }) async {
    File target = note.file;
    // A picked document keeps its name: it is someone else's file, and the
    // picker grants no right to rename it.
    if (note.uri == null && newName != null && newName.trim().isNotEmpty) {
      // The title field shows the name WITHOUT its extension, so a bare name
      // keeps the file's own; never renamed ONTO another file (that deletes
      // it): the next free name is taken instead.
      target = await _destFor(note, newName);
    }
    var docCharset = note.charset;
    if (rtf && isRtf(target.path)) {
      content = await compute(writeRtf, content);
      // RTF is ASCII: written plainly whatever the old file was in.
      charset = 'UTF-8';
      docCharset = 'UTF-8';
    }
    Uint8List? docx;
    if (rtf && isDocx(target.path)) {
      // Saving over a Word file keeps its body font and size.
      List<int>? old;
      try {
        if (isDocx(note.file.path) && await note.file.exists()) {
          old = await note.file.readAsBytes();
        }
      } catch (_) {}
      final Uint8List made = await compute(writeDocxKeeping, (content, old));
      docx = made;
      // Bytes travel to Android as Latin-1 text, one character per byte.
      content = latin1.decode(made);
      charset = 'ISO-8859-1';
      docCharset = 'ISO-8859-1';
    }
    // Write the new file FIRST. Deleting the old one before this write meant
    // a failed write (disk full, read-only folder) lost both copies.
    if (note.uri != null) {
      // The real file FIRST (a cleared cache must not block saving it). A
      // failure throws, and the editor offers Discard/Stay.
      await _docs.invokeMethod('writeDocument', {
        'uri': note.uri,
        'content': content,
        'charset': docCharset,
      });
      await target.parent.create(recursive: true);
    }
    // A picked document's working copy is plain UTF-8; a note keeps the
    // encoding it was read in.
    final docBytes = docx;
    if (docBytes != null) {
      if (note.external || note.uri != null) {
        await target.writeAsBytes(docBytes, flush: true);
      } else {
        await _writeSafely(target, docBytes);
      }
    } else if (note.uri != null) {
      await target.writeAsString(content, flush: true);
    } else if (note.external) {
      // A file opened from elsewhere is written in place: replacing it by a
      // rename would turn a link into a copy and overwrite a read-only file.
      await target.writeAsBytes(encodeText(content, charset), flush: true);
    } else {
      await _writeSafely(target, encodeText(content, charset));
    }
    if (target.path != note.file.path) {
      if (!note.external) {
        // Rename carries pins/tags/lock across; a stale entry left under the
        // new name by an earlier file is replaced, never inherited.
        final m = _index.remove(p.basename(note.file.path));
        final newBase = p.basename(target.path);
        if (m != null) {
          _index[newBase] = m;
        } else {
          _index.remove(newBase);
        }
      }
      try {
        await note.file.delete();
      } catch (_) {}
      await _saveIndex();
    }
    await _refresh();
    return _notes.firstWhere(
      (n) => n.file.path == target.path,
      orElse: () => Note(
        file: target,
        modified: DateTime.now(),
        size: docx?.length ?? utf8.encode(content).length,
        external: note.external,
        uri: note.uri,
        charset: docCharset,
      ),
    );
  }

  /// Rename a note on disk (File.rename), carrying its pin/tags/lock. The
  /// contents are never re-read or re-encoded, so a Latin-1 or binary file
  /// comes through byte for byte, and an unchanged name changes nothing.
  Future<Note> rename(Note note, String newName) => _serial(() async {
    if (note.uri != null) return note;
    final dest = await _destFor(note, newName);
    if (dest.path == note.file.path) return note;
    try {
      await note.file.rename(dest.path);
    } catch (_) {
      await note.file.copy(dest.path);
      await note.file.delete();
    }
    if (!note.external) {
      final m = _index.remove(p.basename(note.file.path));
      _index.remove(p.basename(dest.path));
      if (m != null) _index[p.basename(dest.path)] = m;
      await _saveIndex();
    }
    await _refresh();
    return _notes.firstWhere(
      (n) => n.file.path == dest.path,
      orElse: () => Note(
        file: dest,
        modified: DateTime.now(),
        size: note.size,
        external: note.external,
      ),
    );
  });

  /// The extension [note] would have under [newName] (as [_destFor] names
  /// it), or '' for none.
  String extFor(Note note, String newName) =>
      realExt(_withExt(note, _sanitize(newName.trim())));

  String _withExt(Note note, String clean) {
    final own = realExt(note.file.path);
    return _typedExt(clean, own).isEmpty
        ? '$clean${own.isEmpty ? (note.external ? '' : '.txt') : own}'
        : clean;
  }

  /// Where [note] would live under [newName]: its own extension kept when
  /// none is typed, and the next free name when the wanted one is taken.
  Future<File> _destFor(Note note, String newName) async {
    final clean = _sanitize(newName.trim());
    final withExt = _withExt(note, clean);
    var dest = note.external
        ? File(p.join(p.dirname(note.file.path), withExt))
        : File(p.join(dir.path, withExt));
    if (dest.path != note.file.path && await dest.exists()) {
      final ext = realExt(withExt);
      final stem = withExt.substring(0, withExt.length - ext.length);
      var i = 2;
      File next() => File(p.join(p.dirname(dest.path), '$stem $i$ext'));
      while (await next().exists() && next().path != note.file.path) {
        i++;
      }
      dest = next();
    }
    return dest;
  }

  /// Create a new empty folder note and return it. Name may carry any
  /// extension; `.txt` is the default.
  /// With [rtf], [content] is the editor's text, written as an RTF document
  /// when the name is .rtf (see [save]).
  ///
  /// [bytes], when given, are the file exactly (a Word document arriving
  /// from another app), and [content] is ignored.
  /// With [exact], a name's last extension is kept whatever it is (a type
  /// the user chose, such as .kt or one Breeze has never heard of); without
  /// it only a known type counts and anything else gets .txt.
  Future<Note> create(
    String name, {
    String content = '',
    bool rtf = false,
    List<int>? bytes,
    bool exact = false,
  }) => _serial(
    () => _create(name, content: content, rtf: rtf, bytes: bytes, exact: exact),
  );

  Future<Note> _create(
    String name, {
    String content = '',
    bool rtf = false,
    List<int>? bytes,
    bool exact = false,
  }) async {
    if (bytes == null && rtf && isRtf(_sanitize(name.trim()))) {
      content = await compute(writeRtf, content);
    }
    if (bytes == null && rtf && isDocx(_sanitize(name.trim()))) {
      bytes = await compute(writeDocx, content);
    }
    var clean = _sanitize(name.trim().isEmpty ? 'Untitled' : name.trim());
    if (_typedExt(clean, '').isEmpty && !(exact && realExt(clean).isNotEmpty)) {
      clean = '$clean.txt';
    }
    var dest = File(p.join(dir.path, clean));
    // Avoid clobbering an existing file: Untitled, Untitled 2, …
    if (await dest.exists()) {
      final ext = realExt(clean);
      final stem = clean.substring(0, clean.length - ext.length);
      var i = 2;
      while (await File(p.join(dir.path, '$stem $i$ext')).exists()) {
        i++;
      }
      dest = File(p.join(dir.path, '$stem $i$ext'));
    }
    if (bytes != null) {
      await dest.writeAsBytes(bytes, flush: true);
    } else {
      await dest.writeAsString(content, flush: true);
    }
    // A new file starts clean: never inherit the tags or LOCK of an older
    // file that once had this name.
    if (_index.remove(p.basename(dest.path)) != null) await _saveIndex();
    await _refresh();
    return _notes.firstWhere(
      (n) => n.file.path == dest.path,
      orElse: () => Note(
        file: dest,
        modified: DateTime.now(),
        size: bytes?.length ?? content.length,
      ),
    );
  }

  /// Take a file handed to us by another app (tapped a `.json`, shared text,
  /// etc.) and make it a real, editable Breeze note. The source may be a
  /// content:// URI with no writable path, so we save its text into the Breeze
  /// folder under its own name and open that.
  ///
  /// Opening the same file again opens the copy already made, as long as it
  /// still holds exactly that text: each tap used to add "settings 2.json",
  /// "settings 3.json", ...
  ///
  /// [charset] is how Android decoded the file; a Word document's exact
  /// bytes are rebuilt from it.
  Future<Note> openIncoming(
    String name,
    String content, {
    String? charset,
  }) async {
    final wanted = name.trim().isEmpty ? 'Untitled.txt' : name.trim();
    var clean = _sanitize(wanted);
    // A received file keeps its own type, even one Breeze does not know
    // (main.kt, notes.abc): it is that file, not a new note. An unknown one
    // counts only when it looks like a file type, lowercase and short, so
    // a shared message titled "Dr.Smith" still becomes a note.
    final own = realExt(clean);
    final looksReal =
        _typedExt(clean, '').isNotEmpty ||
        RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(own);
    if (!looksReal) clean = '$clean.txt';
    final ext = realExt(clean);
    final stem = clean.substring(0, clean.length - ext.length);
    final same = RegExp(
      '^${RegExp.escape(stem)}( [0-9]+)?${RegExp.escape(ext)}\$',
    );
    // A Word document is compared and kept as its bytes.
    final docx = isDocx(clean) ? bytesOfHandedText(content, charset) : null;
    for (final n in List.of(_notes)) {
      if (n.external || n.locked || !same.hasMatch(n.fullName)) continue;
      try {
        if (docx != null) {
          if (listEquals(await n.file.readAsBytes(), docx)) return n;
          continue;
        }
        // The file as it is on disk: [read] gives an RTF document's text,
        // which is never the source that arrived.
        if ((await readWithCharset(n)).$1 == content) return n;
      } catch (_) {}
    }
    return create(clean, content: content, bytes: docx, exact: true);
  }

  /// A binary file handed over by another app, opened only to look at:
  /// kept in the cache, never saved into the Breeze folder, where it would
  /// sit among the notes as strange characters.
  Future<Note> openViewOnly(String name, String content) async {
    final tmp = await getTemporaryDirectory();
    final folder = Directory(p.join(tmp.path, 'view'));
    if (await folder.exists()) {
      // Only the one being looked at is kept.
      try {
        await folder.delete(recursive: true);
      } catch (_) {}
    }
    await folder.create(recursive: true);
    final f = File(
      p.join(folder.path, _sanitize(name.trim().isEmpty ? 'File' : name)),
    );
    await f.writeAsString(content, flush: true);
    final stat = await f.stat();
    return Note(
      file: f,
      modified: stat.modified,
      size: stat.size,
      external: true,
    );
  }

  /// Open an arbitrary file the user picked from anywhere on the device, the
  /// way Notepad opens any file. It is editable in place when writable.
  Future<Note> openExternalPath(String path) async {
    final f = File(path);
    final stat = await f.stat();
    final inFolder = p.isWithin(dir.path, path);
    if (inFolder) {
      await refresh();
      return _notes.firstWhere(
        (n) => n.file.path == path,
        orElse: () => Note(file: f, modified: stat.modified, size: stat.size),
      );
    }
    return Note(
      file: f,
      modified: stat.modified,
      size: stat.size,
      external: true,
    );
  }

  // -- pins / tags / lock ------------------------------------------------
  // Metadata is keyed by file NAME inside the Breeze folder; an outside file
  // that shares a name would hand its tags or lock to a Breeze note, so
  // external files carry none.

  Future<void> setPinned(Note note, bool pinned) =>
      _serial(() => _setPinned(note, pinned));

  Future<void> _setPinned(Note note, bool pinned) async {
    if (note.external) return;
    final base = p.basename(note.file.path);
    final m = _index[base] ?? _Meta(pinned: false, tags: const []);
    _index[base] = _Meta(pinned: pinned, tags: m.tags, locked: m.locked);
    await _saveIndex();
    await _refresh();
  }

  /// Lock or unlock a single file (fingerprint to open).
  Future<void> setLocked(Note note, bool locked) =>
      _serial(() => _setLocked(note, locked));

  Future<void> _setLocked(Note note, bool locked) async {
    if (note.external) return;
    final base = p.basename(note.file.path);
    final m = _index[base] ?? _Meta(pinned: false, tags: const []);
    _index[base] = _Meta(pinned: m.pinned, tags: m.tags, locked: locked);
    await _saveIndex();
    await _refresh();
  }

  /// A copy of [note] in the Breeze folder, named "NAME copy" (then
  /// "copy 2", …), carrying its tags and lock but not its pin. The original
  /// is never touched, so the copy is a safe snapshot to keep while the user
  /// changes the other one. A file opened from elsewhere is copied INTO the
  /// Breeze folder, which is where Breeze manages its own files.
  Future<Note> duplicate(Note note) => _serial(() => _duplicate(note));

  Future<Note> _duplicate(Note note) async {
    final ext = realExt(note.file.path);
    var dest = File(p.join(dir.path, '${note.name} copy$ext'));
    var i = 2;
    while (await dest.exists()) {
      dest = File(p.join(dir.path, '${note.name} copy $i$ext'));
      i++;
    }
    await note.file.copy(dest.path);
    final m = note.external ? null : _index[p.basename(note.file.path)];
    // With the index unreadable every note counts as locked, so the copy
    // is locked too rather than a readable copy of a locked note.
    final locked = _indexBroken || (m?.locked ?? false);
    _index.remove(p.basename(dest.path));
    if ((m != null && m.tags.isNotEmpty) || locked) {
      _index[p.basename(dest.path)] = _Meta(
        pinned: false,
        tags: List.of(m?.tags ?? const []),
        locked: locked,
      );
    }
    await _saveIndex();
    await _refresh();
    return _notes.firstWhere(
      (x) => x.file.path == dest.path,
      orElse: () => Note(file: dest, modified: DateTime.now(), size: 0),
    );
  }

  Future<void> setTags(Note note, List<String> tags) =>
      _serial(() => _setTags(note, tags));

  Future<void> _setTags(Note note, List<String> tags) async {
    if (note.external) return;
    final base = p.basename(note.file.path);
    final m = _index[base] ?? _Meta(pinned: false, tags: const []);
    _index[base] = _Meta(pinned: m.pinned, tags: tags, locked: m.locked);
    for (final t in tags) {
      if (!_allTags.contains(t)) _allTags.add(t);
    }
    await _saveIndex();
    await _refresh();
  }

  Future<void> addTag(String tag) => _serial(() => _addTag(tag));

  Future<void> _addTag(String tag) async {
    final t = tag.trim();
    if (t.isEmpty || _allTags.contains(t)) return;
    _allTags.add(t);
    await _saveIndex();
    notifyListeners();
  }

  /// Renames [from] to [to] in the tag list (same place) and on every file.
  Future<void> renameTag(String from, String to) =>
      _serial(() => _renameTag(from, to));

  Future<void> _renameTag(String from, String to) async {
    final t = to.trim();
    final i = _allTags.indexOf(from);
    if (t.isEmpty || i < 0 || t == from) return;
    if (_allTags.contains(t)) {
      _allTags.removeAt(i);
    } else {
      _allTags[i] = t;
    }
    for (final e in _index.entries.toList()) {
      if (e.value.tags.contains(from)) {
        final tags = {for (final x in e.value.tags) x == from ? t : x}.toList();
        _index[e.key] = _Meta(
          pinned: e.value.pinned,
          tags: tags,
          locked: e.value.locked,
        );
      }
    }
    await _saveIndex();
    await _refresh();
  }

  Future<void> removeTag(String tag) => _serial(() => _removeTag(tag));

  Future<void> _removeTag(String tag) async {
    _allTags.remove(tag);
    for (final e in _index.entries.toList()) {
      if (e.value.tags.contains(tag)) {
        _index[e.key] = _Meta(
          pinned: e.value.pinned,
          tags: e.value.tags.where((x) => x != tag).toList(),
          locked: e.value.locked,
        );
      }
    }
    await _saveIndex();
    await _refresh();
  }

  // -- delete / trash ----------------------------------------------------
  /// Delete a note outright (trash off, or a file outside the folder) and
  /// forget its metadata, so a later file with the same name is not born
  /// with this one's tags or lock.
  Future<void> deletePermanently(Note note) =>
      _serial(() => _deletePermanently(note));

  Future<void> _deletePermanently(Note note) async {
    try {
      await note.file.delete();
    } catch (_) {}
    if (!note.external && _index.remove(p.basename(note.file.path)) != null) {
      await _saveIndex();
    }
    await _refresh();
  }

  /// Move a folder note to the 30-day trash. External files are never
  /// trashed (they are not ours to move).
  /// Returns the trashed copy, so the move can be undone; null when there
  /// was nothing to move.
  Future<TrashedNote?> moveToTrash(Note note) =>
      _serial(() => _moveToTrash(note));

  Future<TrashedNote?> _moveToTrash(Note note) async {
    if (note.external) return null;
    final base = p.basename(note.file.path);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    // Store as `<ms>__<original name>` so the deletion time and name survive.
    final dest = File(p.join(trashDir.path, '${stamp}__$base'));
    if (!await note.file.exists()) {
      // Already gone from disk (removed by another app while the list was
      // showing it): nothing to move; drop it from the list, no error.
      if (_index.remove(base) != null) await _saveIndex();
      await _refresh();
      return null;
    }
    try {
      await note.file.rename(dest.path);
    } catch (_) {
      await note.file.copy(dest.path);
      await note.file.delete();
    }
    // Park its pin/tags/lock beside it, so a restored note comes back as it
    // left (a locked note used to come back unlocked and readable). With
    // the index unreadable it is parked as locked.
    final m = _index.remove(base);
    if (m != null || _indexBroken) {
      _index[_trashKey(p.basename(dest.path))] = _Meta(
        pinned: m?.pinned ?? false,
        tags: m?.tags ?? const [],
        locked: _indexBroken || (m?.locked ?? false),
      );
    }
    await _saveIndex();
    await _refresh();
    return TrashedNote(dest, base, DateTime.fromMillisecondsSinceEpoch(stamp));
  }

  Future<List<TrashedNote>> trash() => _serial(() => _trash());

  Future<List<TrashedNote>> _trash() async {
    final out = <TrashedNote>[];
    if (!await trashDir.exists()) return out;
    var purged = false;
    await for (final e in trashDir.list()) {
      if (e is! File) continue;
      final base = p.basename(e.path);
      final sep = base.indexOf('__');
      if (sep < 0) continue;
      final ms = int.tryParse(base.substring(0, sep));
      if (ms == null) continue;
      final deletedAt = DateTime.fromMillisecondsSinceEpoch(ms);
      // Purge anything past 30 days as we read.
      if (DateTime.now().difference(deletedAt) > const Duration(days: 30)) {
        try {
          await e.delete();
        } catch (_) {}
        purged |= _index.remove(_trashKey(base)) != null;
        continue;
      }
      out.add(TrashedNote(e, base.substring(sep + 2), deletedAt));
    }
    if (purged) await _saveIndex();
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Whether any file in the trash is locked.
  bool get anyTrashedLocked =>
      _indexBroken ||
      _index.entries.any((e) => e.key.startsWith('.trash/') && e.value.locked);

  /// Whether a trashed file was locked when it was deleted.
  bool trashedLocked(TrashedNote t) =>
      _indexBroken ||
      (_index[_trashKey(p.basename(t.file.path))]?.locked ?? false);

  Future<void> restore(TrashedNote t) => _serial(() => _restore(t));

  Future<void> _restore(TrashedNote t) async {
    var dest = File(p.join(dir.path, t.originalName));
    if (await dest.exists()) {
      final ext = realExt(t.originalName);
      final stem = t.originalName.substring(
        0,
        t.originalName.length - ext.length,
      );
      var i = 2;
      while (await File(p.join(dir.path, '$stem $i$ext')).exists()) {
        i++;
      }
      dest = File(p.join(dir.path, '$stem $i$ext'));
    }
    try {
      await t.file.rename(dest.path);
    } catch (_) {
      await t.file.copy(dest.path);
      await t.file.delete();
    }
    final m = _index.remove(_trashKey(p.basename(t.file.path)));
    _index.remove(p.basename(dest.path));
    if (m != null) _index[p.basename(dest.path)] = m;
    await _saveIndex();
    await _refresh();
  }

  Future<void> deleteForever(TrashedNote t) => _serial(() => _deleteForever(t));

  Future<void> _deleteForever(TrashedNote t) async {
    try {
      await t.file.delete();
    } catch (_) {}
    if (_index.remove(_trashKey(p.basename(t.file.path))) != null) {
      await _saveIndex();
    }
  }

  Future<void> emptyTrash() => _serial(() async {
    for (final t in await _trash()) {
      await _deleteForever(t);
    }
  });

  /// Safe file name. A LEADING dot is dropped: the list hides dot-files, so
  /// ".env" was saved as a hidden file the app could then not find (and the
  /// editor threw on every save, so back did nothing).
  static String _sanitize(String name) {
    final s = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceFirst(RegExp(r'^[.\s]+'), '')
        .trim();
    if (s.isEmpty) return 'Untitled';
    // A name over the file system's 255-byte limit failed every save (a long
    // first line in Hindi reaches it at about 85 letters): the stem is cut
    // to 200 bytes, the extension kept, leaving room for " 2", " 3", ...
    final ext = realExt(s);
    final stem = s.substring(0, s.length - ext.length);
    if (utf8.encode(stem).length <= 200) return s;
    final cut = StringBuffer();
    var bytes = 0;
    for (final r in stem.runes) {
      final n = utf8.encode(String.fromCharCode(r)).length;
      if (bytes + n > 200) break;
      bytes += n;
      cut.writeCharCode(r);
    }
    final kept = cut.toString().trim();
    return '${kept.isEmpty ? 'Untitled' : kept}$ext';
  }

  /// The extension a TYPED name carries, or ''. Only a real file type
  /// counts (or the file's own [own]): "Dr.Smith" or "Q3.Plan" typed as a
  /// title is a title, and taking ".Smith" as its type renamed
  /// "Dr.Smith.txt" to "Dr.Smith" on the next save, which then showed as "Dr".
  /// The real file type a typed title names, or '' ("Dr.Smith" names none).
  static String typedExt(String name) => _typedExt(name, '');

  static String _typedExt(String name, String own) {
    final e = realExt(name);
    if (e.isEmpty) return '';
    final l = e.toLowerCase();
    if (own.isNotEmpty && l == own.toLowerCase()) return e;
    if (_plainExts.contains(l) || codeLanguageFor(l) != null) return e;
    return '';
  }

  static const _plainExts = {
    '.txt',
    '.md',
    '.markdown',
    '.text',
    '.note',
    '.csv',
    '.tsv',
    '.rtf',
    '.docx',
    '.log',
    '.json',
    '.xml',
    '.yaml',
    '.yml',
    '.ini',
    '.env',
    '.srt',
    '.vtt',
    '.tex',
  };

  /// Write [bytes] to a hidden sibling first, then move it over [target]: a
  /// kill or full disk mid-write leaves the old note whole instead of empty.
  static Future<void> _writeSafely(File target, List<int> bytes) async {
    final tmp = File(
      p.join(p.dirname(target.path), '.${p.basename(target.path)}.saving'),
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      // A folder that refuses the sibling (another app's directory): write
      // in place as before.
      await target.writeAsBytes(bytes, flush: true);
    }
  }

  /// The extension only when it looks like one (`.txt`, `.json`, `.md`).
  /// `p.extension` calls ". Smith" in "Dr. Smith" an extension, so a dotted
  /// title got no `.txt`, showed as "Dr", and never stopped looking unsaved.
  static String realExt(String name) {
    final e = p.extension(name);
    // At least one letter: "Version 1.5" is a title, not a ".5" file.
    return RegExp(r'^\.(?=[^.]*[A-Za-z])[A-Za-z0-9]{1,8}$').hasMatch(e)
        ? e
        : '';
  }
}

/// A note's text as Breeze shows and edits it.
class NoteText {
  const NoteText(this.text, this.charset, this.rtf);
  final String text;

  /// The encoding the file was read in.
  final String charset;

  /// Set when the file is an RTF document ([text] is then its formatted
  /// text, not the file's bytes).
  final RtfRead? rtf;
}

class _Meta {
  _Meta({required this.pinned, required this.tags, this.locked = false});
  final bool pinned;
  final List<String> tags;
  final bool locked;
}

/// Bytes as text, and the encoding they were in: UTF-16 by its byte-order
/// mark, else strict UTF-8, else Latin-1 (which takes any bytes, so a binary
/// or legacy file still opens). Same rules as Android's reader.
(String, String) decodeText(List<int> bytes) {
  // An odd byte count is not UTF-16 whatever its first two bytes say:
  // read that way its last byte would be lost on save.
  if (bytes.length >= 2 && bytes.length.isEven) {
    final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
    final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
    if (le || be) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(
          le ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
        );
      }
      return (String.fromCharCodes(units), le ? 'UTF-16LE' : 'UTF-16BE');
    }
  }
  try {
    // A UTF-8 byte-order mark is kept as the text's first character, as
    // Android's reader does, so it is written back on save (Excel needs it
    // to read a CSV's accents) and both readers agree on the text.
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    final body = utf8.decode(bom ? bytes.sublist(3) : bytes);
    return (bom ? '﻿$body' : body, 'UTF-8');
  } on FormatException {
    // A Windows file (curly quotes, euro sign, dashes in 0x80-0x9F) is read
    // as Windows-1252, so those show as themselves and survive a save.
    // Bytes Windows-1252 leaves undefined mean it is not one: Latin-1, which
    // keeps any byte as it is.
    if (_isCp1252(bytes)) {
      return (String.fromCharCodes(bytes.map(_cp1252Char)), 'windows-1252');
    }
    return (latin1.decode(bytes), 'ISO-8859-1');
  }
}

/// Windows-1252's characters for bytes 0x80-0x9F; 0 where it has none.
const _cp1252High = <int>[
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0, //
  0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178, //
];

bool _isCp1252(List<int> bytes) {
  var high = false;
  for (final b in bytes) {
    if (b >= 0x80 && b <= 0x9F) {
      if (_cp1252High[b - 0x80] == 0) return false;
      high = true;
    }
  }
  return high;
}

int _cp1252Char(int b) => b >= 0x80 && b <= 0x9F ? _cp1252High[b - 0x80] : b;

/// [text] as Windows-1252 bytes, or null when it holds a character that
/// code page has no byte for.
Uint8List? _toCp1252(String text) {
  final out = Uint8List(text.length);
  var i = 0;
  for (final c in text.codeUnits) {
    if (c < 0x80 || (c >= 0xA0 && c <= 0xFF)) {
      out[i++] = c;
      continue;
    }
    final at = _cp1252High.indexOf(c);
    if (at < 0 || c == 0) return null;
    out[i++] = 0x80 + at;
  }
  return out;
}

/// [text] in [charset], with UTF-16's byte-order mark. Text Latin-1 cannot
/// hold (an emoji, a euro sign) is saved as UTF-8 rather than lost as '?'.
Uint8List encodeText(String text, String charset) {
  switch (charset) {
    case 'windows-1252':
      // Typed text it cannot hold (an emoji): the whole file goes UTF-8,
      // from real characters, so its quotes and euro signs stay right.
      final b = _toCp1252(text);
      if (b != null) return b;
    case 'ISO-8859-1':
      if (text.codeUnits.every((c) => c <= 0xFF)) {
        return Uint8List.fromList(latin1.encode(text));
      }
    case 'UTF-16LE':
    case 'UTF-16BE':
      final le = charset == 'UTF-16LE';
      final out = Uint8List(2 + text.length * 2);
      out[0] = le ? 0xFF : 0xFE;
      out[1] = le ? 0xFE : 0xFF;
      var i = 2;
      for (final u in text.codeUnits) {
        out[i++] = le ? u & 0xFF : u >> 8;
        out[i++] = le ? u >> 8 : u & 0xFF;
      }
      return out;
  }
  return Uint8List.fromList(utf8.encode(text));
}
