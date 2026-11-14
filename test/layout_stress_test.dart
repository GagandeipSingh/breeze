// Every list layout, light and dark, on a narrow phone with the largest text
// the app allows and long names: no overflow anywhere. A RenderFlex overflow
// is reported as an exception, which fails the test.
import 'dart:io';

import 'package:breeze/data/note_scope.dart';
import 'package:breeze/data/note_store.dart';
import 'package:breeze/main.dart';
import 'package:breeze/state/settings.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Where it must fit: the narrowest common phone (840 / 2.625 = 320dp) in
// both themes, then a phone on its side and a tablet both ways.
const _screens = [
  ('320dp phone', Size(840, 1700), 2.625, [false, true]),
  ('phone landscape', Size(2400, 1080), 2.625, [true]),
  ('tablet portrait', Size(1600, 2560), 2.0, [true]),
  ('tablet landscape', Size(2560, 1600), 2.0, [false]),
];

void main() {
  for (final (where, size, ratio, themes) in _screens) {
    for (final dark in themes) {
      for (final layout in ListLayout.values) {
        testWidgets('${layout.name} ${dark ? 'dark' : 'light'} fits on $where '
            'with large text', (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = ratio;
          t.platformDispatcher.textScaleFactorTestValue = 1.4;
          addTearDown(t.view.reset);
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          // One recent file with a long name, so Open file shows its sheet.
          SharedPreferences.setMockInitialValues({
            'recent_files_v1':
                '[{"uri":"content://x/1","name":"A recent file with a very long '
                'name that will not fit on one line.kt","at":1700000000000}]',
          });
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('breeze/open'),
            (_) async => null,
          );
          late Settings settings;
          late NoteStore store;
          late Directory base;
          await t.runAsync(() async {
            settings = await Settings.load();
            settings.appearance = dark ? Appearance.dark : Appearance.light;
            settings.listLayout = layout;
            base = await Directory.systemTemp.createTemp('breeze_stress');
            store = await NoteStore.openIn(base);
            await store.create(
              'A very long file name that keeps going well past the edge of '
              'any phone screen.md',
              content:
                  '# Heading\nSome **bold** words and a long line that '
                  'wraps around the tile more than once to fill the preview.',
            );
            await store.create(
              'मसाला चाय बनाने की पूरी विधि और सामग्री की सूची.txt',
              content: 'दो कप पानी, एक कप दूध, अदरक, इलायची।',
            );
            await store.create('budget.csv', content: 'Item,Cost\nRent,15000');
            await store.create('x.json', content: '{"a": 1}');
            // Many tags, some long: the row must scroll, not overflow.
            for (final t in [
              'Work',
              'Personal projects and ideas',
              'Recipes',
              'Travel',
              'हिंदी नोट्स',
              'Shopping',
              'Very long tag name that goes on',
            ]) {
              await store.addTag(t);
            }
          });
          await t.pumpWidget(
            SettingsScope(
              settings: settings,
              child: NoteScope(store: store, child: const BreezeApp()),
            ),
          );
          Future<void> settle() async {
            for (var i = 0; i < 25; i++) {
              await t.runAsync(
                () => Future.delayed(const Duration(milliseconds: 20)),
              );
              await t.pump(const Duration(milliseconds: 60));
            }
          }

          await settle();
          expect(
            find.textContaining('A very long', findRichText: true),
            findsWidgets,
          );

          // The editor's read header, for a long name, then back.
          await t.tap(
            find.textContaining('A very long', findRichText: true).first,
          );
          await settle();
          await t.binding.handlePopRoute();
          await settle();

          // Settings, scrolled to the end. On a big screen it is fitted to
          // the screen and has nothing to scroll.
          await t.tap(find.byIcon(CupertinoIcons.settings).first);
          await settle();
          final scroll = find.byType(Scrollable);
          if (scroll.evaluate().isNotEmpty) {
            await t.fling(scroll.first, const Offset(0, -3000), 2000);
            await settle();
          }
          await t.binding.handlePopRoute();
          await settle();

          // The tile menu, with its badge header and the long name.
          await t.tap(find.byIcon(CupertinoIcons.ellipsis).first);
          await settle();
          await t.binding.handlePopRoute();
          await settle();

          // The + speed dial and the "What are you making?" sheet.
          await t.tap(find.bySemanticsLabel('New').first);
          await settle();
          await t.tap(find.bySemanticsLabel('New note').first);
          await settle();
          expect(
            find.textContaining('making', findRichText: true),
            findsWidgets,
          );
          // Other: the any-extension picker, with something typed.
          await t.ensureVisible(find.text('Data or code').first);
          await t.tap(find.text('Data or code').first);
          await settle();
          // More turns the same sheet into the list: one sheet, a back arrow.
          expect(find.text('Type any extension, or pick one.'), findsOneWidget);
          expect(find.bySemanticsLabel('Back to file types'), findsOneWidget);
          await t.enterText(find.byType(EditableText).last, 'k');
          await settle();
          // Back returns to the file types, then closes the sheet.
          await t.binding.handlePopRoute();
          await settle();
          expect(
            find.textContaining('making', findRichText: true),
            findsWidgets,
          );
          await t.binding.handlePopRoute();
          await settle();

          // Every tag at once. The button is there only when the chips
          // overflow the row; on a wide screen they all fit and it is not.
          final allTags = find.bySemanticsLabel('All tags');
          if (allTags.evaluate().isNotEmpty) {
            await t.tap(allTags.first);
            await settle();
            expect(find.text('Tags'), findsWidgets);
            await t.tap(find.text('Recipes').last);
            await settle();
          }

          // The clock switches the list to recent files, and back.
          await t.tap(find.byIcon(CupertinoIcons.clock).first);
          await settle();
          expect(find.text('Recently opened'), findsOneWidget);
          expect(find.text('Browse files'), findsOneWidget);
          await t.tap(find.byIcon(CupertinoIcons.clock).first);
          await settle();
          expect(find.text('Recently opened'), findsNothing);

          // The pin shows only pinned files, and back.
          await t.tap(find.bySemanticsLabel('Pinned files').first);
          await settle();
          expect(find.text('Pinned'), findsOneWidget);
          await t.tap(find.bySemanticsLabel('Show all files').first);
          await settle();
          expect(find.text('Pinned'), findsNothing);

          // Trash, empty, then with a file in it.
          await t.runAsync(() async {
            final n = store.notes.firstWhere((n) => n.fullName == 'budget.csv');
            await store.moveToTrash(n);
          });
          await settle();
          await t.tap(find.byIcon(CupertinoIcons.trash).last);
          await settle();
          expect(
            find.textContaining('budget', findRichText: true),
            findsWidgets,
          );

          await t.runAsync(() => base.delete(recursive: true));
        });
      }
    }
  }
}
