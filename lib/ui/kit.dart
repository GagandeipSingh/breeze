import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'glass_chrome.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../state/settings.dart';
import 'ambient.dart';
import 'glass_surface.dart';
import 'scale.dart';
import 'motion.dart';

/// Colours for text and accents on top of the glass.
class Pal {
  Pal._(this.dark, this.accent);
  factory Pal.of(BuildContext context) => Pal._(
    Theme.of(context).brightness == Brightness.dark,
    SettingsScope.of(context).accent.color,
  );

  @visibleForTesting
  factory Pal.test({bool dark = false}) => Pal._(dark, const Color(0xFF3B82F6));

  final bool dark;
  final Color accent;
  Color get ink => dark ? Colors.white : const Color(0xFF14151A);
  Color get sub => dark ? const Color(0xB3FFFFFF) : const Color(0x9914151A);
  Color get faint => dark ? const Color(0x1FFFFFFF) : const Color(0x1414151A);

  /// The fill of accent buttons (+, Save, chosen tag, OK, a Word file's
  /// badge): the accent itself, lit softly from above - a touch lighter at
  /// the top, a touch deeper at the foot - so it reads as one colour with
  /// depth, never as two.
  LinearGradient get accentFill {
    final a = dark ? 0.9 : 0.96;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color.lerp(accent, Colors.white, 0.12)!.withValues(alpha: a),
        Color.lerp(accent, Colors.black, 0.10)!.withValues(alpha: a),
      ],
    );
  }
}

/// The colour field behind every screen. Glass refracts what is behind it, so
/// a time-of-day sky with faint contour lines gives the liquid effect
/// something to bend.
class GradientBackground extends StatelessWidget {
  const GradientBackground({super.key});

  @override
  Widget build(BuildContext context) =>
      AmbientBackground(accent: SettingsScope.of(context).accent.color);
}

/// Padding that clears the glass app bar on top and the bottom bar below.
EdgeInsets pagePadding(BuildContext context, {bool bottomBar = false}) {
  final mq = MediaQuery.paddingOf(context);
  return EdgeInsets.fromLTRB(
    16,
    mq.top + GlassAppBar.gap + GlassAppBar.barHeight + 14,
    16,
    mq.bottom + (bottomBar ? 72.dp + 20.dp : 28.dp),
  );
}

/// A centered empty-state: a glass circle holding an icon, a title and an
/// optional hint. Used wherever a screen would otherwise read as blank.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.bg = true,
  });
  final IconData icon;
  final String title;
  final String? hint;

  /// Whether to draw the glass circle behind the icon.
  final bool bg;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bg)
            SizedBox.square(
              dimension: 92.dp,
              child: GlassSurface(
                radius: 46.dp,
                thick: true,
                child: Center(
                  child: Icon(icon, size: 40.dp, color: p.accent),
                ),
              ),
            )
          else
            Icon(icon, size: 52.dp, color: p.accent.withValues(alpha: 0.9)),
          SizedBox(height: 18.dp),
          Text(
            title,
            style: TextStyle(
              color: p.ink,
              fontSize: 16.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hint != null) ...[
            SizedBox(height: 6.dp),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.sub, fontSize: 13.5.sp, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// A glass card.
class Pane extends StatelessWidget {
  const Pane({
    super.key,
    required this.child,
    this.padding,
    this.tint,
    this.radius,
    this.expand = false,
  });
  final Widget child;
  final EdgeInsets? padding;
  final Color? tint;
  final double? radius;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final surface = GlassSurface(
      radius: radius ?? 26.dp,
      padding: padding ?? EdgeInsets.fromLTRB(18.dp, 16.dp, 18.dp, 16.dp),
      tint: tint,
      child: child,
    );
    return expand ? SizedBox.expand(child: surface) : surface;
  }
}

class Gap extends StatelessWidget {
  const Gap([this.size = 12, Key? key]) : super(key: key);
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(height: size, width: size);
}

class Caption extends StatelessWidget {
  const Caption(this.text, {super.key, this.color, this.align});
  final String text;
  final Color? color;
  final TextAlign? align;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    textAlign: align,
    style: TextStyle(
      color: color ?? Pal.of(context).sub,
      fontSize: 11.5.sp,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(6.dp, 18.dp, 6.dp, 8.dp),
    child: Caption(text),
  );
}

class Hairline extends StatelessWidget {
  const Hairline({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: 12.dp),
    child: Container(height: 0.6.dp, color: Pal.of(context).faint),
  );
}

/// A label (with optional hint) and a trailing iOS switch.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.icon,
  });
  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20.dp, color: p.accent),
          SizedBox(width: 12.dp),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 15.5.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (hint != null)
                Padding(
                  padding: EdgeInsets.only(top: 2.dp),
                  child: Text(
                    hint!,
                    style: TextStyle(color: p.sub, fontSize: 12.5.sp),
                  ),
                ),
            ],
          ),
        ),
        Transform.scale(
          scale: 0.8,
          alignment: Alignment.centerRight,
          child: CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: p.accent,
            inactiveTrackColor: p.dark
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.black.withValues(alpha: 0.12),
          ),
        ),
      ],
    );
  }
}

/// A tappable settings/menu row with an icon, title, optional subtitle and a
/// chevron or trailing widget.
class TapRow extends StatelessWidget {
  const TapRow({
    super.key,
    required this.label,
    this.hint,
    this.icon,
    this.onTap,
    this.trailing,
    this.chevron = true,
    this.danger = false,
  });
  final String label;
  final String? hint;
  final IconData? icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool chevron;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final c = danger ? const Color(0xFFE5484D) : p.ink;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: 48.dp),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20.dp, color: danger ? c : p.accent),
                SizedBox(width: 12.dp),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: c,
                        fontSize: 15.5.sp,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hint != null)
                      Padding(
                        padding: EdgeInsets.only(top: 2.dp),
                        child: Text(
                          hint!,
                          style: TextStyle(color: p.sub, fontSize: 12.5.sp),
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
              if (chevron && trailing == null)
                Icon(CupertinoIcons.chevron_forward, size: 16.dp, color: p.sub),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.interactive()` glass, as the compass app does it: swells under the
/// finger, and settles back with a small bounce on release. The whole surface
/// is the hit region. Pass [builder] instead of [child] to also brighten the
/// glass while it is held (`GlassSurface(lit: down)`).
class GlassPress extends StatefulWidget {
  const GlassPress({
    super.key,
    required this.onTap,
    required this.label,
    this.child,
    this.builder,
    this.onLongPress,
    this.actions,
  }) : assert(child != null || builder != null);
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Extra screen-reader actions (the children's own buttons are hidden
  /// from it, so a button inside, like a menu, is offered here instead).
  final Map<CustomSemanticsAction, VoidCallback>? actions;
  final String label;
  final Widget? child;
  final Widget Function(bool down)? builder;

  @override
  State<GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<GlassPress> {
  bool _down = false;
  bool _hover = false;
  Offset? _at; // the finger, in this button's own coordinates
  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      customSemanticsActions: widget.actions,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hover) setState(() => _hover = true);
        },
        onExit: (_) {
          if (_hover) setState(() => _hover = false);
        },
        child: Listener(
          // The glow follows the finger while it is down.
          onPointerDown: (e) => setState(() => _at = e.localPosition),
          onPointerMove: (e) {
            if (_down) setState(() => _at = e.localPosition);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _set(true),
            onTapCancel: () => _set(false),
            onTapUp: (_) => _set(false),
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onTap();
            },
            onLongPress: widget.onLongPress,
            // Swells quickly under the finger and springs back on release,
            // keeping its speed if pressed again mid-bounce. The glow rides
            // the same spring.
            child: SpringValue(
              value: _down && !still ? 1 : (_hover && !still ? 0.33 : 0),
              stiffness: _down ? 420 : 180,
              dampingRatio: _down ? 0.8 : 0.5,
              child: widget.builder?.call(_down) ?? widget.child,
              builder: (context, v, child) => Transform.scale(
                scale: 1 + 0.06 * v,
                child: PressGlow(
                  point: _at,
                  strength: v.clamp(0.0, 1.0),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round glass button (back, menu, save).
class RoundGlassButton extends StatelessWidget {
  const RoundGlassButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.size,
    this.tint,
    this.gradient,
    this.iconColor,
    this.bold = false,
  });
  final IconData icon;
  final VoidCallback onPressed;
  final String semanticLabel;
  final double? size;
  final Color? tint;

  /// A gradient fill in place of [tint] (Pal.accentFill).
  final Gradient? gradient;
  final Color? iconColor;

  /// A hair heavier glyph, for a thin icon that reads weak beside the others.
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final size = this.size ?? 40.dp;
    return GlassPress(
      onTap: onPressed,
      label: semanticLabel,
      builder: (down) => SizedBox.square(
        dimension: size,
        child: GlassSurface(
          radius: size / 2,
          lit: down,
          tint: tint,
          gradient: gradient,
          child: Center(
            child: Transform.translate(
              offset: Offset(_lean(icon) * size * 0.035, 0),
              child: Icon(
                icon,
                color: iconColor ?? p.ink,
                size: size * 0.46,
                shadows: bold
                    ? [
                        Shadow(
                          color: iconColor ?? p.ink,
                          offset: const Offset(0.35, 0),
                        ),
                        Shadow(
                          color: iconColor ?? p.ink,
                          offset: const Offset(-0.35, 0),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static double _lean(IconData i) {
    if (i == CupertinoIcons.chevron_left || i == CupertinoIcons.chevron_back) {
      return -1;
    }
    if (i == CupertinoIcons.chevron_right ||
        i == CupertinoIcons.chevron_forward) {
      return 1;
    }
    return 0;
  }
}

/// A glass segmented control for short choices.
class Segments<T> extends StatelessWidget {
  const Segments({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final height = 46.dp;
    final index = values.indexOf(selected).clamp(0, values.length - 1);
    return GlassSurface(
      radius: height / 2,
      thick: true,
      padding: EdgeInsets.all(4.dp),
      child: SizedBox(
        height: height - 8.dp,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth / values.length;
            return Stack(
              children: [
                SpringValue(
                  value: index.toDouble(),
                  builder: (context, at, child) => Positioned(
                    left: w * at,
                    top: 0,
                    bottom: 0,
                    width: w,
                    child: child!,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: p.dark
                          ? Colors.white.withValues(alpha: 0.14)
                          : Colors.white.withValues(alpha: 0.8),
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: p.dark ? 0.18 : 0.9,
                        ),
                        width: 0.8,
                      ),
                      boxShadow: p.dark
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 8,
                              ),
                            ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < values.length; i++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: i == index,
                          label: labels[i],
                          excludeSemantics: true,
                          onTap: () => onChanged(values[i]),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (i == index) return;
                              HapticFeedback.selectionClick();
                              onChanged(values[i]);
                            },
                            child: Center(
                              child: Text(
                                labels[i],
                                style: TextStyle(
                                  color: i == index ? p.ink : p.sub,
                                  fontSize: 14.sp,
                                  fontWeight: i == index
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
