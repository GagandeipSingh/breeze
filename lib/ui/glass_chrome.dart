import 'dart:math' as math;

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
    this.maxContentWidth,
  });

  final Widget body;
  final Widget? background;
  final GlassAppBar? appBar;
  final GlassStatusBarStyle statusBarStyle;
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final overlay = statusBarStyle == GlassStatusBarStyle.light
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    final stack = Stack(
      children: [
        Positioned.fill(child: body),
        if (appBar != null)
          Positioned(left: 0, top: 0, right: 0, child: appBar!),
      ],
    );
    final content = maxContentWidth != null
        ? Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth!),
              child: stack,
            ),
          )
        : stack;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
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
            body: content,
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

/// A glass bottom sheet: on phones it slides up smoothly as an ergonomic
/// rounded floating card; on larger screens (tablets, foldables, desktop)
/// it seamlessly presents as a centered floating liquid glass modal card.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= 720;
  if (isWide) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final screenH = MediaQuery.sizeOf(ctx).height;
        return Center(
          child: FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.95, end: 1.0).animate(curve),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  maxHeight: math.min(640, screenH - 32),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GlassSurface(
                    radius: 24,
                    thick: true,
                    blur: 24,
                    tint: dark
                        ? Colors.black.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.45),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Material(
                      type: MaterialType.transparency,
                      child: SingleChildScrollView(child: builder(ctx)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) {
      final inset = MediaQuery.viewInsetsOf(ctx).bottom;
      final dark = Theme.of(ctx).brightness == Brightness.dark;
      return Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
            child: GlassSurface(
              radius: 20,
              thick: true,
              blur: 18,
              tint: dark
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
