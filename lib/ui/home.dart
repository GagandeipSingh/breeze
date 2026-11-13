import 'dart:ui' show BoxWidthStyle;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'glass_chrome.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/note_scope.dart';
import '../data/note_store.dart';
import '../data/recent_files.dart';
import '../logic/binary_text.dart';
import '../logic/code_highlight.dart';
import '../logic/markdown_lite.dart';
import '../logic/pdf_export.dart';
import '../logic/docx.dart';
import '../logic/list_text.dart';
import '../logic/rtf.dart';
import '../logic/text_stats.dart';
import '../state/settings.dart';
import 'editor.dart';
import 'file_look.dart';
import 'new_file_sheet.dart';
import 'recent_list.dart';
import 'recent_sheet.dart' show showFileInFiles;
import 'glass_surface.dart';
import 'kit.dart';
import 'lock_gate.dart';
import 'scale.dart';
import 'settings_screen.dart';
import 'sheets.dart';
import 'trash_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// Coming back to the app re-reads the folder: "Save to Breeze" in another
  /// app writes files while Breeze is in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      NoteScope.of(context).refresh();
    }
  }

  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _searchInside = false;

  /// Search lives behind a button at the right of the tag row; open, the
  /// field takes the row's place.
  bool _searchOpen = false;

  /// Recent mode: the list shows files opened from the phone instead of
  /// Breeze's own. The clock in the header switches it on and off.
  bool _recentMode = false;

  /// Pinned mode: only the pinned files. The pin in the header switches it.
  bool _pinnedMode = false;
  RecentFiles? _recentFiles;
  String? _tag; // null = All
  bool _fabOpen = false;

  // Multi-select for sharing / zipping.
  bool _selecting = false;
  final Set<String> _selected = {};

  /// Cache of paths whose contents match the current inside-search query.
  Set<String>? _contentMatches;
  int _contentToken = 0;

  static const _openChannel = MethodChannel('breeze/open');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text;
      if (q != _query) {
        setState(() => _query = q);
        // Content search reads every file; wait for a pause in typing.
        _searchDebounce?.cancel();
        _searchDebounce = Timer(
          const Duration(milliseconds: 250),
          _recomputeContentMatches,
        );
      }
    });
    // A file tapped in another app (e.g. a .json) launches us; open it.
    _openChannel.setMethodCallHandler((call) async {
      if (call.method == 'openFile') {
        await _openArrived((call.arguments as Map).cast<String, dynamic>());
      }
      return null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final m = await _openChannel.invokeMapMethod<String, dynamic>(
        'getOpenedFile',
      );
      if (m != null) await _openArrived(m);
    });
  }

  /// A file handed over by Android: one tapped or shared in another app, or
  /// one picked in "Open file" whose answer came back after Android had
  /// restarted Breeze (it carries its uri, so it opens as a picked file).
  Future<void> _openArrived(Map<String, dynamic> m) async {
    final uri = m['uri'] as String?;
    if (uri == null) {
      await _openIncoming(
        m['name'] as String?,
        m['content'] as String?,
        m['charset'] as String?,
        m['copy'] == '1',
      );
      return;
    }
    if (!mounted) return;
    final store = NoteScope.of(context);
    final Note note;
    try {
      final name = (m['name'] as String?) ?? 'Untitled.txt';
      note = await store.openDocument(
        uri,
        name,
        (m['content'] as String?) ?? '',
        charset: (m['charset'] as String?) ?? 'UTF-8',
      );
      // Only a file Breeze can write back to arrives with its uri, and
      // that is one it can open again later.
      await _remember(uri, name);
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not open that file',
          icon: CupertinoIcons.doc,
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EditorScreen(note: note)));
  }

  Future<void> _openIncoming(
    String? name,
    String? content, [
    String? charset,
    bool readOnlyOrigin = false,
  ]) async {
    if (content == null || !mounted) return;
    final store = NoteScope.of(context);
    final Note note;
    try {
      // A binary file (a photo, an app, a zip) is shown, never saved in.
      // A Word file is a zip by design, and is read as one.
      final shown = name ?? 'File';
      if (!NoteStore.isDocx(shown) && looksBinary(content)) {
        note = await store.openViewOnly(shown, content);
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => EditorScreen(note: note)));
        return;
      }
      note = await store.openIncoming(
        name ?? 'Untitled.txt',
        content,
        charset: charset,
      );
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not open that file',
          icon: CupertinoIcons.doc,
        );
      }
      return;
    }
    if (!mounted) return;
    // Tapped in an app that only lets Breeze read it (Telegram, WhatsApp,
    // Gmail): edits go to Breeze's copy, never back there.
    await _openEditor(
      note,
      notice: readOnlyOrigin
          ? "Opened as a copy in Breeze. The original doesn't change."
          : null,
    );
  }

  Timer? _searchDebounce;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _recomputeContentMatches() async {
    if (!mounted) return;
    if (!_searchInside || _query.trim().isEmpty) {
      // Bump the token too, so a scan still running cannot re-apply its
      // matches after the box was unchecked.
      _contentToken++;
      setState(() => _contentMatches = null);
      return;
    }
    final token = ++_contentToken;
    final store = NoteScope.of(context);
    final lockAll = SettingsScope.of(context).lockFiles;
    final q = _query.toLowerCase();
    // A locked file is never searched: which locked note stays in the list
    // while you type would spell its contents out.
    final paths = [
      for (final n in store.notes)
        if (!lockAll && !n.locked) n.path,
    ];
    // Off the UI thread: reading and lowercasing every note (up to 20 MB
    // each) after each pause in typing dropped frames under the keyboard.
    final matches = await compute(_searchFiles, (paths, q));
    if (token == _contentToken && mounted) {
      setState(() => _contentMatches = matches);
    }
  }

  List<Note> _visible(NoteStore store, Settings s) {
    var list = List<Note>.from(store.notes);
    if (_pinnedMode) list = list.where((n) => n.pinned).toList();
    final tag = _pinnedMode ? null : _activeTag(store, s);
    if (tag != null) {
      list = list.where((n) => n.tags.contains(tag)).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((n) {
        final nameHit = n.fullName.toLowerCase().contains(q);
        // Checked against the lock NOW: a note locked after the scan
        // must not stay in the results (that would say what it contains).
        final contentHit =
            !s.lockFiles &&
            !n.locked &&
            (_contentMatches?.contains(n.path) ?? false);
        return nameHit || contentHit;
      }).toList();
    }
    int cmp(Note a, Note b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final r = s.sortBy == SortBy.name
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : a.modified.compareTo(b.modified);
      return s.sortAscending ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  /// The tag filter in force: none while Tags are switched off in Settings
  /// (the chips are hidden, so it could not be cleared) or once the tag is
  /// gone.
  String? _activeTag(NoteStore store, Settings s) =>
      s.tagsEnabled && _tag != null && store.allTags.contains(_tag)
      ? _tag
      : null;

  /// Selected notes that still exist. A file renamed or deleted from its menu
  /// while selecting leaves a path behind that names nothing.
  List<Note> _selectedNotes(NoteStore store) =>
      store.notes.where((n) => _selected.contains(n.path)).toList();

  /// Asks for the fingerprint before a locked file leaves the app or shows
  /// its counts. True when nothing in [notes] is locked.
  Future<bool> _passLock(List<Note> notes, String reason) async {
    final lockAll = SettingsScope.of(context).lockFiles;
    if (!notes.any((n) => lockAll || n.locked)) return true;
    return authenticate(context, reason);
  }

  bool _anyLocked(NoteStore store) =>
      SettingsScope.of(context).lockFiles ||
      store.notes.any((n) => n.locked) ||
      store.anyTrashedLocked;

  void _enterSelect(Note n) {
    setState(() {
      _selecting = true;
      _fabOpen = false;
      _selected
        ..clear()
        ..add(n.path);
    });
  }

  void _toggleSelect(Note n) {
    setState(() {
      if (_selected.contains(n.path)) {
        _selected.remove(n.path);
      } else {
        _selected.add(n.path);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelect() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  /// The selected files that have something in them: apps such as
  /// Telegram refuse an empty file ("Unsupported attachment").
  List<XFile> _selectedFiles(NoteStore store) => [
    for (final n in _selectedNotes(store))
      if (n.size > 0) _shareFile(n),
  ];

  void _emptyToast(String what) => showToast(
    context,
    message: '$what empty. Add some text first.',
    icon: CupertinoIcons.doc,
  );

  /// A file to share, with its type said outright. Left to guess, Android
  /// calls a .kt or .toml file "unknown", and some apps then refuse it.
  XFile _shareFile(Note n) =>
      XFile(n.path, mimeType: shareMime(n.ext), name: n.fullName);

  /// Asks how to send the selection: as the files themselves or as PDFs,
  /// each separately or all in one ZIP. One file is asked only file or PDF.
  Future<void> _shareChoice() async {
    final store = NoteScope.of(context);
    final chosen = _selectedNotes(store);
    if (chosen.isEmpty) return;
    if (!await _passLock(chosen, 'Share locked files')) return;
    if (!mounted) return;
    final choice = await showShareFormat(context, count: chosen.length);
    switch (choice) {
      case 'files':
        await _shareSelected();
      case 'zip':
        await _zipAndShare();
      case 'pdfs':
        await _sharePdfs(chosen, zip: false);
      case 'pdfzip':
        await _sharePdfs(chosen, zip: true);
    }
  }

  /// Sends [notes] as PDFs, separately or in one ZIP. Built one at a time,
  /// each off the main thread, so a long batch never freezes the screen.
  Future<void> _sharePdfs(List<Note> notes, {required bool zip}) async {
    final store = NoteScope.of(context);
    final formatted = SettingsScope.of(context).formatting;
    final colours = SettingsScope.of(context).codeColours;
    showToast(
      context,
      message: notes.length == 1
          ? 'Making the PDF…'
          : 'Making ${notes.length} PDFs…',
      icon: CupertinoIcons.doc_richtext,
    );
    try {
      final tmp = await getTemporaryDirectory();
      // Its own folder per run. Runs over an hour old are cleared; a newer
      // one may still be building, or its share sheet still reading.
      final root = Directory(p.join(tmp.path, 'pdf_share'));
      if (await root.exists()) {
        final old = DateTime.now().subtract(const Duration(hours: 1));
        await for (final e in root.list()) {
          try {
            if ((await e.stat()).modified.isBefore(old)) {
              await e.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
      final dir = Directory(
        p.join(root.path, '${DateTime.now().microsecondsSinceEpoch}'),
      );
      await dir.create(recursive: true);
      final used = <String>{};
      final files = <File>[];
      var failed = 0;
      for (final n in notes) {
        final Uint8List bytes;
        try {
          final text = await store.read(n);
          bytes = await buildNotePdf(
            n.name,
            text,
            formatted: formatted && mdFormattable(n.ext),
            escapes: const {'.rtf', '.docx'}.contains(n.ext.toLowerCase()),
            codeLanguage: codeLanguageFor(n.ext),
            colours: colours,
          );
        } catch (_) {
          // One unreadable note does not sink the rest.
          failed++;
          continue;
        }
        // "notes.txt" and "notes.md" would both be "notes.pdf".
        var name = '${n.name}.pdf';
        var i = 2;
        while (!used.add(name.toLowerCase())) {
          name = '${n.name} ${i++}.pdf';
        }
        final f = File(p.join(dir.path, name));
        await f.writeAsBytes(bytes, flush: true);
        files.add(f);
      }
      if (!mounted) return;
      if (files.isEmpty) throw StateError('no PDFs');
      if (failed > 0) {
        showToast(
          context,
          message: failed == 1
              ? '1 file could not be made a PDF'
              : '$failed files could not be made PDFs',
          icon: CupertinoIcons.doc_richtext,
        );
      }
      if (zip) {
        final zipPath = p.join(dir.path, 'Breeze PDFs.zip');
        final enc = ZipFileEncoder();
        enc.create(zipPath);
        // addFile is asynchronous: closing without waiting wrote an EMPTY zip.
        for (final f in files) {
          await enc.addFile(f, p.basename(f.path));
        }
        await enc.close();
        await SharePlus.instance.share(ShareParams(files: [XFile(zipPath)]));
      } else {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              for (final f in files) XFile(f.path, mimeType: 'application/pdf'),
            ],
          ),
        );
      }
      if (mounted) _exitSelect();
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not make the PDF',
          icon: CupertinoIcons.doc_richtext,
        );
      }
    }
  }

  Future<void> _shareSelected() async {
    final store = NoteScope.of(context);
    final files = _selectedFiles(store);
    if (files.isEmpty) {
      if (_selected.isNotEmpty) {
        _emptyToast(_selected.length == 1 ? 'This file is' : 'These files are');
      }
      return;
    }
    await SharePlus.instance.share(ShareParams(files: files));
    if (mounted) _exitSelect();
  }

  Future<void> _zipAndShare() async {
    final store = NoteScope.of(context);
    final notes = _selectedNotes(store);
    if (notes.isEmpty) return;
    try {
      final tmp = await getTemporaryDirectory();
      final zipPath = p.join(
        tmp.path,
        'Breeze_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final enc = ZipFileEncoder();
      enc.create(zipPath);
      for (final n in notes) {
        await enc.addFile(n.file, n.fullName);
      }
      await enc.close();
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(zipPath)]));
      if (mounted) _exitSelect();
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not create ZIP',
          icon: CupertinoIcons.archivebox,
        );
      }
    }
  }

  Future<void> _openNote(Note n) async {
    final s = SettingsScope.of(context);
    if (s.lockFiles && n.ext == '.txt') {
      // Fingerprint gate handled inside the editor's unlock; kept simple here.
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EditorScreen(note: n)));
    if (mounted) _recomputeContentMatches();
  }

  Future<void> _newNote() async {
    setState(() => _fabOpen = false);
    final settings = SettingsScope.of(context);
    // What it is decides its real format and the toolbar it gets.
    final ext = await showNewFileKind(context, last: settings.newFileExt);
    if (ext == null || !mounted) return;
    settings.newFileExt = ext;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          note: null,
          tag: _activeTag(NoteScope.of(context), settings),
          newExt: ext,
        ),
      ),
    );
  }

  Future<RecentFiles>? _recentLoad;
  Future<RecentFiles> get _recent => _recentLoad ??= RecentFiles.load();

  /// Files opened from elsewhere are remembered for "Open file"; the ones
  /// pushed off the end give back their lasting access.
  Future<void> _remember(String uri, String name) async {
    try {
      final r = await _recent;
      for (final gone in await r.add(uri, name)) {
        await _forgetAccess(gone.uri);
      }
    } catch (_) {}
  }

  Future<void> _forgetAccess(String uri) async {
    try {
      await _openChannel.invokeMethod('forgetUri', {'uri': uri});
    } catch (_) {}
  }

  /// The clock: the list switches to recently opened files, and back.
  Future<void> _toggleRecent() async {
    HapticFeedback.selectionClick();
    if (_recentMode) {
      setState(() => _recentMode = false);
      return;
    }
    RecentFiles? r;
    try {
      r = await _recent;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _recentFiles = r;
      _recentMode = true;
      _pinnedMode = false;
      _fabOpen = false;
      _searchOpen = false;
      _searchInside = false;
      _searchCtrl.clear();
      // A selection is of Breeze's files; it does not carry into Recent.
      _selecting = false;
      _selected.clear();
    });
  }

  /// The pin: the list shows only pinned files, and back.
  void _togglePinned() {
    HapticFeedback.selectionClick();
    setState(() {
      _pinnedMode = !_pinnedMode;
      if (_pinnedMode) {
        _recentMode = false;
        _fabOpen = false;
      }
    });
  }

  Future<void> _removeRecent(RecentFile f) async {
    final r = _recentFiles;
    if (r == null) return;
    await r.remove(f.uri);
    await _forgetAccess(f.uri);
    if (mounted) setState(() {});
  }

  Future<void> _clearRecent() async {
    final r = _recentFiles;
    if (r == null) return;
    final all = r.items;
    await r.clear();
    for (final f in all) {
      await _forgetAccess(f.uri);
    }
    if (mounted) setState(() {});
  }

  Future<void> _browse() async {
    if (_fabOpen) setState(() => _fabOpen = false);
    final store = NoteScope.of(context);
    final Note note;
    String? notice;
    try {
      final m = await _openChannel.invokeMapMethod<String, dynamic>(
        'pickDocument',
      );
      if (m == null || !mounted) return; // picker cancelled
      final name = (m['name'] as String?) ?? 'Untitled.txt';
      // Read-only where it lives: opened as a copy in Breeze, since every
      // save back there would fail.
      final content = (m['content'] as String?) ?? '';
      if (m['writable'] == false &&
          !NoteStore.isDocx(name) &&
          looksBinary(content)) {
        // A photo or other binary is only shown, never copied in as a note.
        note = await store.openViewOnly(name, content);
      } else if (m['writable'] == false) {
        note = await store.openIncoming(
          name,
          content,
          charset: m['charset'] as String?,
        );
        notice = "Opened as a copy: that app doesn't let Breeze save there";
      } else {
        note = await store.openDocument(
          m['uri'] as String,
          name,
          (m['content'] as String?) ?? '',
          charset: (m['charset'] as String?) ?? 'UTF-8',
        );
        await _remember(m['uri'] as String, name);
      }
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not open that file (too large or unreadable)',
          icon: CupertinoIcons.doc,
        );
      }
      return;
    }
    if (!mounted) return;
    await _openEditor(note, notice: notice);
  }

  /// Opens [note] in the editor; [notice] is shown over it once it is up
  /// (shown before, the editor would cover it).
  Future<void> _openEditor(Note note, {String? notice}) {
    final route = Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EditorScreen(note: note)));
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showToast(context, message: notice, icon: CupertinoIcons.doc_on_doc);
        }
      });
    }
    return route;
  }

  /// A recent file, read again from where it lives. One that has been
  /// moved, deleted or whose access was taken back leaves the list.
  Future<void> _openRecent(RecentFiles r, RecentFile f) async {
    final store = NoteScope.of(context);
    final Note note;
    try {
      final m = await _openChannel.invokeMapMethod<String, dynamic>('readUri', {
        'uri': f.uri,
      });
      if (m == null) throw StateError('gone');
      final name = (m['name'] as String?) ?? f.name;
      note = await store.openDocument(
        f.uri,
        name,
        (m['content'] as String?) ?? '',
        charset: (m['charset'] as String?) ?? 'UTF-8',
      );
      await _remember(f.uri, name);
    } on PlatformException catch (e) {
      final tooBig = e.message == 'too large';
      // Only a file that is truly gone leaves Recent; a read that failed
      // for another reason (offline cloud file, busy app) is kept.
      final gone = !tooBig && e.code == 'gone';
      if (gone) {
        await r.remove(f.uri);
        await _forgetAccess(f.uri);
      }
      if (mounted) {
        showToast(
          context,
          message: tooBig
              ? '${f.name} is too large to open (over 20 MB)'
              : gone
              ? "Can't open ${f.name} any more. It may have been moved or "
                    'deleted. Use Browse files to find it.'
              : "Couldn't open ${f.name} right now. Try again.",
          icon: CupertinoIcons.exclamationmark_circle,
          duration: const Duration(seconds: 3),
        );
      }
      return;
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not open ${f.name}',
          icon: CupertinoIcons.exclamationmark_circle,
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EditorScreen(note: note)));
  }

  Future<void> _addTag() async {
    final store = NoteScope.of(context);
    final name = await promptText(
      context,
      title: 'Add tag',
      label: 'Tag name',
      confirmLabel: 'Add',
      caps: TextCapitalization.words,
    );
    if (name == null || name.trim().isEmpty) return;
    final t = name.trim();
    final same = store.allTags.where((x) => x.toLowerCase() == t.toLowerCase());
    if (same.isNotEmpty) {
      if (mounted) {
        showToast(
          context,
          message: 'Tag "${same.first}" already exists',
          icon: CupertinoIcons.tag,
        );
      }
      return;
    }
    await store.addTag(t);
  }

  /// The icon for each layout, so the bar shows the one in use.
  static IconData _layoutIcon(ListLayout l) => switch (l) {
    ListLayout.compact => CupertinoIcons.list_bullet,
    ListLayout.standard => CupertinoIcons.square_list,
    ListLayout.detailed => CupertinoIcons.text_alignleft,
    ListLayout.grid => CupertinoIcons.square_grid_2x2,
  };

  /// Pick how the list is drawn, right from Home (also in Settings > Look).
  void _viewMenu() async {
    final s = SettingsScope.of(context);
    const names = {
      ListLayout.compact: 'Compact',
      ListLayout.standard: 'Standard',
      ListLayout.detailed: 'Detailed',
      ListLayout.grid: 'Grid',
    };
    final choice = await showChoiceTiles<ListLayout>(
      context,
      title: 'View',
      selected: s.listLayout,
      options: [
        for (final l in ListLayout.values) (l, _layoutIcon(l), names[l]!),
      ],
    );
    if (choice != null) s.listLayout = choice;
  }

  /// Sort: the four orders people actually want, as one short list. A tap
  /// applies it and closes; the current one carries a tick.
  void _sortMenu() async {
    final s = SettingsScope.of(context);
    const options = [
      (SortBy.date, false, CupertinoIcons.clock, 'Newest first'),
      (SortBy.date, true, CupertinoIcons.clock, 'Oldest first'),
      (SortBy.name, true, CupertinoIcons.textformat, 'Name, A to Z'),
      (SortBy.name, false, CupertinoIcons.textformat, 'Name, Z to A'),
    ];
    final pick = await showGlassSheet<int>(
      context,
      builder: (ctx) {
        final p = Pal.of(ctx);
        return Padding(
          padding: EdgeInsets.fromLTRB(12.dp, 6.dp, 12.dp, 14.dp),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(8.dp, 6.dp, 8.dp, 10.dp),
                child: Text(
                  'Sort by',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 20.sp,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              for (final (i, o) in options.indexed)
                Builder(
                  builder: (_) {
                    final on = s.sortBy == o.$1 && s.sortAscending == o.$2;
                    return Semantics(
                      button: true,
                      selected: on,
                      label: o.$4,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          Navigator.of(ctx).pop(i);
                        },
                        child: Container(
                          height: 52.dp,
                          margin: EdgeInsets.only(top: 2.dp),
                          padding: EdgeInsets.symmetric(horizontal: 10.dp),
                          decoration: BoxDecoration(
                            color: on
                                ? p.accent.withValues(
                                    alpha: p.dark ? 0.16 : 0.10,
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(14.dp),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                o.$3,
                                size: 20.dp,
                                color: on ? p.accent : p.sub,
                              ),
                              SizedBox(width: 14.dp),
                              Expanded(
                                child: Text(
                                  o.$4,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: on ? p.accent : p.ink,
                                    fontSize: 15.5.sp,
                                    fontWeight: on
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (on)
                                Icon(
                                  CupertinoIcons.checkmark_alt,
                                  size: 20.dp,
                                  color: p.accent,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
    if (pick == null) return;
    s.sortBy = options[pick].$1;
    s.sortAscending = options[pick].$2;
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    // Drop selected paths that no longer name a file (renamed or deleted
    // from the menu mid-selection), so the count and actions stay true.
    final notes = _visible(store, s);
    // Only files on screen stay selected: a file hidden by the pin filter, a
    // tag or a search must never be deleted or shared unseen.
    _selected.removeWhere(
      (path) => _recentMode || !notes.any((n) => n.path == path),
    );
    if (_selecting && _selected.isEmpty) _selecting = false;

    // Back steps out of whatever is open — selection, the + menu, search —
    // before it is allowed to leave the app.
    final busy =
        _selecting || _fabOpen || _searchOpen || _recentMode || _pinnedMode;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newNote,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newNote,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (!_searchOpen) setState(() => _searchOpen = true);
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          if (!_searchOpen) setState(() => _searchOpen = true);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchOpen) {
            _searchCtrl.clear();
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() {
              _searchOpen = false;
              _searchInside = false;
            });
          } else if (_selecting) {
            _exitSelect();
          } else if (_fabOpen) {
            setState(() => _fabOpen = false);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelect();
        } else if (_fabOpen) {
          setState(() => _fabOpen = false);
        } else if (_recentMode && !_searchOpen) {
          setState(() => _recentMode = false);
        } else if (_pinnedMode && !_searchOpen) {
          setState(() => _pinnedMode = false);
        } else if (_searchOpen) {
          _searchCtrl.clear();
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() {
            _searchOpen = false;
            _searchInside = false;
          });
        }
      },
      child: GlassScaffold(
        background: const GradientBackground(),
        statusBarStyle: p.dark
            ? GlassStatusBarStyle.light
            : GlassStatusBarStyle.dark,
        body: Listener(
          onPointerDown: (_) {
            FocusManager.instance.primaryFocus?.unfocus();
          },
          child: Stack(
            children: [
              Column(
                children: [
                  SizedBox(height: MediaQuery.paddingOf(context).top + 10.dp),
                  _header(p, s, store),
                  Expanded(
                    child: store.loading
                        ? const SizedBox.shrink()
                        : _recentMode
                        ? RecentList(
                            items: _recentFiles?.items ?? const [],
                            query: _searchOpen ? _query.trim() : '',
                            onOpen: (f) async {
                              final r = _recentFiles;
                              if (r == null) return;
                              await _openRecent(r, f);
                              if (mounted) setState(() {});
                            },
                            onBrowse: () async {
                              await _browse();
                              if (mounted) setState(() {});
                            },
                            onRemove: _removeRecent,
                          )
                        : notes.isEmpty
                        ? _empty(p)
                        : AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeOutCubic,
                            child: KeyedSubtree(
                              key: ValueKey(s.listLayout),
                              child: _fileList(notes, s.listLayout),
                            ),
                          ),
                  ),
                ],
              ),
              // Tap-away scrim: closes the speed-dial without stealing the taps on
              // the menu buttons themselves (which sit above it in the stack).
              if (_fabOpen)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _fabOpen = false),
                  ),
                ),
              if (_selecting)
                _selectBar(p)
              // While typing a search the keyboard is up: the bar and the
              // + would float over the results being looked for.
              else if (MediaQuery.viewInsetsOf(context).bottom == 0)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 1200.dp),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _bottomBar(p),
                        _fab(p),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    )));
  }

  /// When the files first showed after launch: tiles built in the next
  /// moment play the entrance, later ones (scrolling, filtering) do not.
  DateTime? _introAt;

  /// Every file path at the last list build; null before the first.
  Set<String>? _shownPaths;
  bool get _introOn =>
      _introAt == null ||
      DateTime.now().difference(_introAt!) < const Duration(milliseconds: 4000);

  /// The files, in the layout picked in Settings > Look > File list.
  Widget _fileList(List<Note> notes, ListLayout layout) {
    final swipe = SettingsScope.of(context).swipeDelete;
    if (notes.isNotEmpty) _introAt ??= DateTime.now();
    final intro = _introOn;
    // A file that was not in the folder at the last build (new, imported,
    // restored) eases in, so the eye finds where it landed. Measured against
    // the whole folder, not the filtered list, so clearing a search does not
    // replay it.
    final all = NoteScope.of(context).notes.map((n) => n.path).toSet();
    final before = _shownPaths;
    _shownPaths = all;
    bool fresh(Note n) => !intro && before != null && !before.contains(n.path);
    Widget place(int i, Note n, Widget child) => KeyedSubtree(
      key: ValueKey('tile:${n.path}'),
      child: _FreshIn(
        play: fresh(n),
        child: _EntranceIn(index: i, play: intro, child: child),
      ),
    );
    Widget tile(Note n) {
      final t = _NoteTile(
        note: n,
        layout: layout,
        query: _query.trim(),
        selecting: _selecting,
        selected: _selected.contains(n.path),
        onTap: () => _selecting ? _toggleSelect(n) : _openNote(n),
        onLong: () => _enterSelect(n),
        onMenu: () => _tileMenu(n),
        h24: MediaQuery.alwaysUse24HourFormatOf(context),
      );
      // Settings > Feel > Delete by swiping. Swiping asks the same question
      // as the menu's Delete and never removes the tile itself: the list
      // drops it once the file is really gone, so Cancel just slides it back.
      if (!swipe || _selecting || layout == ListLayout.grid) return t;
      return Dismissible(
        key: ValueKey('swipe:${n.path}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) async {
          await _deleteNote(n);
          return false;
        },
        background: Container(
          alignment: Alignment.centerRight,
          padding: EdgeInsets.only(right: 24.dp),
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(20.dp),
          ),
          child: Icon(CupertinoIcons.trash, color: Colors.white, size: 22.dp),
        ),
        child: t,
      );
    }

    final pad = EdgeInsets.fromLTRB(16, 4.dp, 16, 120.dp);
    if (layout == ListLayout.grid) {
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1200.dp),
          child: Scrollbar(
            child: GridView.builder(
              padding: pad,
              // Two across on a phone, more where the screen is wider.
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 260.dp,
                mainAxisSpacing: 10.dp,
                crossAxisSpacing: 10.dp,
                mainAxisExtent: 196.dp,
              ),
              itemCount: notes.length,
              itemBuilder: (c, i) => place(i, notes[i], tile(notes[i])),
            ),
          ),
        ),
      );
    }
    final gap = layout == ListLayout.compact ? 6.dp : 10.dp;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: Scrollbar(
          child: ListView.builder(
            padding: pad,
            itemCount: notes.length,
            itemBuilder: (c, i) => Padding(
              padding: EdgeInsets.only(bottom: gap),
              child: place(i, notes[i], tile(notes[i])),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectBar(Pal p) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 14.dp,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760.dp),
          child: GlassSurface(
            radius: 24.dp,
            thick: true,
            padding: EdgeInsets.symmetric(horizontal: 8.dp, vertical: 6.dp),
            child: Row(
          children: [
            GlassPress(
              onTap: _exitSelect,
              label: 'Cancel',
              child: Padding(
                padding: EdgeInsets.all(10.dp),
                child: Icon(CupertinoIcons.xmark, size: 20.dp, color: p.ink),
              ),
            ),
            SizedBox(width: 6.dp),
            Text(
              '${_selected.length} selected',
              style: TextStyle(
                color: p.ink,
                fontSize: 14.5.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            GlassPress(
              onTap: _selected.isEmpty ? () {} : _deleteSelected,
              label: 'Delete',
              child: Padding(
                padding: EdgeInsets.all(10.dp),
                child: Icon(
                  CupertinoIcons.trash,
                  size: 21.dp,
                  color: const Color(0xFFE5484D),
                ),
              ),
            ),
            SizedBox(width: 2.dp),
            // One labelled button that asks HOW to send. A bare box icon for
            // "ZIP" read as archive/hide, so nobody knew zipping existed.
            GlassPress(
              onTap: _selected.isEmpty ? () {} : _shareChoice,
              label: 'Share',
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 12.dp,
                  vertical: 10.dp,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.share, size: 20.dp, color: p.accent),
                    SizedBox(width: 6.dp),
                    Text(
                      'Share',
                      style: TextStyle(
                        color: p.accent,
                        fontSize: 14.5.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);
  }

  Widget _header(Pal p, Settings s, NoteStore store) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1200.dp),
        child: Padding(
          // The cards' own edges: the mark lines up over the card text's
          // badges and the pill ends where the cards end.
          padding: EdgeInsets.fromLTRB(16, 6.dp, 16, 6.dp),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The app icon's own wind lines, tinted to the accent, then the
              // name: the same mark as on the launcher, so the two read as one.
              // One fixed height, so the name and the pill share a centre line.
              SizedBox(
                height: 40.dp,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: 6.dp),
                    Image.asset(
                      'assets/icon/mark.png',
                      height: 19.dp,
                      // Ink, not accent: white on dark, near-black on light, so
                      // the name reads as the app's own, not as a link.
                      color: p.ink,
                      colorBlendMode: BlendMode.srcIn,
                      semanticLabel: 'Breeze',
                    ),
                    SizedBox(width: 10.dp),
                    Expanded(
                      child: Text(
                        'Breeze',
                        style: TextStyle(
                          color: p.ink,
                          fontSize: 21.sp,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    // Down a touch: a name's letters sit low in their line, so a
                    // pill centred on the line box reads as riding high.
                    if (!_searchOpen)
                      Transform.translate(
                        offset: Offset(0, 3.dp),
                        child: _findPill(p, store),
                      ),
                  ],
                ),
              ),
              if (_searchOpen) ...[
                // The field is 10dp taller than the chip row, so 5dp less gap
                // keeps its centre on the chips' line and it does not drop.
                SizedBox(height: 11.dp),
                _searchField(p),
              ] else if (_recentMode) ...[
                SizedBox(height: 16.dp),
                SizedBox(height: 34.dp, child: _recentBar(p)),
              ] else if (_pinnedMode) ...[
                SizedBox(height: 16.dp),
                SizedBox(height: 34.dp, child: _modeTitle(p, 'Pinned')),
              ] else if (s.tagsEnabled) ...[
                SizedBox(height: 16.dp),
                SizedBox(height: 34.dp, child: _tagRow(p, store)),
              ],
              if (_searchOpen && _query.isNotEmpty && !_recentMode) ...[
                SizedBox(height: 12.dp),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _searchInside = !_searchInside);
                    _recomputeContentMatches();
                  },
                  // Inset to line up with the search icon inside the field.
                  child: Padding(
                    padding: EdgeInsets.only(left: 8.dp),
                    child: Row(
                      children: [
                        Icon(
                          _searchInside
                              ? CupertinoIcons.checkmark_square_fill
                              : CupertinoIcons.square,
                          size: 18.dp,
                          color: _searchInside ? p.accent : p.sub,
                        ),
                        SizedBox(width: 8.dp),
                        Text(
                          'Include file contents',
                          style: TextStyle(color: p.ink, fontSize: 13.5.sp),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              SizedBox(height: 12.dp),
            ],
          ),
        ),
      ),
    );
  }

  /// The tag chips, with the search button pinned to the right edge. With
  /// tags off the row still holds the button, alone on the right.
  /// Recent and Search in one glass pill, like the bar at the bottom:
  /// tools for finding a file, kept off the tag row so tags have it all.
  Widget _findPill(Pal p, NoteStore store) => GlassSurface(
    radius: 22.dp,
    thick: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _pillIcon(
          CupertinoIcons.clock,
          _recentMode ? 'Back to my files' : 'Recent files',
          _toggleRecent,
          on: _recentMode,
        ),
        _pillIcon(
          CupertinoIcons.pin,
          _pinnedMode ? 'Show all files' : 'Pinned files',
          _togglePinned,
          on: _pinnedMode,
          // The pin glyph fills its box taller and sits high in it; a touch
          // smaller and lower, it reads the same size as clock and search.
          scale: 0.88,
          dy: 1.5,
        ),
        // Nothing to search until there is a file.
        if (store.notes.isNotEmpty || _recentMode) ...[
          _pillIcon(
            CupertinoIcons.search,
            'Search files',
            // In Recent it searches the recent files.
            () => setState(() => _searchOpen = true),
          ),
        ],
      ],
    ),
  );

  /// The open search: a field in the tag row's place, and a close button
  /// in the search button's spot that clears and puts the tags back.
  Widget _searchField(Pal p) {
    return SizedBox(
      height: 44.dp,
      child: Row(
        children: [
          Expanded(
            child: GlassSurface(
              radius: 22.dp,
              padding: EdgeInsets.symmetric(horizontal: 14.dp),
              child: Row(
                children: [
                  Icon(CupertinoIcons.search, size: 16.dp, color: p.sub),
                  SizedBox(width: 8.dp),
                  Expanded(
                    child: TextField(
                      selectionWidthStyle: BoxWidthStyle.tight,
                      // Off: the app is scaled to fit width, which puts Android's
                      // loupe in the wrong place and leaves it stuck on screen.
                      magnifierConfiguration:
                          TextMagnifierConfiguration.disabled,
                      controller: _searchCtrl,
                      autofocus: true,
                      cursorColor: p.accent,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(color: p.ink, fontSize: 15.sp),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 11.dp),
                        border: InputBorder.none,
                        hintText: _recentMode
                            ? 'Search recent files'
                            : 'Search files',
                        hintStyle: TextStyle(color: p.sub, fontSize: 15.sp),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 10.dp),
          // Sits a touch low beside the taller field, so it reads level.
          Transform.translate(
            offset: Offset(0, 1.5.dp),
            child: RoundGlassButton(
              icon: CupertinoIcons.xmark,
              size: 38.dp,
              semanticLabel: 'Close search',
              onPressed: () {
                _searchCtrl.clear();
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() {
                  _searchOpen = false;
                  _searchInside = false;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  /// One key per tag chip, so a tag picked from the all-tags sheet can be
  /// scrolled into view.
  final _tagKeys = <String, GlobalKey>{};

  /// From this many tags the row gets its all-tags button: past it, finding
  /// one by scrolling sideways is slower than seeing them all.
  static const _manyTags = 4;

  Widget _tagRow(Pal p, NoteStore store) {
    final tags = store.allTags;
    GlobalKey keyFor(String t) => _tagKeys.putIfAbsent(t, GlobalKey.new);
    final chips = <Widget>[
      _TagChip(
        label: 'All',
        selected: _tag == null,
        onTap: () => setState(() => _tag = null),
      ),
      for (final t in tags) ...[
        SizedBox(width: 8.dp),
        _TagChip(
          key: keyFor(t),
          label: t,
          selected: _tag == t,
          onTap: () => setState(() => _tag = t),
          onLong: () => _tagMenu(t),
        ),
      ],
      SizedBox(width: 10.dp),
      Container(
        width: 1,
        height: 20.dp,
        color: p.faint,
        margin: EdgeInsets.symmetric(vertical: 8.dp),
      ),
      SizedBox(width: 10.dp),
      _TagChip(label: '+', selected: false, outline: true, onTap: _addTag),
      SizedBox(width: 8.dp),
    ];
    final many = tags.length >= _manyTags;
    final row = ListView(
      scrollDirection: Axis.horizontal,
      // With the all-tags button, the last chip scrolls clear of it.
      padding: EdgeInsets.only(right: many ? 46.dp : 0),
      children: chips,
    );
    if (!many) return row;
    return Stack(
      children: [
        // The edge fades where more chips are hidden, so it reads as a
        // row that goes on rather than one that is cut off.
        Positioned.fill(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) {
              final w = r.width == 0 ? 1.0 : r.width;
              final fadeEnd = ((w - 46.dp) / w).clamp(0.0, 1.0);
              final fadeStart = ((w - 46.dp - 28.dp) / w).clamp(0.0, fadeEnd);
              return LinearGradient(
                colors: const [
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                  Colors.transparent,
                ],
                stops: [0, fadeStart, fadeEnd, 1],
              ).createShader(r);
            },
            child: row,
          ),
        ),
        // Shaped like the chips beside it, so it reads as part of the row.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: Semantics(
              button: true,
              label: 'All tags',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  _allTags(store);
                },
                child: Container(
                  width: 40.dp,
                  height: 34.dp,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12.dp),
                    border: Border.all(color: p.ink.withValues(alpha: 0.18)),
                  ),
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 15.dp,
                    color: p.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Every tag at once, in rows: one tap picks it, without scrolling the
  /// row sideways to find it.
  Future<void> _allTags(NoteStore store) async {
    final picked = await showGlassSheet<String>(
      context,
      builder: (ctx) {
        final p = Pal.of(ctx);
        final tags = store.allTags;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18.dp, 8.dp, 18.dp, 16.dp),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tags',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 20.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2.dp),
                Text(
                  'Hold a tag to rename or delete it.',
                  style: TextStyle(color: p.sub, fontSize: 13.sp),
                ),
                SizedBox(height: 14.dp),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8.dp,
                      runSpacing: 12.dp,
                      children: [
                        _TagChip(
                          label: 'All',
                          selected: _tag == null,
                          onTap: () => Navigator.of(ctx).pop(''),
                        ),
                        for (final t in tags)
                          _TagChip(
                            label: t,
                            selected: _tag == t,
                            onTap: () => Navigator.of(ctx).pop(t),
                            onLong: () {
                              Navigator.of(ctx).pop();
                              _tagMenu(t);
                            },
                          ),
                        _TagChip(
                          label: '+',
                          selected: false,
                          outline: true,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _addTag();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _tag = picked.isEmpty ? null : picked);
    if (picked.isEmpty) return;
    // Bring the picked chip into view in the row.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _tagKeys[picked]?.currentContext;
      if (c != null && c.mounted) {
        Scrollable.ensureVisible(
          c,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// Renames a tag everywhere it is used; the files keep it under the
  /// new name, and a filter on it follows.
  Future<void> _renameTag(String tag) async {
    final store = NoteScope.of(context);
    final name = await promptText(
      context,
      title: 'Rename tag',
      label: 'Tag name',
      initial: tag,
      confirmLabel: 'Rename',
      caps: TextCapitalization.words,
    );
    final t = name?.trim() ?? '';
    if (t.isEmpty || t == tag || !mounted) return;
    final clash = store.allTags.where(
      (x) => x != tag && x.toLowerCase() == t.toLowerCase(),
    );
    if (clash.isNotEmpty) {
      showToast(
        context,
        message: 'Tag "${clash.first}" already exists',
        icon: CupertinoIcons.tag,
      );
      return;
    }
    await store.renameTag(tag, t);
    if (mounted && _tag == tag) setState(() => _tag = t);
  }

  Future<void> _tagMenu(String tag) async {
    final store = NoteScope.of(context);
    final choice = await showGlassMenu<String>(
      context,
      title: tag,
      items: [
        ('rename', CupertinoIcons.text_cursor, 'Rename tag', false),
        ('delete', CupertinoIcons.delete, 'Delete tag', true),
      ],
    );
    if (choice == 'rename' && mounted) return _renameTag(tag);
    if (choice != 'delete' || !mounted) return;
    // A tag on files asks first; the files themselves are kept, only the
    // tag comes off them. An unused tag goes at once, nothing to lose.
    final used = store.notes.where((n) => n.tags.contains(tag)).length;
    if (used > 0) {
      final ok = await showConfirm(
        context,
        title: 'Delete tag "$tag"?',
        message: used == 1
            ? '1 file has this tag. The file stays; only the tag is removed.'
            : '$used files have this tag. The files stay; only the tag is removed.',
        confirmLabel: 'Delete tag',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    if (_tag == tag) setState(() => _tag = null);
    await store.removeTag(tag);
  }

  // Lifted: centred in the space under the header it sat visibly below the
  // middle of the screen.
  Widget _empty(Pal p) => Transform.translate(
    offset: Offset(0, -56.dp),
    child: EmptyState(
      icon: _query.isNotEmpty
          ? CupertinoIcons.doc_text_search
          : _pinnedMode
          ? CupertinoIcons.pin
          : CupertinoIcons.doc_text,
      title: _query.isNotEmpty
          ? 'No matches'
          : _pinnedMode
          ? 'No pinned files'
          : _tag != null
          ? 'No files tagged $_tag'
          : 'No files yet',
      hint: _query.isNotEmpty
          ? null
          : _pinnedMode
          ? 'Pin a file from its ••• menu.'
          : _tag != null
          ? 'Tag a file from its ••• menu.'
          : 'Tap the + button to write one.',
      bg: false,
    ),
  );

  Widget _bottomBar(Pal p) {
    return Positioned(
      left: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 14.dp,
      child: GlassSurface(
        radius: 28.dp,
        thick: true,
        padding: EdgeInsets.symmetric(horizontal: 6.dp, vertical: 4.dp),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _barIcon(
              CupertinoIcons.settings,
              'Settings',
              () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
            _barIcon(
              _layoutIcon(SettingsScope.of(context).listLayout),
              'View',
              _viewMenu,
            ),
            _barIcon(CupertinoIcons.sort_down, 'Sort', _sortMenu),
            _barIcon(
              CupertinoIcons.trash,
              'Trash',
              () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const TrashScreen())),
            ),
          ],
        ),
      ),
    );
  }

  /// An icon in the top pill: the bar's, a size smaller to sit in the row.
  /// An icon in the header's find pill: sized to the title beside it and
  /// a step quieter than it, so the name leads and the tools sit back.
  Widget _pillIcon(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool on = false,
    double scale = 1,
    double dy = 0,
  }) {
    final p = Pal.of(context);
    Widget glyph(double size, Color color) => Transform.translate(
      offset: Offset(0, dy.dp),
      child: Icon(icon, size: size * scale, color: color),
    );
    return GlassPress(
      onTap: onTap,
      label: label,
      // The same gap on every side, so a lit circle sits centred in the
      // pill rather than nearer one edge.
      child: Padding(
        padding: EdgeInsets.all(4.dp),
        child: SizedBox.square(
          dimension: 32.dp,
          // Lit, it is the + button's own glass: one look for "on".
          child: on
              ? GlassSurface(
                  radius: 16.dp,
                  thick: true,
                  gradient: p.accentFill,
                  child: Center(child: glyph(19.dp, Colors.white)),
                )
              : Center(child: glyph(20.dp, p.ink)),
        ),
      ),
    );
  }

  /// A mode's name in the tag row's place, so the list says what it is.
  Widget _modeTitle(Pal p, String title) => Padding(
    padding: EdgeInsets.only(left: 6.dp),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: p.ink,
          fontSize: 15.sp,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  /// In Recent mode, in the tag row's place: what the list is, and Clear.
  Widget _recentBar(Pal p) {
    final any = (_recentFiles?.items ?? const []).isNotEmpty;
    return Row(
      children: [
        SizedBox(width: 6.dp),
        Expanded(
          child: Text(
            'Recently opened',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.ink,
              fontSize: 15.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (any)
          TextButton(
            onPressed: _clearRecent,
            child: Text(
              'Clear',
              style: TextStyle(
                color: p.accent,
                fontSize: 14.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _barIcon(IconData icon, String label, VoidCallback onTap) =>
      GlassPress(
        onTap: onTap,
        label: label,
        child: Padding(
          padding: EdgeInsets.all(12.dp),
          child: Icon(icon, size: 22.dp, color: Pal.of(context).ink),
        ),
      );

  Widget _fab(Pal p) {
    final bottom = MediaQuery.paddingOf(context).bottom + 14.dp;
    return Positioned(
      right: 16,
      bottom: bottom,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _fabOpen
                // Right inset = half the size difference (54 vs 48), so the
                // small circles sit centred over the big one.
                ? Padding(
                    padding: EdgeInsets.only(right: 3.dp),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _miniFab(CupertinoIcons.folder, 'Open file', _browse),
                        SizedBox(height: 12.dp),
                        _miniFab(
                          CupertinoIcons.square_pencil,
                          'New note',
                          _newNote,
                        ),
                        SizedBox(height: 12.dp),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          GlassPress(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _fabOpen = !_fabOpen);
            },
            label: 'New',
            child: SizedBox.square(
              dimension: 54.dp,
              child: GlassSurface(
                radius: 27.dp,
                thick: true,
                gradient: p.accentFill,
                child: Center(
                  child: AnimatedRotation(
                    turns: _fabOpen ? 0.125 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      CupertinoIcons.add,
                      color: Colors.white,
                      size: 23.dp,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniFab(IconData icon, String label, VoidCallback onTap) {
    final p = Pal.of(context);
    return GlassPress(
      onTap: onTap,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassSurface(
            radius: 14.dp,
            thick: true,
            padding: EdgeInsets.symmetric(horizontal: 12.dp, vertical: 8.dp),
            child: Text(
              label,
              style: TextStyle(
                color: p.ink,
                fontSize: 13.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: 10.dp),
          SizedBox.square(
            dimension: 48.dp,
            child: GlassSurface(
              radius: 24.dp,
              thick: true,
              child: Center(
                child: Icon(icon, color: p.accent, size: 22.dp),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _tileMenu(Note n) async {
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    final choice = await showGlassMenu<String>(
      context,
      title: n.fullName,
      leading: FileBadge(look: FileLook.of(n.ext), size: 34.dp),
      grid: true,
      items: [
        (
          n.pinned ? 'unpin' : 'pin',
          n.pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
          n.pinned ? 'Unpin' : 'Pin',
          false,
        ),
        (
          n.locked ? 'unlock' : 'lock',
          n.locked ? CupertinoIcons.lock_open : CupertinoIcons.lock,
          n.locked ? 'Unlock' : 'Lock',
          false,
        ),
        if (s.tagsEnabled) ('tags', CupertinoIcons.tag, 'Tags', false),
        ('share', CupertinoIcons.share, 'Share', false),
        ('rename', CupertinoIcons.text_cursor, 'Rename', false),
        ('copy', CupertinoIcons.doc_on_doc, 'Copy', false),
        ('save', CupertinoIcons.arrow_down_doc, 'Save to phone', false),
        ('info', CupertinoIcons.info_circle, 'File info', false),
        ('delete', CupertinoIcons.trash, 'Delete', true),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'pin':
        await store.setPinned(n, true);
      case 'unpin':
        await store.setPinned(n, false);
      case 'lock':
        if (await ensureCanLock(context, anyLocked: _anyLocked(store))) {
          await store.setLocked(n, true);
        }
      case 'unlock':
        // Taking a lock off is as guarded as opening: otherwise anyone with
        // the phone could unlock a file from this menu and then read it.
        if (await authenticate(context, 'Unlock ${n.fullName}')) {
          await store.setLocked(n, false);
        }
      case 'share':
        if (!await _passLock([n], 'Share ${n.fullName}') || !mounted) return;
        final how = await showShareFormat(context, count: 1);
        if (how == 'files') {
          if (n.size == 0) {
            if (mounted) _emptyToast('${n.fullName} is');
            return;
          }
          await SharePlus.instance.share(ShareParams(files: [_shareFile(n)]));
        } else if (how == 'pdfs' && mounted) {
          await _sharePdfs([n], zip: false);
        }
      case 'tags':
        await _editTags(n);
      case 'copy':
        try {
          final c = await store.duplicate(n);
          if (mounted) {
            showToast(
              context,
              message: 'Copied as ${c.fullName}',
              icon: CupertinoIcons.doc_on_doc,
            );
          }
        } catch (_) {
          if (mounted) {
            showToast(
              context,
              message: 'Could not copy this file',
              icon: CupertinoIcons.doc_on_doc,
            );
          }
        }
      case 'rename':
        final settings = SettingsScope.of(context);
        final name = await promptText(
          context,
          title: 'Rename',
          label: 'Name',
          initial: n.name,
          confirmLabel: 'Rename',
        );
        if (name != null) {
          try {
            // The old path's remembered scroll position is now meaningless.
            settings.setScrollFor(n.path, 0);
            await store.rename(n, name);
          } catch (_) {
            if (mounted) {
              showToast(
                context,
                message: 'Could not rename this file',
                icon: CupertinoIcons.text_cursor,
              );
            }
          }
          _selected.remove(n.path);
          if (mounted) _recomputeContentMatches();
        }
      case 'save':
        if (await _passLock([n], 'Save ${n.fullName} to phone')) {
          await _saveToPhone(n);
        }
      case 'info':
        // Word and character counts are about the contents.
        if (await _passLock([n], 'Show info for ${n.fullName}')) {
          if (mounted) await _fileInfo(n);
        }
      case 'delete':
        await _deleteNote(n);
    }
  }

  Future<void> _editTags(Note n) async {
    final store = NoteScope.of(context);
    final selected = Set<String>.from(n.tags);
    await showGlassSheet(
      context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final p = Pal.of(ctx);
            return Padding(
              padding: EdgeInsets.fromLTRB(20.dp, 14.dp, 20.dp, 20.dp),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tags',
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 14.dp),
                  if (store.allTags.isEmpty)
                    Text(
                      'No tags yet. Add one from the home screen.',
                      style: TextStyle(color: p.sub, fontSize: 14.sp),
                    ),
                  Wrap(
                    spacing: 8.dp,
                    runSpacing: 12.dp,
                    children: [
                      for (final t in store.allTags)
                        _TagChip(
                          label: t,
                          selected: selected.contains(t),
                          onTap: () => setSheet(
                            () => selected.contains(t)
                                ? selected.remove(t)
                                : selected.add(t),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 18.dp),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      await store.setTags(n, selected.toList());
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: GlassSurface(
                      radius: 14.dp,
                      thick: true,
                      gradient: p.accentFill,
                      child: SizedBox(
                        height: 48.dp,
                        child: Center(
                          child: Text(
                            'Done',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15.5.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// A copy of one of Breeze's own files, saved in a folder the user picks,
  /// where the phone's Files app shows it. Breeze keeps its files private.
  Future<void> _saveToPhone(Note n) async {
    Object? res;
    try {
      res = await _openChannel.invokeMethod<Object>('saveCopy', {
        'path': n.file.path,
        'name': n.fullName,
      });
    } catch (_) {
      res = false;
    }
    if (!mounted || res == null) return; // cancelled
    // Breeze's own files are private to it, so Files cannot see them; the
    // copy can be, and Show goes straight to its folder.
    final copy = res is String ? res : null;
    showToast(
      context,
      message: copy != null
          ? 'Saved a copy to your phone'
          : 'Could not save a copy',
      icon: copy != null
          ? CupertinoIcons.checkmark_alt
          : CupertinoIcons.exclamationmark_circle,
      actionLabel: copy != null ? 'Show' : null,
      onAction: copy == null
          ? null
          : () async {
              if (!await showFileInFiles(copy) && mounted) {
                showToast(
                  context,
                  message: 'No file manager could open its folder',
                  icon: CupertinoIcons.folder,
                );
              }
            },
    );
  }

  Future<void> _fileInfo(Note n) async {
    final store = NoteScope.of(context);
    final String text;
    try {
      text = await store.read(n);
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not read this file',
          icon: CupertinoIcons.info_circle,
        );
      }
      return;
    }
    final st = TextStats(text);
    if (!mounted) return;
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    await showGlassSheet(
      context,
      builder: (ctx) {
        final p = Pal.of(ctx);
        final look = FileLook.of(n.ext);
        // 12345 -> 12,345: big counts read at a glance.
        String num(int v) => v.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (_) => ',',
        );
        Widget stat(String value, String label) => Expanded(
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 12.dp, horizontal: 6.dp),
            decoration: BoxDecoration(
              color: p.ink.withValues(alpha: p.dark ? 0.05 : 0.04),
              borderRadius: BorderRadius.circular(16.dp),
            ),
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 19.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(height: 2.dp),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.sub, fontSize: 12.5.sp),
                ),
              ],
            ),
          ),
        );
        Widget fact(IconData icon, String text) => Padding(
          padding: EdgeInsets.only(top: 8.dp),
          child: Row(
            children: [
              Icon(icon, size: 15.dp, color: p.sub),
              SizedBox(width: 8.dp),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: p.sub, fontSize: 13.5.sp),
                ),
              ),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(20.dp, 10.dp, 20.dp, 20.dp),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The file itself: what it is and how big.
              Row(
                children: [
                  FileBadge(look: look, size: 44.dp),
                  SizedBox(width: 12.dp),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          n.fullName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 17.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2.dp),
                        Text(
                          '${fileKindName(n.ext)}  ·  ${humanSize(n.size)}',
                          style: TextStyle(
                            color: look.ink(p),
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16.dp),
              Row(
                children: [
                  stat(num(st.words), 'Words'),
                  SizedBox(width: 8.dp),
                  stat(num(st.characters), 'Characters'),
                  SizedBox(width: 8.dp),
                  stat(num(st.lines), 'Lines'),
                ],
              ),
              SizedBox(height: 6.dp),
              fact(
                CupertinoIcons.clock,
                'Edited ${fullDate(n.modified, h24: h24)}',
              ),
              // Breeze's files are private, so the Files app cannot see
              // them; a copy saved to the phone can be.
              fact(
                CupertinoIcons.lock,
                'Kept inside Breeze. Save a copy to see it in Files.',
              ),
              SizedBox(height: 16.dp),
              GlassPress(
                onTap: () {
                  Navigator.of(ctx).pop();
                  _saveToPhone(n);
                },
                label: 'Save to phone',
                child: Container(
                  height: 46.dp,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: p.accentFill,
                    borderRadius: BorderRadius.circular(14.dp),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.arrow_down_doc,
                        size: 18.dp,
                        color: Colors.white,
                      ),
                      SizedBox(width: 8.dp),
                      Text(
                        'Save to phone',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Deletes the whole selection behind ONE confirmation, with the same
  /// rule as a single file: Breeze-folder files go to the 30-day trash when
  /// it is on; files opened from elsewhere cannot be trashed and are deleted.
  Future<void> _deleteSelected() async {
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    final notes = store.notes.where((n) => _selected.contains(n.path)).toList();
    if (notes.isEmpty) return;
    final toTrash = s.trashEnabled ? notes.where((n) => !n.external).length : 0;
    final outright = notes.length - toTrash;
    final trashable = outright == 0;
    final count = notes.length == 1
        ? notes.first.fullName
        : '${notes.length} files';
    final ok = await showConfirm(
      context,
      title: trashable ? 'Move to trash?' : 'Delete $count?',
      message: trashable
          ? '$count will be moved to the trash. You can restore them for 30 days.'
          : toTrash == 0
          ? '$count will be permanently deleted.'
          : '$toTrash will go to the trash (restorable for 30 days). '
                '$outright opened from outside Breeze will be permanently deleted.',
      confirmLabel: trashable ? 'Move to trash' : 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    // A locked file is deleted only after the fingerprint, like opening it.
    if (!await _passLock(notes, 'Delete locked files')) return;
    if (!mounted) return;
    // One file that cannot be moved must not stop the rest of the batch.
    var failed = 0;
    final trashed = <TrashedNote>[];
    for (final n in notes) {
      if (!mounted) return;
      // The old path's remembered scroll position is now meaningless.
      SettingsScope.of(context).setScrollFor(n.path, 0);
      try {
        if (s.trashEnabled && !n.external) {
          final t = await store.moveToTrash(n);
          if (t != null) trashed.add(t);
        } else {
          await store.deletePermanently(n);
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    _exitSelect();
    if (failed > 0) {
      await store.refresh();
      if (!mounted) return;
      showToast(
        context,
        message: failed == 1
            ? 'Could not delete 1 file'
            : 'Could not delete $failed files',
        icon: CupertinoIcons.exclamationmark_circle,
      );
      return;
    }
    showToast(
      context,
      message: trashable
          ? (notes.length == 1
                ? 'Moved to trash'
                : 'Moved ${notes.length} files to trash')
          : (notes.length == 1 ? 'Deleted' : 'Deleted ${notes.length} files'),
      icon: CupertinoIcons.trash,
      actionLabel: trashable && trashed.isNotEmpty ? 'Undo' : null,
      onAction: trashable && trashed.isNotEmpty
          ? () => _undoTrash(store, trashed)
          : null,
    );
  }

  /// Puts files just moved to the trash back, from the toast's Undo.
  Future<void> _undoTrash(NoteStore store, List<TrashedNote> items) async {
    var failed = 0;
    for (final t in items) {
      try {
        await store.restore(t);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (failed > 0) {
      await store.refresh();
      if (!mounted) return;
      showToast(
        context,
        message: failed == 1
            ? "Couldn't restore 1 file. It is still in the trash."
            : "Couldn't restore $failed files. They are still in the trash.",
        icon: CupertinoIcons.exclamationmark_circle,
      );
      return;
    }
    showToast(
      context,
      message: items.length == 1
          ? 'Restored'
          : 'Restored ${items.length} files',
      icon: CupertinoIcons.arrow_uturn_left,
    );
  }

  Future<void> _deleteNote(Note n) async {
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    // Folder files go to the 30-day trash (if enabled); files opened from
    // outside the Breeze folder can't be trashed, so they're deleted outright.
    final toTrash = s.trashEnabled && !n.external;
    final ok = await showConfirm(
      context,
      title: toTrash ? 'Move to trash?' : 'Delete file?',
      message: toTrash
          ? '${n.fullName} will be moved to the trash. You can restore it for 30 days.'
          : '${n.fullName} will be permanently deleted.',
      confirmLabel: toTrash ? 'Move to trash' : 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    if (!await _passLock([n], 'Delete ${n.fullName}')) return;
    if (!mounted) return;
    if (toTrash) {
      // The old path's remembered scroll position is now meaningless.
      SettingsScope.of(context).setScrollFor(n.path, 0);
      TrashedNote? trashed;
      try {
        trashed = await store.moveToTrash(n);
      } catch (_) {
        await store.refresh();
        if (mounted) {
          showToast(
            context,
            message: "Couldn't move ${n.fullName} to trash",
            icon: CupertinoIcons.exclamationmark_circle,
          );
        }
        return;
      }
      if (mounted) {
        final t = trashed;
        showToast(
          context,
          message: 'Moved to trash',
          icon: CupertinoIcons.trash,
          actionLabel: t == null ? null : 'Undo',
          onAction: t == null ? null : () => _undoTrash(store, [t]),
        );
      }
    } else {
      // The old path's remembered scroll position is now meaningless.
      SettingsScope.of(context).setScrollFor(n.path, 0);
      try {
        await store.deletePermanently(n);
      } catch (_) {
        if (mounted) {
          showToast(
            context,
            message: "Couldn't delete ${n.fullName}",
            icon: CupertinoIcons.exclamationmark_circle,
          );
        }
        return;
      }
    }
    if (mounted) setState(() => _selected.remove(n.path));
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.layout,
    required this.query,
    required this.onTap,
    required this.onMenu,
    this.h24 = true,
    this.onLong,
    this.selecting = false,
    this.selected = false,
  });
  final Note note;
  final ListLayout layout;
  final String query;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  /// The phone's clock: 24-hour, or 12-hour with AM/PM.
  final bool h24;
  final VoidCallback? onLong;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final compact = layout == ListLayout.compact;
    final grid = layout == ListLayout.grid;
    return GlassPress(
      onTap: onTap,
      onLongPress: onLong,
      label: note.fullName,
      actions: {
        CustomSemanticsAction(label: 'More for ${note.fullName}'): onMenu,
      },
      child: GlassSurface(
        radius: compact ? 16.dp : 20.dp,
        tint: selected ? p.accent.withValues(alpha: 0.18) : null,
        padding: grid
            ? EdgeInsets.fromLTRB(14.dp, 12.dp, 4.dp, 12.dp)
            : compact
            ? EdgeInsets.fromLTRB(12.dp, 8.dp, 4.dp, 8.dp)
            : EdgeInsets.fromLTRB(16.dp, 14.dp, 8.dp, 14.dp),
        child: grid
            ? _gridBody(p)
            : compact
            ? _compactBody(p)
            : _listBody(p, detailed: layout == ListLayout.detailed),
      ),
    );
  }

  FileLook get _look => FileLook.of(note.ext);

  /// The type's name: "Word", "Markdown", "PY"; a data or unusual text file
  /// by its own extension ("CSV", "XML", "CONF"), which says more.
  String get _label {
    final k = _look;
    final e = note.ext;
    if ((identical(k, FileLook.data) ||
            (identical(k, FileLook.text) &&
                !const {'', '.txt', '.text', '.note'}.contains(e))) &&
        e.length > 1 &&
        e.length <= 6) {
      return e.substring(1).toUpperCase();
    }
    return k.label;
  }

  Widget _badge(Pal p, double size) => FileBadge(
    look: _look,
    size: size,
    selecting: selecting,
    selected: selected,
  );

  /// The type's name in its colour, then the rest of the line in grey.
  Widget _kindLine(Pal p, String rest, {double size = 13}) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: _label,
          style: TextStyle(color: _look.ink(p), fontWeight: FontWeight.w600),
        ),
        if (rest.isNotEmpty) TextSpan(text: '  ·  $rest'),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: p.sub, fontSize: size.sp),
  );

  Widget _menu(Pal p) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onMenu,
    child: Padding(
      padding: EdgeInsets.all(8.dp),
      child: Icon(CupertinoIcons.ellipsis, size: 20.dp, color: p.sub),
    ),
  );

  // The pin and lock ride INSIDE the text as middle-aligned spans, so they
  // centre on the first line's letters whatever the font size, rather than
  // being nudged down by a guessed padding. The name is shown without its
  // extension: the coloured type beside it already says what it is.
  Widget _name(Pal p, {double size = 17, int lines = 1}) {
    // The pin glyph is top-heavy, so it reads high even when its box is
    // centred; a 1dp drop puts its weight on the line.
    Widget mark(IconData i) => Padding(
      padding: EdgeInsets.only(right: 5.dp),
      child: Transform.translate(
        offset: Offset(0, 1.dp),
        child: Icon(i, size: (size * 0.78).dp, color: p.accent),
      ),
    );
    final name = note.name.trim().isEmpty ? note.fullName : note.name;
    return Text.rich(
      TextSpan(
        children: [
          if (note.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: mark(CupertinoIcons.pin_fill),
            ),
          if (note.locked)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: mark(CupertinoIcons.lock_fill),
            ),
          TextSpan(text: name),
        ],
      ),
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: p.ink,
        fontSize: size.sp,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.1,
      ),
    );
  }

  Widget _tags(Pal p) => Wrap(
    spacing: 6.dp,
    runSpacing: 4.dp,
    children: [
      for (final t in note.tags)
        Container(
          padding: EdgeInsets.symmetric(horizontal: 8.dp, vertical: 2.dp),
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8.dp),
          ),
          child: Text(
            t,
            style: TextStyle(
              color: p.accent,
              fontSize: 10.5.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
    ],
  );

  /// One line: badge, name, when, menu. For long lists; the badge's colour
  /// carries the type.
  Widget _compactBody(Pal p) => Row(
    children: [
      _badge(p, 32.dp),
      SizedBox(width: 12.dp),
      Expanded(child: _name(p, size: 16)),
      SizedBox(width: 8.dp),
      Text(
        friendlyDate(note.modified, short: true, h24: h24),
        style: TextStyle(color: p.sub, fontSize: 13.sp),
      ),
      _menu(p),
    ],
  );

  /// Standard, and Detailed with the first words of the file and its size.
  Widget _listBody(Pal p, {required bool detailed}) => Row(
    crossAxisAlignment: detailed
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      _badge(p, 44.dp),
      SizedBox(width: 14.dp),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _name(p),
            SizedBox(height: 3.dp),
            _kindLine(
              p,
              detailed
                  ? '${friendlyDate(note.modified, h24: h24)}  ·  ${humanSize(note.size)}'
                  : friendlyDate(note.modified, h24: h24),
            ),
            if (detailed) ...[
              SizedBox(height: 8.dp),
              _Preview(note: note, lines: 2),
            ],
            if (note.tags.isNotEmpty) ...[SizedBox(height: 8.dp), _tags(p)],
          ],
        ),
      ),
      _menu(p),
    ],
  );

  /// A card: badge and menu on top, the name, a peek at the words, and the
  /// type and day at the foot.
  Widget _gridBody(Pal p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [_badge(p, 38.dp), const Spacer(), _menu(p)]),
      SizedBox(height: 10.dp),
      Padding(
        padding: EdgeInsets.only(right: 10.dp),
        child: _name(p, size: 15.5, lines: 2),
      ),
      SizedBox(height: 5.dp),
      Expanded(
        child: Padding(
          padding: EdgeInsets.only(right: 10.dp),
          child: _Preview(note: note, lines: 3, size: 12.5),
        ),
      ),
      SizedBox(height: 6.dp),
      _kindLine(
        p,
        friendlyDate(note.modified, short: true, h24: h24),
        size: 12.5,
      ),
    ],
  );
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLong,
    this.outline = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLong;
  final bool outline;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final isPlus = label == '+';
    return Semantics(
      button: true,
      selected: selected,
      label: isPlus ? 'Add tag' : label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLong,
          child: GlassSurface(
          radius: 12.dp,
          thick: true,
          gradient: selected ? p.accentFill : null,
          padding: EdgeInsets.symmetric(horizontal: isPlus ? 0 : 16.dp),
          // 34: the home row's height, so a chip in the Tags sheet is the
          // same size as the one in the row.
          child: SizedBox(
            height: 34.dp,
            width: isPlus ? 44.dp : null,
            // widthFactor 1: hug the label. A plain Center fills whatever width
            // it is offered, which stretched a lone chip across the Tags sheet.
            child: Center(
              widthFactor: isPlus ? null : 1,
              child: isPlus
                  ? Icon(CupertinoIcons.add, size: 18.dp, color: p.ink)
                  : Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : p.ink,
                        fontSize: 13.5.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ));
  }
}

/// The first words of a file, for the Detailed and Grid layouts. Reads only
/// the head of the file and caches it per (path, modified time), so scrolling
/// a long list does not re-read anything. A locked file never shows its text.
class _Preview extends StatelessWidget {
  const _Preview({required this.note, this.lines = 2, this.size = 13});
  final Note note;
  final int lines;
  final double size;

  static final _cache = <String, String>{};

  static Future<String> _load(Note n) async {
    final key = '${n.path}|${n.modified.millisecondsSinceEpoch}';
    final hit = _cache[key];
    if (hit != null) return hit;
    var text = '';
    try {
      final raf = await n.file.open();
      try {
        final head = await raf.read(400);
        text = utf8.decode(head, allowMalformed: true);
        // An RTF document starts with its font table: its words come from
        // reading it (up to 2 MB; a bigger one shows no preview).
        if (NoteStore.isDocx(n.path) && looksLikeDocx(head)) {
          // A Word document is a zip: its words come from reading it.
          final size = await raf.length();
          if (size <= 2 << 20) {
            await raf.setPosition(0);
            final all = await raf.read(size);
            text = await compute(docxPlainText, all.toList());
            if (text.length > 400) text = text.substring(0, 400);
          } else {
            text = '';
          }
        } else if (NoteStore.isRtf(n.path) && looksLikeRtf(text)) {
          final size = await raf.length();
          if (size <= 2 << 20) {
            await raf.setPosition(0);
            final all = await raf.read(size);
            text = await compute(
              rtfPlainText,
              utf8.decode(all, allowMalformed: true),
            );
            if (text.length > 400) text = text.substring(0, 400);
          } else {
            text = '';
          }
        }
        text = previewText(text, n.ext, n.name);
      } finally {
        await raf.close();
      }
    } catch (_) {}
    if (_cache.length > 500) _cache.clear();
    return _cache[key] = text;
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final style = TextStyle(color: p.sub, fontSize: size.sp, height: 1.35);
    if (note.locked || SettingsScope.of(context).lockFiles) {
      return Text('Locked', style: style.copyWith(fontStyle: FontStyle.italic));
    }
    return FutureBuilder<String>(
      future: _load(note),
      builder: (context, snap) {
        final t = snap.data;
        final empty = t != null && t.isEmpty;
        return Text(
          t == null ? '' : (empty ? 'Empty file' : t),
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: empty ? style.copyWith(fontStyle: FontStyle.italic) : style,
        );
      },
    );
  }
}

/// A note dropping into place when the app opens: each a little after the
/// one above it, fading in as it settles. Plays once, at launch only; with
/// the phone's animations turned off it is simply there.
class _EntranceIn extends StatefulWidget {
  const _EntranceIn({
    required this.index,
    required this.play,
    required this.child,
  });
  final int index;
  final bool play;
  final Widget child;

  @override
  State<_EntranceIn> createState() => _EntranceInState();
}

class _EntranceInState extends State<_EntranceIn>
    with SingleTickerProviderStateMixin {
  // One clock for every tile, started at the first drawn frame. Each tile
  // reads its own place on that clock every frame, so a slow launch frame
  // delays them all equally instead of letting their timers bunch up.
  static Stopwatch? _clock;
  static const _lead = 250, _each = 220, _run = 650;

  Ticker? _ticker;
  double _v = 1;

  @override
  void initState() {
    super.initState();
    if (!widget.play) return;
    _v = 0;
    if (_clock == null) {
      final sw = Stopwatch();
      _clock = sw;
      WidgetsBinding.instance.addPostFrameCallback((_) => sw.start());
    }
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final delay = _lead + _each * widget.index.clamp(0, 12);
    final v = ((_clock!.elapsedMilliseconds - delay) / _run).clamp(0.0, 1.0);
    if (v != _v) setState(() => _v = v);
    if (v >= 1) _ticker?.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ticker != null && MediaQuery.disableAnimationsOf(context)) {
      _ticker!.stop();
      _v = 1;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_v >= 1) return widget.child;
    final t = Curves.easeOutCubic.transform(_v);
    // No fade: hidden until its turn, then solid while it drops into place.
    // Clipped to its own slot: the tiles are see-through glass, and one
    // falling over the tile above showed THAT tile through its glass, so its
    // colour changed when it landed.
    return Opacity(
      opacity: _v > 0 ? 1 : 0,
      child: ClipRect(
        child: Transform.translate(
          offset: Offset(0, -60 * (1 - t)),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The notes among [job].$1 whose text contains [job].$2 (lowercase).
Set<String> _searchFiles((List<String>, String) job) {
  final (paths, q) = job;
  final hits = <String>{};
  for (final path in paths) {
    try {
      final bytes = File(path).readAsBytesSync();
      if (NoteStore.isDocx(path) && looksLikeDocx(bytes)) {
        if (docxPlainText(bytes).toLowerCase().contains(q)) hits.add(path);
        continue;
      }
      var (text, _) = decodeText(bytes);
      // An RTF document is searched by its words, not its codes.
      if (NoteStore.isRtf(path) && looksLikeRtf(text)) {
        text = rtfPlainText(text);
      }
      if (text.toLowerCase().contains(q)) hits.add(path);
    } catch (_) {}
  }
  return hits;
}

/// A tile that just appeared: a short fade and settle into its slot. Whether
/// to play is decided once, when the tile is first built, so a rebuild in the
/// middle of the fade does not cut it off.
class _FreshIn extends StatefulWidget {
  const _FreshIn({required this.play, required this.child});
  final bool play;
  final Widget child;

  @override
  State<_FreshIn> createState() => _FreshInState();
}

class _FreshInState extends State<_FreshIn> {
  late final bool _play = widget.play;

  @override
  Widget build(BuildContext context) {
    if (!_play || MediaQuery.disableAnimationsOf(context)) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      child: widget.child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.96 + 0.04 * v, child: child),
      ),
    );
  }
}
