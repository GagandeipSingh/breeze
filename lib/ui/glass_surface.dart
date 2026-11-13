import 'dart:ui';

import 'package:flutter/material.dart';

/// Liquid Glass the way the compass app draws it: a backdrop blur in a
/// ClipRRect, a translucent fill, and a one-pixel rim that catches the light
/// at the top-left and bottom-right. One material for every surface in the
/// app — cards, buttons, bars and sheets.
///
/// * `thick` is the denser variant for surfaces that carry text over busy
///   content (sheets, the app bar, the tab bar).
/// * `lit` is the glass under a finger: it brightens, as `.interactive()`
///   glass does.
/// * `tint` is a faint colour wash over the glass (result cards, a prominent
///   round button).
/// * High contrast is the fallback: an opaque surface with a firm border.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    required this.radius,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.gradient,
    this.thick = false,
    this.lit = false,
    this.blur,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint;

  /// A fill in place of [tint]: the accent buttons' gradient.
  final Gradient? gradient;
  final bool thick;
  final bool lit;

  /// Blur strength, overriding the default frost. Sheets use a heavier one
  /// so what sits behind them (the + button) cannot be read through.
  final double? blur;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);

    if (MediaQuery.highContrastOf(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
          borderRadius: shape,
          border: Border.all(
            color: dark ? Colors.white70 : Colors.black54,
            width: 1.2,
          ),
        ),
        child: Padding(padding: padding, child: child),
      );
    }

    // Smoky see-through glass in dark mode, clear white glass in light.
    // Kept LIGHT on purpose: the glass must read as see-through at rest, not
    // only while something slides behind it. A dense fill plus a strong blur
    // erases the background and the pane looks like a solid card.
    var fill = thick
        ? (dark
              ? Colors.black.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.62))
        : (dark
              ? Colors.white.withValues(alpha: lit ? 0.07 : 0.02)
              : Colors.white.withValues(alpha: lit ? 0.70 : 0.50));
    if (tint != null) fill = Color.alphaBlend(tint!, fill);

    return DecoratedBox(
      // No shadow under see-through glass in dark mode: it shows through the
      // pane and reads as a dark background. Light glass needs one to stand
      // off a pale background — OUTER only and centred, so nothing greys the
      // pane and no shifted second pill appears.
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          if (!dark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.09),
              blurRadius: 22,
              blurStyle: BlurStyle.outer,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          // A light frost: enough to soften what is behind, little enough
          // that its shapes still show through.
          filter: ImageFilter.blur(
            sigmaX: blur ?? (thick ? 4 : 3),
            sigmaY: blur ?? (thick ? 4 : 3),
            tileMode: TileMode.mirror,
          ),
          child: CustomPaint(
            foregroundPainter: _Rim(
              radius: radius,
              dark: dark,
              strength: lit ? 1.4 : 1.0,
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: gradient == null ? fill : null,
                gradient: gradient,
                borderRadius: shape,
              ),
              padding: padding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The edge that makes glass read as glass: a one-pixel line that catches
/// light at the top left and again at the bottom right and fades between,
/// as on iOS 26 controls. Identical to the compass app's rim.
class _Rim extends CustomPainter {
  const _Rim({required this.radius, required this.dark, this.strength = 1});

  final double radius;
  final bool dark;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );
    final hi = ((dark ? 0.42 : 0.85) * strength).clamp(0.0, 1.0);
    final lo = ((dark ? 0.08 : 0.30) * strength).clamp(0.0, 1.0);
    Color w(double a) => Colors.white.withValues(alpha: a);

    // On a light page a white highlight is invisible, so light glass gets a
    // faint dark edge underneath it to hold its shape.
    if (!dark) {
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: 0.07),
      );
    }

    // Circles, cards and sheets: a straight diagonal gradient.
    if (size.shortestSide / size.longestSide > 0.5) {
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [w(hi), w(lo), w(lo), w((hi * 0.7).clamp(0.0, 1.0))],
            stops: const [0, 0.4, 0.6, 1],
          ).createShader(rect),
      );
      return;
    }

    // Long pills and wide cards: one corner light in each of the top-left
    // and bottom-right corners, sized to the HEIGHT, so a long edge keeps
    // only the faint base line instead of one end lighting up entirely.
    final h = size.height;
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = w(lo),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [w(hi), w(0)],
        ).createShader(Rect.fromLTWH(0, 0, h * 0.8, h * 0.8)),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader =
            LinearGradient(
              begin: Alignment.bottomRight,
              end: Alignment.topLeft,
              colors: [w((hi * 0.7).clamp(0.0, 1.0)), w(0)],
            ).createShader(
              Rect.fromLTWH(size.width - h * 0.8, h * 0.2, h * 0.8, h * 0.8),
            ),
    );
  }

  @override
  bool shouldRepaint(_Rim old) =>
      old.radius != radius || old.dark != dark || old.strength != strength;
}
