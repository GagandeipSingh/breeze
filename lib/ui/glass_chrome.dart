import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_surface.dart';

/// The app's chrome, drawn with the compass app's glass. These keep the names
/// and arguments the screens used from liquid_glass_widgets, so swapping the
/// package out changed no call site.
///
/// The compass rule holds: only the FLOATING layer is glass. The bar is a
/// light blur behind its controls (so a list scrolled under it stays
/// legible), and the controls on it are the glass.

enum GlassStatusBarStyle { light, dark }

/// A screen over [background], with an optional floating [appBar]. The body
/// runs behind the bar and the status bar; screens pad for it themselves
/// (`pagePadding`).
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    required this.body,
    this.background,
    this.appBar,
    this.statusBarStyle = GlassStatusBarStyle.dark,
  });

  final Widget body;
  final Widget? background;

  /// The widest a screen's content grows. On a tablet or a phone in
  /// landscape the background still fills the screen, but lists, the
  /// editor and the bar sit in a centred column: cards stretched across a
  /// 1,000-wide screen and lines of text that long are hard to read.
  static const double maxContentWidth = 760;
  final GlassAppBar? appBar;
  final GlassStatusBarStyle statusBarStyle;

  @override
  Widget build(BuildContext context) {
    final overlay = statusBarStyle == GlassStatusBarStyle.light
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      // The background sits OUTSIDE the Scaffold: the Scaffold shrinks its
      // body when the keyboard opens, and a background inside it would be
      // squeezed and redrawn (the sky visibly jumps). Out here it always
      // fills the whole screen and never moves.
      child: Stack(
        children: [
          if (background != null) Positioned.fill(child: background!),
          Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: true,
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxContentWidth),
                child: Stack(
                  children: [
                    Positioned.fill(child: body),
                    if (appBar != null)
                      Positioned(left: 0, top: 0, right: 0, child: appBar!),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A floating top bar: [leading], [title] and [actions] in a 44-pt row under
/// the status bar, over a soft blur.
class GlassAppBar extends StatelessWidget {
  const GlassAppBar({
    super.key,
    this.leading,
    this.title,
    this.actions = const [],
    this.centerTitle = false,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final bool centerTitle;

  static const double barHeight = 44;

  /// Space between the status bar and the buttons, so they don't touch it.
  static const double gap = 8;

  /// From the top of the screen to the bottom of the bar.
  static double bottomOf(BuildContext context) =>
      MediaQuery.paddingOf(context).top + gap + barHeight;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.paddingOf(context).top;

    final row = SizedBox(
      height: barHeight,
      child: NavigationToolbar(
        // Centred: the toolbar stretches its leading slot to the bar height,
        // which squashed a round button smaller than the bar into an oval.
        leading: leading == null
            ? null
            : Center(widthFactor: 1, child: leading),
        middle: title == null
            ? null
            : DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: title!,
              ),
        trailing: actions.isEmpty
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: actions),
        centerMiddle: centerTitle,
        middleSpacing: 12,
      ),
    );

    if (MediaQuery.highContrastOf(context)) {
      return ColoredBox(
        color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
        child: Padding(
          padding: EdgeInsets.only(top: top + gap),
          child: row,
        ),
      );
    }

    // No strip behind the bar: only its buttons are glass, floating over the
    // background as the compass app's controls do.
    return Padding(
      padding: EdgeInsets.only(top: top + gap, bottom: 6),
      child: row,
    );
  }
}

/// A glass bottom sheet, as in the compass app: thick glass with a grabber,
/// rounded on every corner and inset from the screen edge, swipe to dismiss,
/// and NO dimming — the glass needs the screen behind it at its own
/// brightness to read as glass. A tap outside still closes it.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    // A phone-width sheet on a tablet or in landscape, not a full-width
    // strip with its rows spread across the screen.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) {
      final inset = MediaQuery.viewInsetsOf(ctx).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: GlassSurface(
              radius: 16,
              thick: true,
              // Denser than the cards: a sheet carries rows of text over
              // whatever is behind it, and the + button bled through the
              // last row. Still glass, just more frosted.
              blur: 18,
              tint: Theme.of(ctx).brightness == Brightness.dark
                  ? Colors.black.withValues(alpha: 0.40)
                  : Colors.white.withValues(alpha: 0.40),
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurface.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // Scrolls when taller than the screen: the note's ⋯ menu
                  // (seven rows) was cut off in landscape.
                  Flexible(child: SingleChildScrollView(child: builder(ctx))),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
