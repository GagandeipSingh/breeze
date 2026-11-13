import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/note_scope.dart';
import 'data/note_store.dart';
import 'state/settings.dart';
import 'ui/home.dart';
import 'ui/scale.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phones are portrait by default (the editor's read mode allows landscape).
  // Large screens and unfolded foldables (>= 600 dp) support all orientations naturally.
  final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
  final isLargeScreen = view != null &&
      view.physicalSize.shortestSide > 0 &&
      (view.physicalSize.shortestSide / view.devicePixelRatio) >= 600;
  if (!isLargeScreen) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  final settings = await Settings.load();
  final store = await NoteStore.open();
  // Purge trash past 30 days at every launch, not only when Trash is opened.
  unawaited(store.trash());
  runApp(
    SettingsScope(
      settings: settings,
      child: NoteScope(store: store, child: const BreezeApp()),
    ),
  );
}

class BreezeApp extends StatelessWidget {
  const BreezeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final s = SettingsScope.of(context);
    ThemeData theme(Brightness b) => ThemeData(
      brightness: b,
      fontFamily: 'Inter',
      colorSchemeSeed: s.accent.color,
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
      cupertinoOverrideTheme: const CupertinoThemeData(
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(fontFamily: 'Inter'),
        ),
      ),
    );
    return MaterialApp(
      title: 'Breeze',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _StillScroll(),
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: switch (s.appearance) {
        Appearance.system => ThemeMode.system,
        Appearance.light => ThemeMode.light,
        Appearance.dark => ThemeMode.dark,
      },
      builder: (context, child) {
        // The phone's "Font size" setting is honoured, but only up to 1.25x:
        // the app already scales everything to the screen, and the bars,
        // chips and buttons have fixed heights that larger text would
        // overflow. Never smaller than 1x. Reading size in a note is
        // Settings › Text size.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: 1.0,
              maxScaleFactor: 1.25,
            ),
          ),
          child: ScaleToWidth(
            child: ScreenUtilScope(
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        );
      },
      home: const HomeScreen(),
    );
  }
}

/// Lists give a very slight bounce at their ends instead of Android's
/// stretch. The stretch redraws the list through an image filter, which
/// switches off the glass blur while it lasts, so every card flashed clear
/// when overscrolled. iOS's own bounce felt too elastic, so this one barely
/// moves: a hint that the list ended, not rubber.
class _StillScroll extends MaterialScrollBehavior {
  const _StillScroll();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _SubtleBounce(parent: RangeMaintainingScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _SubtleBounce extends BouncingScrollPhysics {
  const _SubtleBounce({super.parent});

  @override
  _SubtleBounce applyTo(ScrollPhysics? ancestor) =>
      _SubtleBounce(parent: buildParent(ancestor));

  // iOS uses 0.52; 0.035 lets the list move only a few points past its end.
  @override
  double frictionFactor(double overscrollFraction) =>
      0.035 * (1 - overscrollFraction) * (1 - overscrollFraction);

  // Stiff and fully damped: back in place at once, no wobble.
  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 0.5, stiffness: 700, ratio: 1.0);
}
