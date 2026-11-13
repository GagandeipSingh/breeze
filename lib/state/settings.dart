import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Accent colours the user can pick. Each carries a light and a dark gradient
/// behind the glass, so the refraction always has colour to bend. Breeze opens
/// on Sky.
class Accent {
  const Accent(this.name, this.color, this.light, this.dark);
  final String name;
  final Color color;
  final List<Color> light;
  final List<Color> dark;
}

const accents = <Accent>[
  Accent(
    'Sky',
    Color(0xFF2E8BFF),
    [
      Color(0xFFD7ECFF),
      Color(0xFFC6DBFF),
      Color(0xFFD9E7FF),
      Color(0xFFCFF4EE),
    ],
    [
      Color(0xFF07152E),
      Color(0xFF0B2654),
      Color(0xFF10294C),
      Color(0xFF052A2E),
    ],
  ),
  Accent(
    'Mint',
    Color(0xFF14A37F),
    [
      Color(0xFFD5F5EA),
      Color(0xFFC9EEDF),
      Color(0xFFD8ECFF),
      Color(0xFFF1F6D2),
    ],
    [
      Color(0xFF06221B),
      Color(0xFF0A3A2D),
      Color(0xFF0B2338),
      Color(0xFF1E2A10),
    ],
  ),
  Accent(
    'Iris',
    Color(0xFF6A4CF5),
    [
      Color(0xFFE6E0FF),
      Color(0xFFD4CCFF),
      Color(0xFFF3D6F7),
      Color(0xFFD6E6FF),
    ],
    [
      Color(0xFF130E30),
      Color(0xFF241A57),
      Color(0xFF341544),
      Color(0xFF0E1A3A),
    ],
  ),
  Accent(
    'Coral',
    Color(0xFFF2564B),
    [
      Color(0xFFFFE3D6),
      Color(0xFFFFC7C2),
      Color(0xFFF6D3F0),
      Color(0xFFDCE4FF),
    ],
    [
      Color(0xFF2A0F17),
      Color(0xFF4A1625),
      Color(0xFF2B1640),
      Color(0xFF0F1530),
    ],
  ),
  Accent(
    'Sunset',
    Color(0xFFF08A1D),
    [
      Color(0xFFFFEBD0),
      Color(0xFFFFD6B8),
      Color(0xFFFFCFD9),
      Color(0xFFF4E2FF),
    ],
    [
      Color(0xFF2A1606),
      Color(0xFF45220C),
      Color(0xFF3F1222),
      Color(0xFF231536),
    ],
  ),
  Accent(
    'Graphite',
    Color(0xFF4A5568),
    [
      Color(0xFFEDEFF3),
      Color(0xFFDDE2EA),
      Color(0xFFE6E3EE),
      Color(0xFFDCE6EC),
    ],
    [
      Color(0xFF0E1014),
      Color(0xFF1A1E26),
      Color(0xFF1C1A24),
      Color(0xFF111A1E),
    ],
  ),
];

enum Appearance { system, light, dark }

enum SortBy { name, date }

/// How the home list draws each file.
enum ListLayout { compact, standard, detailed, grid }

/// Everything the user can tune, backed by shared_preferences. Mirrors the
/// txtpad settings surface: Look (theme, text size, monospace), Feel (swipe to
/// delete, autosave, remember scroll, tags, trash), Security (fingerprint
/// lock), and the plumbing (encoding — display only, premium).
class Settings extends ChangeNotifier {
  Settings._(this._prefs);

  static Future<Settings> load() async =>
      Settings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  Appearance get appearance =>
      Appearance.values[(_prefs.getInt('appearance') ?? 0).clamp(0, 2)];
  set appearance(Appearance v) =>
      _set(() => _prefs.setInt('appearance', v.index));

  Accent get accent =>
      accents[(_prefs.getInt('accent') ?? 0).clamp(0, accents.length - 1)];
  int get accentIndex => accents.indexOf(accent);
  set accentIndex(int i) => _set(() => _prefs.setInt('accent', i));

  // Look ---------------------------------------------------------------
  /// Editor/reader text size in logical points, 12..28.
  double get textSize => (_prefs.getDouble('text_size') ?? 18).clamp(12, 28);
  set textSize(double v) =>
      _set(() => _prefs.setDouble('text_size', v.clamp(12, 28)));

  /// The type picked for the last new file, offered first next time.
  String get newFileExt => _prefs.getString('new_file_ext') ?? '.txt';
  set newFileExt(String v) => _set(() => _prefs.setString('new_file_ext', v));

  bool get monospace => _prefs.getBool('monospace') ?? false;
  set monospace(bool v) => _set(() => _prefs.setBool('monospace', v));

  /// Bold, italic, headings and lists in notes (stored as Markdown, like
  /// Windows Notepad). Off: every note is plain text, syntax and all.
  bool get formatting => _prefs.getBool('formatting') ?? true;
  set formatting(bool v) => _set(() => _prefs.setBool('formatting', v));

  /// Syntax colours in code files (.py, .js, .json, ...), as code editors
  /// show them. Only how the text is drawn; nothing is added to the file.
  bool get codeColours => _prefs.getBool('code_colours') ?? true;
  set codeColours(bool v) => _set(() => _prefs.setBool('code_colours', v));

  // Feel ---------------------------------------------------------------
  bool get swipeDelete => _prefs.getBool('swipe_delete') ?? false;
  set swipeDelete(bool v) => _set(() => _prefs.setBool('swipe_delete', v));

  bool get autosave => _prefs.getBool('autosave') ?? true;
  set autosave(bool v) => _set(() => _prefs.setBool('autosave', v));

  bool get rememberScroll => _prefs.getBool('remember_scroll') ?? false;
  set rememberScroll(bool v) =>
      _set(() => _prefs.setBool('remember_scroll', v));

  /// Where a file was left, by path. Not a listened-to setting: written on
  /// leaving the editor, read on opening it.
  double scrollFor(String path) => _prefs.getDouble('scroll:$path') ?? 0;
  void setScrollFor(String path, double offset) {
    if (offset <= 0) {
      _prefs.remove('scroll:$path');
    } else {
      _prefs.setDouble('scroll:$path', offset);
    }
  }

  bool get tagsEnabled => _prefs.getBool('tags_enabled') ?? true;
  set tagsEnabled(bool v) => _set(() => _prefs.setBool('tags_enabled', v));

  bool get trashEnabled => _prefs.getBool('trash_enabled') ?? true;
  set trashEnabled(bool v) => _set(() => _prefs.setBool('trash_enabled', v));

  // Security -----------------------------------------------------------
  bool get lockFiles => _prefs.getBool('lock_files') ?? false;
  set lockFiles(bool v) => _set(() => _prefs.setBool('lock_files', v));

  // List state ---------------------------------------------------------
  SortBy get sortBy =>
      SortBy.values[(_prefs.getInt('sort_by') ?? 1).clamp(0, 1)];
  set sortBy(SortBy v) => _set(() => _prefs.setInt('sort_by', v.index));

  ListLayout get listLayout {
    final saved = _prefs.getInt('list_layout');
    if (saved != null) {
      return ListLayout.values[saved.clamp(0, ListLayout.values.length - 1)];
    }
    // Large screens and unfolded foldables (>= 600 dp) default to Grid for superior UX;
    // phones default to Standard list.
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    final isLarge = view != null &&
        view.physicalSize.shortestSide > 0 &&
        (view.physicalSize.shortestSide / view.devicePixelRatio) >= 600;
    return isLarge ? ListLayout.grid : ListLayout.standard;
  }
  set listLayout(ListLayout v) =>
      _set(() => _prefs.setInt('list_layout', v.index));

  bool get sortAscending => _prefs.getBool('sort_asc') ?? false;
  set sortAscending(bool v) => _set(() => _prefs.setBool('sort_asc', v));

  // Premium ------------------------------------------------------------
  /// Pin, search-inside, undo/redo, print and ad removal sit behind this. It
  /// is a local flag; wire a real purchase later.
  bool get premium => _prefs.getBool('premium') ?? false;
  set premium(bool v) => _set(() => _prefs.setBool('premium', v));

  int? get ageYears => _prefs.getInt('age_years');
  set ageYears(int? v) => _set(
    () =>
        v == null ? _prefs.remove('age_years') : _prefs.setInt('age_years', v),
  );

  void _set(void Function() write) {
    write();
    notifyListeners();
  }
}

/// Makes [Settings] reachable from any widget and rebuilds on change.
class SettingsScope extends InheritedNotifier<Settings> {
  const SettingsScope({
    super.key,
    required Settings settings,
    required super.child,
  }) : super(notifier: settings);

  static Settings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()!.notifier!;
}
