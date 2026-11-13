// The app's scroll physics once made every scrollable "always scrollable",
// the hidden one inside SelectableText too: it took the drag, and read
// mode did not scroll at all while edit mode did.
import 'dart:io';

import 'package:breeze/data/note_scope.dart';
import 'package:breeze/data/note_store.dart';
import 'package:breeze/main.dart';
import 'package:breeze/state/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('read mode scrolls a long note (app scroll physics)', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('breeze/open'),
      (_) async => null,
    );
    late Settings settings;
    late NoteStore store;
    late Directory base;
    await t.runAsync(() async {
      settings = await Settings.load();
      base = await Directory.systemTemp.createTemp('breeze_scroll');
      store = await NoteStore.openIn(base);
      final text = List.generate(
        70,
        (i) => 'Line $i of a long shared note that wraps across the screen.',
      ).join('\n');
      await store.create('Long.txt', content: text);
    });
    await t.pumpWidget(
      SettingsScope(
        settings: settings,
        child: NoteScope(store: store, child: const BreezeApp()),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    await t.tap(find.text('Long', findRichText: true).first);
    await settle();
    final sv = find.byType(SingleChildScrollView);
    final pos = t
        .state<ScrollableState>(
          find
              .descendant(of: sv.first, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    final before = pos.pixels;
    await t.dragFrom(const Offset(200, 600), const Offset(0, -300));
    await settle();
    expect(pos.pixels, greaterThan(before));
    await t.runAsync(() => base.delete(recursive: true));
  });
}
