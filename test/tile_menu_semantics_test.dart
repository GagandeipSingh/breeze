// A file tile hides its children from a screen reader (it reads as one
// button), so its ••• menu must be offered as an action on the tile itself,
// or TalkBack users can never reach Rename, Lock, Share or Delete.
import 'dart:io';

import 'package:breeze/data/note_scope.dart';
import 'package:breeze/data/note_store.dart';
import 'package:breeze/main.dart';
import 'package:breeze/state/settings.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a tile offers its menu to a screen reader', (t) async {
    final handle = t.ensureSemantics();
    SharedPreferences.setMockInitialValues({});
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('breeze/open'),
      (_) async => null,
    );
    late Settings settings;
    late NoteStore store;
    await t.runAsync(() async {
      settings = await Settings.load();
      final base = await Directory.systemTemp.createTemp('breeze_a11y');
      store = await NoteStore.openIn(base);
      await store.create('Reach me.txt', content: 'one');
    });
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: NoteScope(store: store, child: const BreezeApp()),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 60));
    }

    final tile = find.bySemanticsLabel('Reach me.txt').first;
    final node = t.getSemantics(tile);
    final data = node.getSemanticsData();
    final action = data.customSemanticsActionIds!
        .map(CustomSemanticsAction.getAction)
        .firstWhere((a) => a!.label == 'More for Reach me.txt');
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(action!),
    );
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    expect(find.bySemanticsLabel(RegExp('^Rename')), findsWidgets);
    handle.dispose();
  });
}
