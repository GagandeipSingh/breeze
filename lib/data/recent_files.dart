import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A file opened from elsewhere on the phone (Files, Drive, another app),
/// remembered so it can be opened again from "Open file". Breeze keeps no
/// copy: [uri] is the file where it lives, and opening it again reads it
/// from there.
class RecentFile {
  const RecentFile(this.uri, this.name, this.openedAt);
  final String uri;
  final String name;
  final DateTime openedAt;

  Map<String, Object> toJson() => {
    'uri': uri,
    'name': name,
    'at': openedAt.millisecondsSinceEpoch,
  };

  static RecentFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final uri = j['uri'], name = j['name'], at = j['at'];
    if (uri is! String || name is! String || at is! int) return null;
    return RecentFile(uri, name, DateTime.fromMillisecondsSinceEpoch(at));
  }
}

/// The recent list, newest first, kept in the app's preferences.
class RecentFiles {
  RecentFiles._(this._prefs, this._items);

  static const key = 'recent_files_v1';

  /// Android keeps lasting access for a limited number of files per app;
  /// twenty is far inside it and more than a "recent" list needs.
  static const max = 20;

  final SharedPreferences _prefs;
  final List<RecentFile> _items;

  static Future<RecentFiles> load() async {
    final prefs = await SharedPreferences.getInstance();
    final items = <RecentFile>[];
    try {
      final raw = prefs.getString(key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final r = RecentFile.fromJson(j);
          if (r != null && items.every((x) => x.uri != r.uri)) items.add(r);
        }
      }
    } catch (_) {
      // A damaged list starts again empty rather than breaking Open file.
    }
    return RecentFiles._(prefs, items);
  }

  List<RecentFile> get items => List.unmodifiable(_items);

  /// Puts [uri] at the top. Returns the files pushed off the end, whose
  /// lasting access can be given back.
  Future<List<RecentFile>> add(String uri, String name, {DateTime? at}) async {
    _items.removeWhere((r) => r.uri == uri);
    _items.insert(0, RecentFile(uri, name, at ?? DateTime.now()));
    final dropped = <RecentFile>[];
    while (_items.length > max) {
      dropped.add(_items.removeLast());
    }
    await _save();
    return dropped;
  }

  Future<void> remove(String uri) async {
    _items.removeWhere((r) => r.uri == uri);
    await _save();
  }

  Future<void> clear() async {
    _items.clear();
    await _save();
  }

  Future<void> _save() =>
      _prefs.setString(key, jsonEncode([for (final r in _items) r.toJson()]));
}
