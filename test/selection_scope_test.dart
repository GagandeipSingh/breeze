// A selection only ever holds files the user can see. Switching to Pinned
// or Recent must not leave hidden files selected, or Delete would act on
// files that are not on screen.
import 'dart:io';

import 'package:breeze/data/note_scope.dart';
import 'package:breeze/data/note_store.dart';
import 'package:breeze/main.dart';
import 'package:breeze/state/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<NoteStore> boot(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('breeze/open'),
      (_) async => null,
    );
    late Settings settings;
    late NoteStore store;
    await t.runAsync(() async {
      settings = await Settings.load();
      final base = await Directory.systemTemp.createTemp('breeze_sel');
      store = await NoteStore.openIn(base);
      await store.create('Unpinned note.txt', content: 'one');
    });
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: NoteScope(store: store, child: const BreezeApp()),
      ),
    );
    return store;
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 60));
    }
  }

  for (final mode in ['Pinned files', 'Recent files']) {
    testWidgets('a selection does not carry into $mode', (t) async {
      await boot(t);
      await settle(t);
      await t.longPress(find.text('Unpinned note').first);
      await settle(t);
      expect(find.text('1 selected'), findsOneWidget);

      await t.tap(find.bySemanticsLabel(mode).first);
      await settle(t);
      expect(find.text('1 selected'), findsNothing);
    });
  }
}
