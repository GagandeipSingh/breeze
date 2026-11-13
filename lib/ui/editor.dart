import 'dart:ui' show BoxWidthStyle;
import 'dart:async';

import 'package:flutter/gestures.dart' show GestureRecognizer;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'glass_chrome.dart';
import 'package:printing/printing.dart';

import '../data/note_scope.dart';
import '../data/note_store.dart';
import '../logic/code_highlight.dart';
import '../logic/docx.dart';
import '../logic/markdown_lite.dart';
import '../logic/pdf_export.dart';
import '../logic/rtf.dart';
import '../logic/text_stats.dart';
import '../state/settings.dart';
import 'format_text.dart';
import '../logic/binary_text.dart';
import '../logic/list_text.dart';
import 'file_look.dart';
import 'recent_sheet.dart' show FileWhere, locateFile, showFileInFiles;
import 'new_file_sheet.dart';
import 'glass_surface.dart';
import 'kit.dart';
import 'lock_gate.dart';
import 'scale.dart';
import 'sheets.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.note,
    this.tag,
    this.edit = false,
    this.newExt,
  });

  /// The type picked for a NEW note ('.txt', '.md', '.rtf', '.json', ...):
  /// what it is saved as when its title names no type of its own.
  final String? newExt;

  /// Null means a brand-new note (opens straight in edit mode).
  final Note? note;

  /// Open [note] in edit mode (a copy made to be edited).
  final bool edit;

  /// The tag filter Home was showing when this NEW note was started. The
  /// note joins it on first save, so it shows up where it was made.
  final String? tag;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  late final FormatController _body;
  late final TextEditingController _name;
  final UndoHistoryController _undo = UndoHistoryController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _bodyFocus = FocusNode();

  Note? _note;
  String _savedText = '';
  // A Windows file (\r\n): edited as \n like any note, saved back as \r\n,
  // so Enter never leaves a file with mixed line ends.
  bool _crlf = false;
  // The encoding the note was read in, to save it back the same way.
  String _charset = 'UTF-8';

  /// Set for an RTF document: the editor holds its text, and saving writes
  /// RTF again. When it holds what Breeze cannot keep (tables, colours...)
  /// it is only read: "Edit a copy" is offered instead, so the original is
  /// never rewritten without them.
  RtfRead? _rtf;
  bool get _rtfReadOnly => _rtf != null && !_rtf!.editable;

  /// An .rtf name on a file that is plain text: kept plain.
  bool _plainRtf = false;
  String _savedName = '';
  bool _editing = false;

  /// A binary file (an image, an app...) shown as text: read only, as its
  /// bytes would change if it were saved.
  bool _binary = false;

  /// Where an opened file lives, asked once.
  Future<FileWhere>? _where;
  bool _loading = true;
  bool _locked = false;
  bool _dirty = false;
  bool _landscape = false; // read-mode landscape, restored on exit

  /// True once the editor holds the file's REAL text (or is a new note).
  /// Until then the fields are empty, and saving them would write an empty
  /// file over the user's: back pressed while a big file loaded, or before
  /// unlocking, wiped it to 0 bytes.
  bool _ready = false;

  // Find-in-file
  bool _finding = false;
  final TextEditingController _findCtrl = TextEditingController();
  List<(int, int)> _matches = const [];
  int _matchIndex = 0;

  Timer? _autosaveDebounce;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _body = FormatController();
    _name = TextEditingController();
    _editing = widget.note == null || widget.edit;
    _findCtrl.addListener(_recomputeMatches);
    _part.addListener(_onPartEdited);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Whether this note is behind a lock (its own, or "Lock all files").
  bool get _isLockedNote {
    final s = SettingsScope.of(context);
    return _note != null && (s.lockFiles || _note!.locked);
  }

  static const _secureChannel = MethodChannel('breeze/open');

  /// FLAG_SECURE while a locked note is on screen: keeps its text out of the
  /// recent-apps preview and screenshots.
  void _secure(bool on) {
    if (on == _securedHere) return;
    _securedHere = on;
    _secureCount += on ? 1 : -1;
    _secureChannel
        .invokeMethod('secure', _secureCount > 0)
        .catchError((_) => null);
  }

  /// Editors currently asking for FLAG_SECURE (one can open over another,
  /// e.g. a file shared in from another app over a locked note).
  static int _secureCount = 0;
  bool _securedHere = false;

  /// Leaving the app locks a locked note again. Its text stays in the editor
  /// (nothing unsaved is lost) and returns after the fingerprint.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || !_ready || _locked) return;
    // `paused` only: `hidden` is also delivered on the way back UP, so a
    // device-PIN unlock (a separate screen) could re-lock the moment it
    // succeeded, in a loop.
    // Leaving the app saves at once (with autosave on), from the first sign
    // of leaving: swiped away from recents inside the autosave delay, the
    // last words were lost. Saving twice is harmless (no change, no write).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // Not while a new file's type is being picked (the save would make
      // it with the old type), nor while leaving (a failed save's
      // Discard sheet is up, and a retry would write what was discarded).
      if (SettingsScope.of(context).autosave &&
          _hasChanges &&
          !_pickingType &&
          !_closing) {
        _autosaveDebounce?.cancel();
        _save(silent: true);
      }
    }
    if (state != AppLifecycleState.paused) return;
    if (_isLockedNote) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _locked = true);
    }
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Inherited lookups (SettingsScope/NoteScope) are only legal from here on,
    // not initState — reading them too early left _loading stuck and the body
    // blank. Run the load exactly once.
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final s = SettingsScope.of(context);
    if (_note == null) {
      // A new note under "Lock all files" is locked once saved: keep it out
      // of screenshots and the recent-apps preview from the first letter.
      if (s.lockFiles) _secure(true);
      _savedText = '';
      _savedName = '';
      _ready = true;
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _bodyFocus.requestFocus(),
      );
      return;
    }
    // Fingerprint gate: either the global "Lock all files" setting, or this
    // one file being individually locked.
    if (s.lockFiles || (_note?.locked ?? false)) {
      _secure(true);
      setState(() {
        _locked = true;
        _loading = false;
      });
      final ok = await _authenticate();
      if (!ok) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (mounted) setState(() => _locked = false);
    }
    await _loadContent();
  }

  Future<void> _loadContent() async {
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    if (_note == null) return;
    String text;
    try {
      final read = await store.readText(_note!);
      text = read.text;
      _charset = read.charset;
      _rtf = read.rtf;
      _plainRtf =
          read.rtf == null && NoteStore.docKind(_note!.file.path).isNotEmpty;
      _crlf = text.contains('\r\n');
      if (_crlf) text = text.replaceAll('\r\n', '\n');
    } catch (_) {
      // Gone or unreadable: say so and leave, rather than a blank screen
      // stuck loading forever.
      if (!mounted) return;
      showToast(
        context,
        message: 'Could not open this file',
        icon: CupertinoIcons.doc,
      );
      Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    _binary = _rtf == null && !_plainRtf && looksBinary(text);
    if (_binary) {
      _editing = false;
      // Shown readable, never saved: the file on disk keeps its bytes.
      text = binaryForDisplay(text);
    }
    _savedText = text;
    _savedName = _note!.name;
    _body.text = text;
    _name.text = _note!.name;
    _ready = true;
    if (mounted) setState(() => _loading = false);
    if (s.rememberScroll) {
      final off = _prefScroll();
      if (off > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(off.clamp(0, _scroll.position.maxScrollExtent));
          }
        });
      }
    }
  }

  double _prefScroll() =>
      _note == null ? 0 : SettingsScope.of(context).scrollFor(_note!.path);

  /// Remembers where this file was left, when "Remember scroll position"
  /// is on. Called before the controller is disposed.
  void _rememberScroll() {
    final n = _note;
    if (n == null || !_ready || !_scroll.hasClients) return;
    final s = SettingsScope.of(context);
    if (s.rememberScroll) s.setScrollFor(n.path, _scroll.offset);
  }

  /// Fails CLOSED: no screen lock, an error or a cancel keeps the file shut
  /// (see lock_gate.dart). It used to open on any of those.
  Future<bool> _authenticate() async {
    return authenticate(context, 'Unlock ${_note?.fullName ?? 'file'}');
  }

  static const _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  void _toggleLandscape() {
    setState(() => _landscape = !_landscape);
    // LANDSCAPE ONLY, so the screen turns the moment the button is tapped:
    // allowing portrait as well left it upright until the user also turned
    // the phone. Both landscape sides, so it follows whichever way they hold
    // it. The second tap forces portrait back the same way.
    SystemChrome.setPreferredOrientations(
      _landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : _portrait,
    );
  }

  void _lockPortrait() {
    if (_landscape) {
      _landscape = false;
      SystemChrome.setPreferredOrientations(_portrait);
    }
  }

  @override
  void deactivate() {
    _rememberScroll();
    super.deactivate();
  }

  @override
  void dispose() {
    for (final r in _linkTaps) {
      r.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    _secure(false);
    // Always leave the app back in portrait when the editor closes.
    SystemChrome.setPreferredOrientations(_portrait);
    _autosaveDebounce?.cancel();
    _body.dispose();
    _name.dispose();
    _undo.dispose();
    _scroll.dispose();
    _bodyFocus.dispose();
    _part.dispose();
    _freePieceTaps();
    _partFocus.dispose();
    _findCtrl.dispose();
    super.dispose();
  }

  /// The name a save would use. An empty title keeps the note's CURRENT
  /// name: 'Untitled' here would rename "Untitled 2" onto "Untitled".
  String get _effectiveName {
    final typed = _name.text.trim();
    if (typed.isNotEmpty) return typed;
    return _note?.name ?? 'Untitled';
  }

  String get _ext => _note?.ext ?? _newFileExt;

  /// A new note's type: one typed in the title ("plan.md"), else the one
  /// picked when it was started.
  String get _newFileExt {
    final typed = NoteStore.typedExt(_name.text.trim());
    return typed.isNotEmpty ? typed : (_newExt ?? '');
  }

  /// The type picked for this new note (changed from the pill by the title).
  late String? _newExt = widget.newExt;

  /// Whether the file's format can store underline. Only Word and RTF can: Markdown
  /// (and Notepad, which saves formatting as Markdown) has none, so in a
  /// .txt or .md note the bar offers no underline. Text already underlined
  /// there still shows, and Clear formatting removes it.
  bool get _underlineStored =>
      const {'.rtf', '.docx'}.contains(_ext.toLowerCase());

  /// A Word or RTF note: its text is Breeze's own Markdown, where a
  /// backslash keeps a "*" or "- " the document has as plain text.
  bool get _escapes => _underlineStored;

  /// Formatting is on in Settings and this is a note, not code or data.
  bool get _formatOn =>
      SettingsScope.of(context).formatting && mdFormattable(_ext);

  /// The file is code (.py, .js, .json, ...): monospace, no auto-capitals
  /// or autocorrect, and syntax colours when they are on.
  bool get _isCode => codeLanguageFor(_ext) != null;
  String? get _codeLang =>
      SettingsScope.of(context).codeColours ? codeLanguageFor(_ext) : null;

  bool get _big => _body.text.length > _bigRead;

  /// What the format bar acts on: the note, or in a huge file the open part
  /// (its edits reach the note through [_onPartEdited]).
  FormatController get _formatTarget =>
      _big && _editingPart != null ? _part : _body;

  /// A toolbar button: changes the text like typing would (undo included).
  /// Bold (or another) from the bar. With just a cursor: at the end of
  /// bold words it stops bold for what is typed next; elsewhere the
  /// markers wait, hidden, for typing (and go again if nothing is typed).
  TextEditingValue _inlineAt(
    FormatController c,
    TextEditingValue v,
    MdDoc doc,
    int kind,
  ) => inlineAtCursor(c, v, doc, kind);

  Future<void> _format(String action) async {
    final c = _formatTarget;
    final focus = identical(c, _part) ? _partFocus : _bodyFocus;
    if (!c.selection.isValid) {
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
    if (!const {'bold', 'italic', 'strike', 'underline'}.contains(action)) {
      // A heading, list or link with B still waiting: the empty markers go.
      c.clearPending();
    }
    final doc = c.doc;
    var v = c.value;
    final sel = v.selection;
    switch (action) {
      case 'bold':
        v = _inlineAt(c, v, doc, Md.bold);
      case 'italic':
        v = _inlineAt(c, v, doc, Md.italic);
      case 'strike':
        v = _inlineAt(c, v, doc, Md.strike);
      case 'underline':
        if (!_underlineStored) return;
        v = _inlineAt(c, v, doc, Md.underline);
      case 'heading':
        v = setLineKind(v, doc, nextHeading(doc.lineAt(sel.start).kind));
      case 'bullet':
        v = setLineKind(v, doc, MdLineKind.bullet);
      case 'numbered':
        v = setLineKind(v, doc, MdLineKind.numbered);
      case 'clear':
        v = clearFormatting(v, doc);
      case 'link':
        final r = doc.regionAround(Md.link, sel.start, sel.end);
        if (r != null) {
          // Already a link: back to its words.
          final text = v.text
              .replaceRange(r.closeStart, r.closeEnd, '')
              .replaceRange(r.openStart, r.openEnd, '');
          v = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: r.closeStart - 1),
          );
        } else {
          final url = await promptText(
            context,
            title: 'Add link',
            label: 'Web address',
            initial: 'https://',
            confirmLabel: 'Add',
            caps: TextCapitalization.none,
          );
          if (!mounted || url == null) {
            focus.requestFocus();
            return;
          }
          var u = url.trim().replaceAll(' ', '%20');
          if (u.isEmpty || u == 'https://') {
            focus.requestFocus();
            return;
          }
          if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(u)) {
            u = 'https://$u';
          }
          // The prompt took the focus; the text may not have changed.
          // The part may have been closed while the prompt was up.
          if (!identical(c, _formatTarget)) return;
          v = insertLink(c.value.copyWith(selection: sel), u);
        }
    }
    if (v == c.value) {
      // Nothing written (B tapped with nothing selected): the bar shows it.
      c.touch();
      focus.requestFocus();
      return;
    }
    c.value = v;
    if (identical(c, _body)) _onBodyChanged('');
    focus.requestFocus();
  }

  bool get _hasChanges =>
      _body.text != _savedText || _effectiveName != _savedName;

  void _onBodyChanged(String _) {
    if (!_dirty) setState(() => _dirty = true);
    final s = SettingsScope.of(context);
    if (s.autosave) {
      _autosaveDebounce?.cancel();
      _autosaveDebounce = Timer(
        const Duration(milliseconds: 900),
        // Not while the type is being picked: the file would be made with
        // the old type and the pick then ignored.
        () {
          if (!_pickingType) _save(silent: true);
        },
      );
    }
    if (_finding) _recomputeMatches();
  }

  /// The save in flight. Saves run ONE AT A TIME: an autosave and a back
  /// press used to run together, both see "no file yet" and create
  /// "Untitled" twice, or both rename and leave "B 2" behind.
  Future<bool>? _saving;

  /// Set while back is being handled, so a fast double back cannot run two
  /// exits and pop Home as well.
  bool _closing = false;

  /// Saves, after any save already running. True when the file is written.
  Future<bool> _save({bool silent = false, bool hold = false}) {
    final prev = _saving;
    final run = () async {
      if (prev != null) await prev;
      try {
        await _saveNow(silent: silent, hold: hold);
        return true;
      } catch (_) {
        if (mounted) {
          showToast(
            context,
            message: 'Could not save this file',
            icon: CupertinoIcons.exclamationmark_triangle,
          );
        }
        return false;
      }
    }();
    _saving = run;
    return run;
  }

  /// The message a save with `hold` kept back, for the caller to show once
  /// the screen has settled.
  String? _heldToast;

  /// With [hold], the "Saved" message is kept in [_heldToast] instead of
  /// shown: the tick shows it once the keyboard has closed.
  Future<void> _saveNow({bool silent = false, bool hold = false}) async {
    void say(String message) {
      if (hold) {
        _heldToast = message;
      } else {
        showToast(
          context,
          message: message,
          icon: CupertinoIcons.checkmark_alt,
        );
      }
    }

    if (!mounted || !_ready) return;
    // Never rewritten: it would lose what Breeze cannot keep.
    if (_rtfReadOnly || _rtfForeign || _binary) return;
    if (!_hasChanges && _note != null) {
      // Autosave got there first: the tick still says it is saved, or a
      // press with no answer reads as a save that did not happen.
      if (!silent && mounted) say('Saved');
      return;
    }
    // A new note typed and then emptied again is not a note: no empty
    // "Untitled.txt" left behind.
    if (_note == null &&
        _body.text.trim().isEmpty &&
        _name.text.trim().isEmpty) {
      return;
    }
    final store = NoteScope.of(context);
    final content = _body.text;
    final onDisk = _crlf
        ? content.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')
        : content;
    var name = _effectiveName;
    // The title as it was when this save began: letters typed while it
    // runs must not be overwritten when it ends.
    final typedAtStart = _name.text.trim();
    if (_note == null) {
      // The picked type, unless the title names one.
      final picked = _newExt;
      var exact = false;
      if (picked != null && NoteStore.typedExt(name).isEmpty) {
        name = '$name$picked';
        exact = true;
      }
      // A name ending .rtf makes an RTF document.
      _note = await store.create(
        name,
        content: content,
        rtf: true,
        exact: exact,
      );
      if (NoteStore.docKind(_note!.file.path).isNotEmpty) {
        _rtf = RtfRead(content, const []);
      }
      final tag = widget.tag;
      if (tag != null) {
        await store.setTags(_note!, [tag]);
        final path = _note!.path;
        _note = store.notes.firstWhere(
          (n) => n.path == path,
          orElse: () => _note!,
        );
      }
    } else {
      final oldPath = _note!.path;
      // Whether the file is to be a document (RTF, Word). A rename to another
      // kind (.rtf to .docx, .txt to .rtf) changes what the bytes must be,
      // so it is a save.
      final kind = _plainRtf
          ? ''
          : NoteStore.docKind(store.extFor(_note!, name));
      final oldKind = _rtf == null ? '' : NoteStore.docKind(_note!.file.path);
      final toRtf = kind.isNotEmpty;
      // Only the name changed: rename the file, never rewrite its bytes.
      _note = content == _savedText && _note!.uri == null && kind == oldKind
          ? await store.rename(_note!, name)
          : await store.save(
              _note!,
              onDisk,
              newName: name,
              charset: _charset,
              rtf: !_plainRtf,
            );
      _rtf = toRtf ? RtfRead(content, const []) : null;
      if (_note!.path != oldPath && mounted) {
        SettingsScope.of(context).setScrollFor(oldPath, 0);
      }
    }
    _savedText = content;
    _savedName = _note!.name;
    // The file may have been named differently from what was typed
    // ("Todo" -> "Todo 2" when Todo exists, "notes.md" -> "notes"). Show
    // the real name, or the field never matches and every exit re-saves.
    final typed = _name.text.trim();
    if (typed == typedAtStart && typed.isNotEmpty && typed != _note!.name) {
      final renamed = typed != _note!.fullName;
      _name.text = _note!.name;
      if (renamed && mounted) {
        say('Saved as ${_note!.fullName}');
        silent = true;
      }
    }
    if (mounted) {
      setState(() => _dirty = false);
      if (!silent) say('Saved');
    }
  }

  Future<bool> _onWillPop() async {
    if (_closing) return false;
    _closing = true;
    // A pending autosave would run AFTER this save and race it.
    _autosaveDebounce?.cancel();
    final s = SettingsScope.of(context);
    var leave = true;
    if (_saving != null) await _saving;
    if (mounted && _ready && _hasChanges) {
      if (s.autosave && (_body.text.trim().isNotEmpty || _note != null)) {
        leave = await _save(silent: true);
        if (!leave && mounted) {
          // Could not save (read-only file, name too long): offer the way
          // out instead of refusing every back press.
          final discard = await askConfirm(
            context,
            title: 'Could not save',
            message: 'Leave without saving your changes?',
            confirmLabel: 'Discard',
            cancelLabel: 'Stay',
            danger: true,
          );
          leave = discard ?? false;
        }
      } else if (_body.text.trim().isNotEmpty || _note != null) {
        // An existing note emptied, or renamed, still asks: leaving
        // quietly threw that change away.
        // Dismissing the sheet (back, swipe, tap outside) means "not yet",
        // never Discard: losing edits needs the Discard button itself.
        final save = await askConfirm(
          context,
          title: 'Save changes?',
          confirmLabel: 'Save',
          cancelLabel: 'Discard',
        );
        if (save == null) {
          leave = false;
        } else if (save) {
          leave = await _save(silent: true);
        }
      }
    }
    if (!leave) _closing = false;
    return leave;
  }

  // -- find ------------------------------------------------------------
  void _recomputeMatches() {
    final q = _findCtrl.text;
    final m = findRanges(_body.text, q);
    setState(() {
      _matches = m;
      _matchIndex = m.isEmpty ? 0 : _matchIndex.clamp(0, m.length - 1);
    });
    _scrollToMatch();
  }

  void _scrollToMatch() {
    if (_matches.isEmpty) return;
    final (a, b) = _matches[_matchIndex];
    // The match is shown highlighted in the reading view while Find is open
    // (in edit mode too). Focus never moves into the note: it did, and the
    // next letters typed into the Find box replaced the match in the text.
    // The cursor waits at the match for when Find closes.
    if (b <= _body.text.length) {
      _body.selection = TextSelection(baseOffset: a, extentOffset: b);
    }
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    double target;
    if (_body.text.length > _bigRead) {
      // Drawn a piece at a time: aim for the piece holding the match.
      _syncChunks();
      final i = _chunks.indexWhere((c) => c.$1 <= a && a < c.$2);
      target = _chunks.isEmpty || i < 0 ? 0 : max * i / _chunks.length;
    } else {
      target = _body.text.isEmpty ? 0 : max * a / _body.text.length;
    }
    _scroll.animateTo(
      target.clamp(0.0, max),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _stepMatch(int dir) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + dir) % _matches.length);
    if (_matchIndex < 0) _matchIndex += _matches.length;
    _scrollToMatch();
  }

  // -- overflow menu ---------------------------------------------------
  Future<void> _overflow() async {
    if (_locked) return;
    final choice = await showGlassMenu<String>(
      context,
      grid: true,
      items: [
        ('undo', CupertinoIcons.arrow_uturn_left, 'Undo', false),
        ('redo', CupertinoIcons.arrow_uturn_right, 'Redo', false),
        ('find', CupertinoIcons.search, 'Find', false),
        ('pdf', CupertinoIcons.share, 'Share PDF', false),
        ('print', CupertinoIcons.printer, 'Print', false),
        ('top', CupertinoIcons.arrow_up_to_line, 'Top', false),
        ('bottom', CupertinoIcons.arrow_down_to_line, 'Bottom', false),
        ('info', CupertinoIcons.info_circle, 'File info', false),
      ],
    );
    switch (choice) {
      case 'undo':
        _undo.undo();
        _onBodyChanged('');
      case 'redo':
        _undo.redo();
        _onBodyChanged('');
      case 'find':
        setState(() => _finding = true);
      case 'print':
        _print();
      case 'pdf':
        _sharePdf();
      case 'top':
        if (_scroll.hasClients) {
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      case 'bottom':
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      case 'info':
        _showInfo();
    }
  }

  Future<void> _print() async {
    if (_locked) return;
    final name = _pdfTitle;
    try {
      final bytes = await _pdfBytes();
      if (bytes == null) return;
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not print this file',
          icon: CupertinoIcons.printer,
        );
      }
    }
  }

  Future<void> _sharePdf() async {
    if (_locked) return;
    final name = _pdfTitle;
    try {
      final bytes = await _pdfBytes();
      if (bytes == null) return;
      final file = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${file.isEmpty ? 'Document' : file}.pdf',
      );
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not make a PDF of this file',
          icon: CupertinoIcons.share,
        );
      }
    }
  }

  /// The note's size as saved: its own line ends and encoding.
  int _onDiskSize() {
    final t = _body.text;
    final text = _crlf
        ? t.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')
        : t;
    final n = _note;
    if (_rtf != null && _rtf!.editable && n != null) {
      // A document is built to measure it, which takes seconds for a big
      // one: unchanged, the saved file's own size is the answer.
      if (!_hasChanges || t.length > 200000) return n.size;
      try {
        return NoteStore.isDocx(n.file.path)
            ? writeDocx(t).length
            : writeRtf(t).length;
      } catch (_) {}
    }
    if (_rtfReadOnly && n != null) return n.size;
    return encodeText(
      text,
      n != null && n.uri != null ? n.charset : _charset,
    ).length;
  }

  /// "a, b and c".
  static String _listWords(List<String> w) => w.length < 2
      ? w.join()
      : '${w.sublist(0, w.length - 1).join(', ')} and ${w.last}';

  /// A document Breeze cannot keep whole: say what is in it, and offer a
  /// copy to edit (an .rtf in Breeze, holding what Breeze shows). The
  /// original is left as it is.
  Future<void> _offerCopy() async {
    final r = _rtf;
    final n = _note;
    if (r == null || n == null) return;
    final what = _listWords(r.unsupported);
    final ok = await showConfirm(
      context,
      title: 'Edit a copy?',
      message:
          'This document has $what, which Breeze can show but not keep. '
          'To leave it whole, Breeze edits a copy instead. The copy keeps '
          'the text, headings, lists, links, bold, italic, underline and '
          'strikethrough.',
      confirmLabel: 'Edit a copy',
    );
    if (!ok || !mounted) return;
    await _editCopy();
  }

  /// An RTF document another app wrote (Word, TextEdit...), not yet agreed
  /// to be rewritten in Breeze's look.
  bool get _rtfForeign =>
      _rtf != null && _rtf!.editable && !_rtf!.native && !_foreignOk;
  bool _foreignOk = false;

  /// Before the first edit of another app's document: say what saving
  /// changes, and offer a copy instead.
  Future<void> _confirmForeignEdit() async {
    final edit = await askConfirm(
      context,
      title: 'Edit this document?',
      // A Word file keeps its body font, text size and page when saved over
      // (docxLook); an RTF file is written in Breeze's own look.
      message: _ext == '.docx'
          ? 'Breeze keeps its text, headings, lists, links, bold, italic, '
                'underline and strikethrough, and its font, text size and '
                'page. When it is saved, its line spacing, heading look and '
                'document details (title, author) become Breeze\'s.'
          : 'Breeze keeps its text, headings, lists, links, bold, italic, '
                'underline and strikethrough. When it is saved, its font, '
                'text size, bullet style, spacing, page layout and document '
                'details '
                '(title, author) become Breeze\'s.',
      confirmLabel: 'Edit',
      cancelLabel: 'Edit a copy',
    );
    if (edit == null || !mounted) return;
    if (!edit) {
      await _editCopy();
      return;
    }
    setState(() {
      _foreignOk = true;
      _editing = true;
      _lockPortrait();
    });
  }

  /// Make an .rtf copy of what is shown, and open it to edit.
  Future<void> _editCopy() async {
    final n = _note;
    if (n == null) return;
    final store = NoteScope.of(context);
    final Note copy;
    try {
      copy = await store.create(
        // The same kind of document: a Word file's copy is a Word file.
        '${n.name} (copy)${NoteStore.isDocx(n.file.path) ? '.docx' : '.rtf'}',
        content: _body.text,
        rtf: true,
      );
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          message: 'Could not make a copy',
          icon: CupertinoIcons.exclamationmark_triangle,
        );
      }
      return;
    }
    // The copy is as private as the file: a locked file's copy is locked
    // (else its text showed in previews, search and share), and keeps tags.
    var opened = copy;
    if (n.locked || n.tags.isNotEmpty) {
      try {
        if (n.tags.isNotEmpty) await store.setTags(copy, n.tags);
        if (n.locked) await store.setLocked(copy, true);
      } catch (_) {
        // The copy exists; open it rather than strand it unseen.
      }
      opened = store.notes.firstWhere(
        (x) => x.path == copy.path,
        orElse: () => copy,
      );
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => EditorScreen(note: opened, edit: true)),
    );
  }

  /// The line over a read-only document saying why, with the way out.
  Widget _readOnlyNote(Pal p) => Padding(
    padding: EdgeInsets.fromLTRB(16.dp, 0, 16.dp, 8.dp),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _offerCopy,
      child: GlassSurface(
        radius: 16.dp,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14.dp, vertical: 10.dp),
          child: Row(
            children: [
              Icon(CupertinoIcons.lock, size: 16.sp, color: p.sub),
              SizedBox(width: 10.dp),
              Expanded(
                child: Text(
                  'Read only: has ${_listWords(_rtf!.unsupported)}',
                  style: TextStyle(color: p.sub, fontSize: 13.sp),
                ),
              ),
              SizedBox(width: 8.dp),
              Text(
                'Edit a copy',
                style: TextStyle(
                  color: p.accent,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String get _pdfTitle =>
      _name.text.trim().isEmpty ? 'Document' : _name.text.trim();

  /// The note as a PDF. A long note takes a moment, so it says so; null when
  /// the editor closed meanwhile.
  Future<Uint8List?> _pdfBytes() async {
    final text = _body.text;
    if (text.length > 20000 && mounted) {
      showToast(
        context,
        message: 'Making the PDF…',
        icon: CupertinoIcons.doc_text,
      );
    }
    final bytes = await buildNotePdf(
      _pdfTitle,
      text,
      formatted: _body.formatting,
      escapes: _escapes,
      codeLanguage: codeLanguageFor(_ext),
      colours: SettingsScope.of(context).codeColours,
    );
    return mounted ? bytes : null;
  }

  Future<void> _showInfo() async {
    if (_locked) return;
    final st = TextStats(_body.text);
    await showGlassSheet(
      context,
      builder: (ctx) {
        final p = Pal.of(ctx);
        Widget line(String k, String v) => Padding(
          padding: EdgeInsets.symmetric(vertical: 6.dp),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  k,
                  style: TextStyle(color: p.sub, fontSize: 14.sp),
                ),
              ),
              Text(
                v,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 14.5.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(22.dp, 14.dp, 22.dp, 22.dp),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'File info',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 10.dp),
              if (_note != null) line('Name', _note!.fullName),
              line('Size', humanSize(_onDiskSize())),
              line('Words', '${st.words}'),
              line('Characters (all)', '${st.characters}'),
              line('Characters (no spaces)', '${st.charactersNoSpaces}'),
              line('Lines', '${st.lines}'),
              if (_note != null)
                line(
                  'Modified',
                  fullDate(
                    _note!.modified,
                    h24: MediaQuery.alwaysUse24HourFormatOf(context),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // -- build -----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final s = SettingsScope.of(context);
    _body
      ..formatting = _formatOn
      ..escapes = _escapes
      ..codeLanguage = _codeLang
      ..pal = p;
    _part
      ..formatting = _formatOn
      ..escapes = _escapes
      ..codeLanguage = _codeLang
      ..pal = p;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          setState(() => _finding = !_finding);
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          setState(() => _finding = !_finding);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_finding) {
            setState(() {
              _finding = false;
              _findCtrl.clear();
              _matches = const [];
            });
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _onWillPop();
        if (ok && context.mounted) Navigator.of(context).pop();
      },
      child: GlassScaffold(
        background: const GradientBackground(),
        statusBarStyle: p.dark
            ? GlassStatusBarStyle.light
            : GlassStatusBarStyle.dark,
        appBar: GlassAppBar(
          centerTitle: false,
          leading: Padding(
            padding: EdgeInsets.only(left: 8.dp),
            child: RoundGlassButton(
              icon: CupertinoIcons.chevron_back,
              semanticLabel: 'Back',
              onPressed: () async {
                final ok = await _onWillPop();
                if (ok && context.mounted) Navigator.of(context).pop();
              },
            ),
          ),
          // Reading: the name has the whole bar (its actions are at the
          // bottom), and a long one wraps rather than ending in "...".
          // Reading: the bar is Back alone; the name is the page's heading
          // (below), where a long one has room to wrap.
          title: null,
          // While locked the bar offers nothing: Print and File info read
          // the text that is still held after a re-lock.
          actions: _locked || !_editing
              ? const []
              : [
                  Padding(
                    padding: EdgeInsets.only(right: 10.dp),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Landscape for comfortable reading; only in read mode.
                        if (!_editing) ...[
                          RoundGlassButton(
                            icon: _landscape
                                ? Icons.stay_current_portrait_rounded
                                : Icons.screen_rotation_rounded,
                            bold: !_landscape,
                            semanticLabel: _landscape
                                ? 'Back to portrait'
                                : 'Rotate for reading',
                            onPressed: _toggleLandscape,
                          ),
                          SizedBox(width: 8.dp),
                        ],
                        RoundGlassButton(
                          icon: _editing
                              ? Icons.visibility_rounded
                              : Icons.edit_rounded,
                          semanticLabel: _editing ? 'Read mode' : 'Edit',
                          onPressed: _toggleEdit,
                        ),
                        SizedBox(width: 8.dp),
                        RoundGlassButton(
                          icon: CupertinoIcons.ellipsis,
                          semanticLabel: 'More',
                          onPressed: _overflow,
                        ),
                        // Save is the screen's one primary action: the only filled
                        // button, last in the row where the thumb ends up.
                        if (_editing) ...[
                          SizedBox(width: 8.dp),
                          RoundGlassButton(
                            icon: CupertinoIcons.checkmark_alt,
                            semanticLabel: 'Save',
                            // Accent glass, as the home screen's + button: the
                            // colour reads through the pane rather than over it.
                            gradient: p.accentFill,
                            iconColor: Colors.white,
                            // Saves, closes the editor into the read view,
                            // and says "Saved" once the keyboard is down: a
                            // message shown while it slides away is missed.
                            onPressed: () async {
                              HapticFeedback.selectionClick();
                              _heldToast = null;
                              final saved = await _save(hold: true);
                              if (!mounted) return;
                              if (saved &&
                                  _editing &&
                                  _note != null &&
                                  !_hasChanges) {
                                _toggleEdit();
                                await _keyboardClosed();
                              }
                              final message = _heldToast;
                              _heldToast = null;
                              if (message != null && mounted) {
                                showToast(
                                  this.context,
                                  message: message,
                                  icon: CupertinoIcons.checkmark_alt,
                                );
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
        ),
        body: _locked
            ? _lockedView(p)
            : _loading
            ? const SizedBox.shrink()
            : Listener(
                onPointerDown: (_) {
                  if (!_editing) FocusManager.instance.primaryFocus?.unfocus();
                },
                child: Stack(
                  children: [
                    Column(
                      children: [
                        SizedBox(height: GlassAppBar.bottomOf(context)),
                        if (_editing) _editHeader(p) else _readHeader(p),
                        if (_rtfReadOnly && !_editing) _readOnlyNote(p),
                        Expanded(
                          child: _editing && !_finding
                              ? _editArea(p, s)
                              : _readArea(p, s),
                        ),
                        // A huge file is formatted in the part being edited,
                        // so the bar shows once a part is open.
                        if (_editing &&
                            _formatOn &&
                            !_finding &&
                            (!_big || _editingPart != null))
                          ListenableBuilder(
                            listenable: _formatTarget,
                            builder: (_, _) => FormatBar(
                              state: formatStateOf(_formatTarget),
                              onAction: _format,
                              underline: _underlineStored,
                            ),
                          ),
                      ],
                    ),
                    if (!_editing && !_finding)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: 820.dp),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _viewBar(p),
                            ],
                          ),
                        ),
                      ),
                    if (_finding)
                      Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: 760.dp),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _findBar(p),
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

  /// Read mode <-> edit mode (a read-only or foreign document asks first).
  /// Waits (frame by frame, at most a second) until the keyboard is fully
  /// down.
  Future<void> _keyboardClosed() async {
    for (var i = 0; i < 60 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (View.of(context).viewInsets.bottom == 0) {
        // One more frame so the last of the slide has been drawn.
        await WidgetsBinding.instance.endOfFrame;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  void _toggleEdit() {
    if (_binary) {
      showToast(
        context,
        message:
            "A binary file can't be edited as text: saving would damage it",
        icon: CupertinoIcons.lock,
      );
      return;
    }
    if (_rtfReadOnly) {
      _offerCopy();
    } else if (!_editing && _rtfForeign) {
      _confirmForeignEdit();
    } else {
      setState(() {
        _editing = !_editing;
        if (!_editing) {
          _bodyFocus.unfocus();
        } else {
          // Editing is portrait-only.
          _lockPortrait();
        }
      });
    }
  }

  /// Reading: the actions float bottom-right, in the same glass pill as
  /// Home's bottom-left one, so the top bar is the file's name alone.
  Widget _viewBar(Pal p) {
    Widget icon(IconData i, String label, VoidCallback onTap) => GlassPress(
      onTap: onTap,
      label: label,
      child: Padding(
        padding: EdgeInsets.all(12.dp),
        child: Icon(i, size: 22.dp, color: p.ink),
      ),
    );
    return Positioned(
      right: 16.dp,
      bottom: MediaQuery.paddingOf(context).bottom + 14.dp,
      child: GlassSurface(
        radius: 28.dp,
        thick: true,
        padding: EdgeInsets.symmetric(horizontal: 6.dp, vertical: 4.dp),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon(
              _landscape
                  ? Icons.stay_current_portrait_rounded
                  : Icons.screen_rotation_rounded,
              _landscape ? 'Back to portrait' : 'Rotate for reading',
              _toggleLandscape,
            ),
            if (!_binary)
              icon(
                _rtfReadOnly
                    ? CupertinoIcons.doc_on_doc
                    : CupertinoIcons.square_pencil,
                _rtfReadOnly ? 'Edit a copy' : 'Edit',
                _toggleEdit,
              ),
            icon(CupertinoIcons.ellipsis, 'More', _overflow),
          ],
        ),
      ),
    );
  }

  /// Reading: the file's name as the page's heading, whole (up to three
  /// lines), its type beneath, and the same divider edit mode draws, so the
  /// title does not jump when switching.
  Widget _readHeader(Pal p) {
    final n = _note;
    if (n == null) return SizedBox(height: 10.dp);
    final ext = n.ext;
    final look = FileLook.of(ext);
    final typeName = switch (ext) {
      _ when _binary => 'Binary',
      '.docx' => 'Word document',
      '.rtf' => 'RTF document',
      '.txt' || '.text' || '.note' => 'Text',
      _ =>
        // Its name when Breeze knows it ("Table (CSV)"), else what it is
        // read as: never the extension in capitals beside the extension.
        identical(look, FileLook.data) || identical(look, FileLook.text)
            ? fileKindName(ext)
            : look.label,
    };
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.dp, 10.dp, 20.dp, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                n.name.isEmpty ? n.fullName : n.name,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 22.sp,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
              SizedBox(height: 6.dp),
              // One meta line: type badge, kind and where it lives, with a small
              // folder button at the end that opens that folder in Files.
              if (!_binary && n.external && n.uri != null)
                FutureBuilder<FileWhere>(
                  future: _where ??= locateFile(n.uri!),
                  builder: (_, w) =>
                      _metaLine(p, look, ext, typeName, w.data, uri: n.uri),
                )
              else
                _metaLine(
                  p,
                  look,
                  ext,
                  typeName,
                  null,
                  note: _binary
                      ? 'Read only'
                      : n.external
                      ? 'Opened file'
                      : null,
                ),
              SizedBox(height: 10.dp),
              Container(height: 0.8.dp, color: p.faint),
              SizedBox(height: 6.dp),
            ],
          ),
        ),
      ),
    );
  }

  /// Badge, kind, and (for an opened file) its folder; when the phone's
  /// Files app can open that folder, a round folder button ends the line.
  Widget _metaLine(
    Pal p,
    FileLook look,
    String ext,
    String typeName,
    FileWhere? at, {
    String? uri,
    String? note,
  }) {
    final place = at?.where ?? note;
    final canShow = uri != null && at?.canShow == true;
    return SizedBox(
      height: 34.dp,
      child: Row(
        children: [
          FileBadge(look: look, size: 22.dp),
          SizedBox(width: 8.dp),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: ext.isEmpty && !_binary ? 'Text' : typeName,
                    style: TextStyle(
                      color: look.ink(p),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (place != null) TextSpan(text: '  ·  $place'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.sub,
                fontSize: 13.5.sp,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (canShow)
            Semantics(
              button: true,
              label: 'Show in Files, ${at!.where}',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  HapticFeedback.selectionClick();
                  if (!await showFileInFiles(uri) && mounted) {
                    showToast(
                      context,
                      message: 'No file manager could open its folder',
                      icon: CupertinoIcons.folder,
                    );
                  }
                },
                child: GlassSurface(
                  radius: 17.dp,
                  child: SizedBox(
                    width: 34.dp,
                    height: 34.dp,
                    child: Icon(
                      CupertinoIcons.folder,
                      size: 17.dp,
                      color: p.ink.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// txtpad-style header: the file name, a divider beneath it, and the Save
  /// button straddling that divider on the right.
  Widget _editHeader(Pal p) {
    final title = TextStyle(
      color: p.ink,
      fontSize: 22.sp,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    );
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.dp, 10.dp, 20.dp, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      selectionWidthStyle: BoxWidthStyle.tight,
                      // Off: the app is scaled to fit width, which puts Android's
                      // loupe in the wrong place and leaves it stuck on screen.
                      magnifierConfiguration: TextMagnifierConfiguration.disabled,
                      controller: _name,
                      // A file opened from elsewhere keeps its name (Android gives no
                      // right to rename it); an editable title only snapped back.
                      readOnly: _note?.uri != null,
                      cursorColor: p.accent,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (_) => _onBodyChanged(''),
                      // A long name wraps (as in view mode) instead of scrolling
                      // out of sight; it is still one line, so Enter moves on.
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _bodyFocus.requestFocus(),
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp('[\r\n]')),
                      ],
                      style: title,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 8.dp),
                        hintText: 'Untitled',
                        hintStyle: title.copyWith(color: p.sub),
                      ),
                    ),
                  ),
                  if (_note == null && widget.newExt != null) _typePill(p),
                ],
              ),
              SizedBox(height: 8.dp),
              // Inset to the text margins, so it belongs to the title rather than
              // cutting the screen in two.
              Container(height: 0.8.dp, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }

  /// A new note's type beside its title ("Markdown .md"): tap to change it
  /// before the first save.
  Widget _typePill(Pal p) {
    final ext = _newFileExt;
    return Semantics(
      button: true,
      label: 'File type ${fileKindName(ext)} $ext. Change',
      child: GestureDetector(
        onTap: _changeType,
        child: Container(
          margin: EdgeInsets.only(left: 8.dp),
          padding: EdgeInsets.symmetric(horizontal: 10.dp, vertical: 6.dp),
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: p.dark ? 0.14 : 0.10),
            borderRadius: BorderRadius.circular(16.dp),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ext,
                style: TextStyle(
                  color: p.accent,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 4.dp),
              Icon(CupertinoIcons.chevron_down, size: 12.dp, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }

  bool _pickingType = false;

  Future<void> _changeType() async {
    final settings = SettingsScope.of(context);
    _pickingType = true;
    final String? ext;
    try {
      ext = await showNewFileKind(context, last: _newFileExt);
    } finally {
      _pickingType = false;
    }
    if (!mounted) return;
    // Held back while the sheet was open: saved now, with the new type.
    if (ext == null) {
      if (_hasChanges) _onBodyChanged('');
      return;
    }
    settings.newFileExt = ext;
    setState(() {
      _newExt = ext;
      // A type typed in the title would win over the pick: drop it.
      final typed = _name.text.trim();
      final own = NoteStore.typedExt(typed);
      if (own.isNotEmpty) {
        _name.text = typed.substring(0, typed.length - own.length);
      }
    });
    if (_hasChanges) _onBodyChanged('');
  }

  TextStyle _textStyle(Pal p, Settings s) {
    final mono = s.monospace || _isCode;
    return TextStyle(
      color: p.ink,
      // Code a size down: its lines are long.
      fontSize: (_isCode ? s.textSize - 1.5 : s.textSize).sp,
      height: 1.5,
      fontFamily: mono ? 'monospace' : 'Inter',
      fontFamilyFallback: mono ? const ['monospace'] : null,
    );
  }

  Widget _editArea(Pal p, Settings s) {
    if (_body.text.length > _bigRead) return _bigEditArea(p, s);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: UnderlinedField(
          controller: _body,
          scroll: _scroll,
          child: TextField(
            selectionWidthStyle: BoxWidthStyle.tight,
            // Off: the app is scaled to fit width, which puts Android's
            // loupe in the wrong place and leaves it stuck on screen.
            magnifierConfiguration: TextMagnifierConfiguration.disabled,
            controller: _body,
            focusNode: _bodyFocus,
            undoController: _undo,
            scrollController: _scroll,
            maxLines: null,
            expands: true,
            cursorColor: p.accent,
            keyboardType: TextInputType.multiline,
            // Code: no capitals, corrections or curly quotes from the keyboard.
            textCapitalization: _isCode
                ? TextCapitalization.none
                : TextCapitalization.sentences,
            autocorrect: !_isCode,
            enableSuggestions: !_isCode,
            smartQuotesType: _isCode ? SmartQuotesType.disabled : null,
            smartDashesType: _isCode ? SmartDashesType.disabled : null,
            inputFormatters: [
              HiddenMarkerBackspace(_body),
              ContinueFormatting(_body),
              ListContinuation(() => _body.formatting),
            ],
            onChanged: _onBodyChanged,
            style: _textStyle(p, s),
            // A line of only hidden markers keeps a full line's height.
            strutStyle: StrutStyle.fromTextStyle(_textStyle(p, s)),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(20.dp, 16.dp, 20.dp, 24.dp),
              hintText: 'Your text',
              hintStyle: _textStyle(p, s).copyWith(color: p.sub),
            ),
          ),
        ),
      ),
    );
  }

  // Rebuilt when the background colours arrive (they come after opening).
  final _linkTaps = <GestureRecognizer>[];

  /// A link in the note, opened in the app that handles it. Only web, mail
  /// and phone links: a note is plain text anyone may have written, and a
  /// link to an app's own scheme could act inside that app.
  Future<void> _openLink(String url) async {
    final u = Uri.tryParse(url.trim());
    final ok =
        u != null &&
        const {
          'http',
          'https',
          'mailto',
          'tel',
        }.contains(u.scheme.toLowerCase());
    var opened = false;
    if (ok) {
      try {
        opened =
            await const MethodChannel(
              'breeze/open',
            ).invokeMethod<bool>('openUrl', {'url': u.toString()}) ??
            false;
      } catch (_) {}
    }
    if (!opened && mounted) {
      showToast(
        context,
        message: "Couldn't open this link",
        icon: CupertinoIcons.link,
      );
    }
  }

  Widget _readArea(Pal p, Settings s) => ListenableBuilder(
    listenable: _body,
    builder: (_, _) => _readContent(p, s),
  );

  /// Over this many characters, reading draws the file a piece at a time.
  /// One block of text that size was laid out and painted whole: a 1.4 MB
  /// file took the app from about 360 MB of memory to over 900 MB, enough
  /// for Android to close it on a phone with less to spare.
  static const _bigRead = 100000;
  String? _chunkedText;
  List<(int, int)> _chunks = const [];

  /// The pieces of [_body]'s text, recut only when the text changed from
  /// outside the part being edited (a part's own edits shift them instead,
  /// so the part stays put while it is typed in).
  void _syncChunks() {
    final text = _body.text;
    if (identical(_chunkedText, text)) return;
    _chunkedText = text;
    _chunks = readChunks(text);
    _editingPart = null;
    _freePieceTaps();
  }

  // -- a huge file, edited a part at a time -----------------------------
  // One text field holding the whole of a 1.4 MB file laid it all out: the
  // app went past 800 MB. Here only the part being edited is a field; the
  // rest is drawn a piece at a time, as when reading.
  int? _editingPart;
  final FormatController _part = FormatController();
  final FocusNode _partFocus = FocusNode();

  /// Edit part [i], the cursor at [at] (an offset inside it) or its start.
  void _editPart(int i, {int at = 0}) {
    _syncChunks();
    if (i < 0 || i >= _chunks.length) return;
    if (_editingPart != i) {
      // Its waiting markers out first (into the file's text too).
      _part.clearPending();
      _syncChunks();
      final (a, b) = _chunks[i];
      final t = _body.text.substring(a, b);
      // Detached first: loading part i's text must not be taken as an edit
      // of the part open before it.
      _editingPart = null;
      _part.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: at.clamp(0, t.length)),
      );
      setState(() => _editingPart = i);
    }
    _partFocus.requestFocus();
  }

  /// Any change to the open part (typing, and undo/redo, which change it
  /// without an onChanged) goes into the file's text.
  void _onPartEdited() {
    final i = _editingPart;
    if (i == null || i >= _chunks.length) return;
    final (a, b) = _chunks[i];
    final v = _part.text;
    if (b - a == v.length && _body.text.substring(a, b) == v) {
      return; // a cursor move
    }
    _onPartChanged(v);
  }

  void _onPartChanged(String v) {
    final i = _editingPart;
    if (i == null || i >= _chunks.length) return;
    // The text changed some other way since the parts were cut: their
    // offsets are stale, and splicing with them would duplicate or drop
    // text. Recut instead (this closes the part).
    if (!identical(_chunkedText, _body.text)) {
      setState(_syncChunks);
      return;
    }
    final (next, chunks) = replaceChunk(_body.text, _chunks, i, v);
    _chunks = chunks;
    _chunkedText = next;
    _body.value = TextEditingValue(text: next);
    // The value just set is the same string object: no recut.
    _chunkedText = _body.text;
    _onBodyChanged('');
  }

  Widget _bigEditArea(Pal p, Settings s) {
    _syncChunks();
    final style = _textStyle(p, s);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(20.dp, 8.dp, 20.dp, 120.dp),
          itemCount: _chunks.length + 1,
          itemBuilder: (_, k) {
        if (k == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: 8.dp),
            child: Text(
              'Large file: tap a part to edit it.',
              style: style.copyWith(
                color: p.sub,
                fontSize: (style.fontSize ?? 16) * 0.8,
              ),
            ),
          );
        }
        final i = k - 1;
        if (i == _editingPart) {
          return UnderlinedField(
            controller: _part,
            child: TextField(
              selectionWidthStyle: BoxWidthStyle.tight,
              // Its own undo history per part: undo never brings another
              // part's text into this one.
              key: ValueKey('part$i'),
              magnifierConfiguration: TextMagnifierConfiguration.disabled,
              controller: _part,
              focusNode: _partFocus,
              undoController: _undo,
              maxLines: null,
              cursorColor: p.accent,
              keyboardType: TextInputType.multiline,
              textCapitalization: _isCode
                  ? TextCapitalization.none
                  : TextCapitalization.sentences,
              autocorrect: !_isCode,
              enableSuggestions: !_isCode,
              smartQuotesType: _isCode ? SmartQuotesType.disabled : null,
              smartDashesType: _isCode ? SmartDashesType.disabled : null,
              inputFormatters: [
                HiddenMarkerBackspace(_part),
                ContinueFormatting(_part),
                ListContinuation(() => _part.formatting),
              ],
              style: style,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            ),
          );
        }
        // Read now, not when the list was built: typing in a part shifts
        // the text and the parts after it without rebuilding the list.
        final (a, b) = _chunks[i];
        final piece = _body.text.substring(a, b);
        return LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The cursor goes where the part was tapped, as in a text box.
            onTapUp: (d) {
              final tp = TextPainter(
                text: TextSpan(text: piece, style: style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: box.maxWidth);
              final at = tp.getPositionForOffset(d.localPosition).offset;
              tp.dispose();
              _editPart(i, at: at);
            },
            child: Text(piece, style: style),
          ),
        );
      },
    ),
  ),
);
  }

  /// Link taps of each piece of a huge file, freed when it is drawn again.
  final _pieceTaps = <int, List<GestureRecognizer>>{};

  void _freePieceTaps() {
    for (final l in _pieceTaps.values) {
      for (final r in l) {
        r.dispose();
      }
    }
    _pieceTaps.clear();
  }

  /// Piece [i] of a huge file (starting at [a]), formatted for reading.
  /// Formatting never crosses a line, so a piece is read on its own. A
  /// piece that starts inside a very long line reads that line's rest with
  /// bold, italic and the rest, but never as a list or heading: a zero-width
  /// space in front keeps a "- " or "# " there from starting one.
  TextSpan _bigPieceSpan(
    int i,
    int a,
    String piece,
    TextStyle style,
    Pal p,
    List<Underline> lines,
  ) {
    for (final r in _pieceTaps.remove(i) ?? const <GestureRecognizer>[]) {
      r.dispose();
    }
    final taps = _pieceTaps[i] = <GestureRecognizer>[];
    var head = '';
    var rest = piece;
    if (a > 0 && _body.text.codeUnitAt(a - 1) != 10) {
      final nl = piece.indexOf(String.fromCharCode(10));
      head = nl < 0 ? piece : piece.substring(0, nl + 1);
      rest = nl < 0 ? '' : piece.substring(nl + 1);
    }
    final lead = head.isEmpty
        ? null
        : _shifted('\u200B$head', style, p, taps, lines, 0);
    return TextSpan(
      style: style,
      children: [
        ?lead,
        // After the head as shown (its ** and <u> are not).
        if (rest.isNotEmpty)
          _shifted(
            rest,
            style,
            p,
            taps,
            lines,
            lead?.toPlainText().length ?? 0,
          ),
      ],
    );
  }

  /// [rest] formatted, its underlines moved [by] characters along (it
  /// follows the plain head of its piece).
  TextSpan _shifted(
    String rest,
    TextStyle style,
    Pal p,
    List<GestureRecognizer> taps,
    List<Underline> lines,
    int by,
  ) {
    final own = <Underline>[];
    final span = mdReadSpan(
      parseMd(rest, escapes: _escapes),
      style,
      p,
      onLink: _openLink,
      recognizers: taps,
      underlines: own,
    );
    for (final u in own) {
      lines.add((
        start: u.start + by,
        end: u.end + by,
        size: u.size,
        colour: u.colour,
      ));
    }
    return span;
  }

  Widget _readContent(Pal p, Settings s) {
    final q = _findCtrl.text;
    final style = _textStyle(p, s);
    final text = _body.text;
    if (text.length > _bigRead) {
      _syncChunks();
      final finding = _finding && q.isNotEmpty && _matches.isNotEmpty;
      return SelectionArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 760.dp),
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(20.dp, 0, 20.dp, 120.dp),
              itemCount: _chunks.length,
              itemBuilder: (_, i) {
                final (a, b) = _chunks[i];
                final piece = text.substring(a, b);
                if (finding) {
                  return Text.rich(
                    TextSpan(
                      children: _highlightSpans(style, p, from: a, to: b),
                    ),
                    style: style,
                  );
                }
                if (!_body.formatting) return Text(piece, style: style);
                final lines = <Underline>[];
                final span = _bigPieceSpan(i, a, piece, style, p, lines);
                return lines.isEmpty
                    ? Text.rich(span)
                    : UnderlinedText(span, lines);
              },
            ),
          ),
        ),
      );
    }
    Widget content;
    if (_finding && q.isNotEmpty && _matches.isNotEmpty) {
      content = SelectableText.rich(
        TextSpan(children: _highlightSpans(style, p)),
        style: style,
      );
    } else if (_body.codeLanguage != null && _body.codePieces() != null) {
      content = SelectableText.rich(
        codeSpan(_body.codePieces()!, style, p.dark),
      );
    } else if (_body.formatting &&
        _body.text.length <= FormatController.maxStyled) {
      for (final r in _linkTaps) {
        r.dispose();
      }
      _linkTaps.clear();
      final lines = <Underline>[];
      final span = mdReadSpan(
        _body.doc,
        style,
        p,
        onLink: _openLink,
        recognizers: _linkTaps,
        underlines: lines,
      );
      // Underlines drawn by hand (unbroken under emoji); text without any
      // stays as it was.
      content = lines.isEmpty
          ? SelectableText.rich(span)
          : SelectionArea(child: UnderlinedText(span, lines));
    } else {
      content = SelectableText(_body.text, style: style);
    }
    return SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(20.dp, 0, 20.dp, 120.dp),
      // Centered on large screens / tablets for comfortable reading line length (approx 760dp),
      // full-width on phones.
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760.dp),
          child: SizedBox(width: double.infinity, child: content),
        ),
      ),
    );
  }

  /// The text in [from, to) (the whole note by default) with the find
  /// matches marked.
  List<TextSpan> _highlightSpans(
    TextStyle base,
    Pal p, {
    int from = 0,
    int? to,
  }) {
    final text = _body.text;
    final end = to ?? text.length;
    if (_body.formatting && end - from <= FormatController.maxStyled) {
      if (from > 0 && text.codeUnitAt(from - 1) != 10) {
        // Starts inside a line: that line's rest is drawn as written (a
        // "- " or "# " there is not a list or heading), the rest formatted.
        final nl = text.indexOf('\n', from);
        final head = nl < 0 || nl >= end ? end : nl + 1;
        return [
          ..._formattedHighlight(base, p, from, head, midLine: true),
          if (head < end) ..._formattedHighlight(base, p, head, end),
        ];
      }
      return _formattedHighlight(base, p, from, end);
    }
    return _rawHighlight(base, p, from, end);
  }

  List<TextSpan> _rawHighlight(TextStyle base, Pal p, int from, int end) {
    final text = _body.text;
    final spans = <TextSpan>[];
    var cursor = from;
    // Matches are in order and don't overlap: start at the first one ending
    // inside this piece rather than walking all of them (a common letter in
    // a huge file is 100,000+ matches, for every piece drawn).
    var lo = 0, hi = _matches.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_matches[mid].$2 <= from) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < _matches.length; i++) {
      var (a, b) = _matches[i];
      if (a >= end) break;
      if (b <= from) continue;
      if (a < from) a = from;
      if (b > end) b = end;
      if (a > cursor) spans.add(TextSpan(text: text.substring(cursor, a)));
      spans.add(
        TextSpan(
          text: text.substring(a, b),
          style: TextStyle(
            backgroundColor: (i == _matchIndex
                ? p.accent
                : p.accent.withValues(alpha: 0.35)),
            color: i == _matchIndex ? Colors.white : base.color,
          ),
        ),
      );
      cursor = b;
    }
    if (cursor < end) spans.add(TextSpan(text: text.substring(cursor, end)));
    return spans;
  }

  TextStyle _matchStyle(int i, TextStyle base, Pal p) => TextStyle(
    backgroundColor: i == _matchIndex
        ? p.accent
        : p.accent.withValues(alpha: 0.35),
    color: i == _matchIndex ? Colors.white : base.color,
  );

  /// [from, end) formatted as when reading (no ** or <u> shown), with the
  /// find matches marked.
  List<TextSpan> _formattedHighlight(
    TextStyle base,
    Pal p,
    int from,
    int end, {
    bool midLine = false,
  }) {
    final text = _body.text;
    // Inside a line: a zero-width space in front keeps a "- " or "# " there
    // from reading as a list or heading; it is not drawn.
    final doc = from == 0 && end == text.length
        ? _body.doc
        : parseMd(
            midLine
                ? '\u200B${text.substring(from, end)}'
                : text.substring(from, end),
            escapes: _escapes,
          );
    final shift = midLine ? from - 1 : from;
    final out = <TextSpan>[];
    var k = 0;
    while (k < _matches.length && _matches[k].$2 <= from) {
      k++;
    }
    for (final r in doc.runs) {
      if (r.flags & Md.marker != 0) continue;
      final ra = (midLine && r.start == 0 ? 1 : r.start) + shift;
      final rb = r.end + shift;
      if (ra >= rb) continue;
      final st = mdTextStyle(base, r.flags, p, editing: false);
      while (k < _matches.length && _matches[k].$2 <= ra) {
        k++;
      }
      var pos = ra;
      var m = k;
      while (pos < rb) {
        if (m >= _matches.length || _matches[m].$1 >= rb) {
          out.add(TextSpan(text: text.substring(pos, rb), style: st));
          break;
        }
        final (ma, mb) = _matches[m];
        if (ma > pos) {
          out.add(TextSpan(text: text.substring(pos, ma), style: st));
          pos = ma;
        }
        final e = mb < rb ? mb : rb;
        out.add(
          TextSpan(
            text: text.substring(pos, e),
            style: st.merge(_matchStyle(m, base, p)),
          ),
        );
        pos = e;
        if (mb <= rb) m++;
      }
    }
    return out;
  }

  Widget _findBar(Pal p) {
    return Positioned(
      left: 16,
      right: 16,
      top: GlassAppBar.bottomOf(context) + 8.dp,
      child: GlassSurface(
        radius: 22.dp,
        thick: true,
        padding: EdgeInsets.symmetric(horizontal: 14.dp, vertical: 4.dp),
        child: Row(
          children: [
            Icon(CupertinoIcons.search, size: 16.dp, color: p.sub),
            SizedBox(width: 8.dp),
            Expanded(
              child: TextField(
                selectionWidthStyle: BoxWidthStyle.tight,
                // Off: the app is scaled to fit width, which puts Android's
                // loupe in the wrong place and leaves it stuck on screen.
                magnifierConfiguration: TextMagnifierConfiguration.disabled,
                controller: _findCtrl,
                autofocus: true,
                cursorColor: p.accent,
                style: TextStyle(color: p.ink, fontSize: 14.5.sp),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Find in file',
                  hintStyle: TextStyle(color: p.sub, fontSize: 14.5.sp),
                ),
              ),
            ),
            if (_findCtrl.text.isNotEmpty)
              Text(
                _matches.isEmpty
                    ? '0/0'
                    : '${_matchIndex + 1}/${_matches.length}',
                style: TextStyle(
                  color: p.sub,
                  fontSize: 12.5.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            _findIcon(
              CupertinoIcons.chevron_up,
              'Previous',
              () => _stepMatch(-1),
            ),
            _findIcon(CupertinoIcons.chevron_down, 'Next', () => _stepMatch(1)),
            _findIcon(CupertinoIcons.xmark, 'Close', () {
              setState(() {
                _finding = false;
                _findCtrl.clear();
                _matches = const [];
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget _findIcon(IconData icon, String label, VoidCallback onTap) =>
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(8.dp),
            child: Icon(icon, size: 18.dp, color: Pal.of(context).ink),
          ),
        ),
      );

  Widget _lockedView(Pal p) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.lock_fill, size: 44.dp, color: p.sub),
        SizedBox(height: 14.dp),
        Text(
          'Locked',
          style: TextStyle(
            color: p.ink,
            fontSize: 17.sp,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 16.dp),
        GlassPress(
          onTap: () async {
            final ok = await _authenticate();
            if (ok && mounted) {
              setState(() => _locked = false);
              // Re-locked after leaving the app: the text is still here,
              // edits included. Only a first unlock loads from disk.
              if (!_ready) _loadContent();
            }
          },
          label: 'Unlock',
          child: GlassSurface(
            radius: 22.dp,
            thick: true,
            padding: EdgeInsets.symmetric(horizontal: 22.dp, vertical: 12.dp),
            child: Text(
              'Unlock',
              style: TextStyle(
                color: p.ink,
                fontSize: 15.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
