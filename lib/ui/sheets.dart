import 'dart:ui' show BoxWidthStyle;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_chrome.dart';
import 'glass_surface.dart';

// The sheet is the compass app's glass sheet; re-exported so screens that
// import this file keep reaching it.
export 'glass_chrome.dart' show showGlassSheet;
import 'kit.dart';
import 'scale.dart';
import 'motion.dart';

/// A small glass toast near the bottom of the screen: an icon and a line of
/// text, properly centred inside the glass (the package's GlassToast drifts
/// under our screen scaling). Auto-dismisses.
// The toast on screen now: a new one replaces it rather than stacking on
// top of it, where both would be unreadable.
void Function()? _closeToast;

void showToast(
  BuildContext context, {
  required String message,
  IconData? icon,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  // Long enough to read: 2.5 s at least, about 50 ms more per letter,
  // at most 6 s (1.5 s flat went before a longer message was read).
  duration ??= Duration(
    milliseconds: (1800 + 50 * message.length).clamp(2500, 6000),
  );
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final p = Pal.of(context);
  final hasAction = actionLabel != null && onAction != null;
  late final OverlayEntry entry;
  var gone = false;
  // Springs up from below the screen, and drops back out when it goes.
  final shown = ValueNotifier<bool>(false);
  final reduce = MediaQuery.disableAnimationsOf(context);
  void close() {
    if (gone) return;
    gone = true;
    if (identical(_closeToast, close)) _closeToast = null;
    if (reduce) {
      entry.remove();
      shown.dispose();
      return;
    }
    shown.value = false;
    Future.delayed(const Duration(milliseconds: 260), () {
      entry.remove();
      shown.dispose();
    });
  }

  entry = OverlayEntry(
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      // Sit above the keyboard when it's open, otherwise above the bottom bar.
      final bottom = mq.viewInsets.bottom > 0
          ? mq.viewInsets.bottom + 16.dp
          : mq.padding.bottom + 90.dp;
      final glass = GlassSurface(
        radius: 22.dp,
        thick: true,
        padding: EdgeInsets.fromLTRB(
          18.dp,
          hasAction ? 4.dp : 12.dp,
          hasAction ? 6.dp : 18.dp,
          hasAction ? 4.dp : 12.dp,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18.dp, color: p.accent),
              SizedBox(width: 10.dp),
            ],
            // A long name or a large system font wraps instead of running
            // off the screen.
            Flexible(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 14.5.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (hasAction) ...[
              SizedBox(width: 4.dp),
              TextButton(
                onPressed: () {
                  close();
                  onAction();
                },
                style: TextButton.styleFrom(
                  foregroundColor: p.accent,
                  minimumSize: Size(48.dp, 44.dp),
                  padding: EdgeInsets.symmetric(horizontal: 12.dp),
                ),
                child: Text(
                  actionLabel,
                  style: TextStyle(
                    fontSize: 14.5.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
      final body = Center(
        // Phone width at most: on a tablet a toast is a pill, not a banner.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: hasAction ? glass : IgnorePointer(child: glass),
        ),
      );
      // Moved by its position, not a transform, so the glass is repainted
      // where it is every frame (a transform would leave its rim behind).
      return ValueListenableBuilder<bool>(
        valueListenable: shown,
        child: body,
        builder: (ctx, on, child) => TweenAnimationBuilder<double>(
          tween: Tween(end: on ? 1 : 0),
          duration: Duration(
            milliseconds: reduce ? 0 : (on ? kSpringSoftMs : 240),
          ),
          curve: on ? kSpringSoft : Curves.easeInCubic,
          child: child,
          builder: (ctx, v, child) => Positioned(
            left: 16.dp,
            right: 16.dp,
            bottom: bottom - (bottom + 140.dp) * (1 - v),
            child: child!,
          ),
        ),
      );
    },
  );
  final old = _closeToast;
  _closeToast = close;
  old?.call();
  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!gone) shown.value = true;
  });
  // An action needs time to be read and reached.
  Future.delayed(
    hasAction && duration < const Duration(seconds: 4)
        ? const Duration(seconds: 4)
        : duration,
    close,
  );
}

/// An action sheet of rows, each a circular tinted icon badge beside its
/// label (after the compass app). Returns the chosen value.
Future<T?> showGlassMenu<T>(
  BuildContext context, {
  String? title,
  Widget? leading,
  required List<(T value, IconData? icon, String label, bool danger)> items,
  bool grid = false,
}) {
  const danger = Color(0xFFE5484D);
  return showGlassSheet<T>(
    context,
    builder: (ctx) {
      final p = Pal.of(ctx);
      void pick(T v) {
        HapticFeedback.selectionClick();
        Navigator.of(ctx).pop(v);
      }

      Widget row((T, IconData?, String, bool) it) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(ctx).pop(it.$1);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 7.dp),
          child: Row(
            children: [
              Container(
                width: 42.dp,
                height: 42.dp,
                decoration: BoxDecoration(
                  color: (it.$4 ? danger : p.accent).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  it.$2 ?? CupertinoIcons.circle,
                  size: 21.dp,
                  color: it.$4 ? danger : p.accent,
                ),
              ),
              SizedBox(width: 14.dp),
              Expanded(
                child: Text(
                  it.$3,
                  style: TextStyle(
                    color: it.$4 ? danger : p.ink,
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      Widget tile((T, IconData?, String, bool) it) => Semantics(
        button: true,
        label: it.$3,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => pick(it.$1),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 6.dp, horizontal: 2.dp),
            child: Column(
              children: [
                Container(
                  width: 48.dp,
                  height: 48.dp,
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    it.$2 ?? CupertinoIcons.circle,
                    size: 21.dp,
                    color: p.accent,
                  ),
                ),
                SizedBox(height: 6.dp),
                Text(
                  it.$3,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 12.5.sp,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      return Padding(
        padding: EdgeInsets.fromLTRB(16.dp, 6.dp, 16.dp, 12.dp),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: EdgeInsets.fromLTRB(4.dp, 6.dp, 4.dp, 10.dp),
                child: Row(
                  children: [
                    if (leading != null) ...[leading, SizedBox(width: 12.dp)],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.ink,
                          fontSize: 20.sp,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // A long menu as a grid of actions, four across, with the
            // destructive ones kept apart below as full rows.
            if (grid) ...[
              for (var i = 0; i < items.where((x) => !x.$4).length; i += 4)
                Padding(
                  padding: EdgeInsets.only(bottom: 6.dp),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var j = i; j < i + 4; j++)
                        Expanded(
                          child: j < items.where((x) => !x.$4).length
                              ? tile(items.where((x) => !x.$4).elementAt(j))
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              if (items.any((x) => x.$4)) ...[
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 4.dp),
                  child: Container(height: 0.8, color: p.faint),
                ),
                // Its icon under the first column's, so the two line up.
                for (final it in items.where((x) => x.$4))
                  LayoutBuilder(
                    builder: (_, c) => Padding(
                      padding: EdgeInsets.only(
                        left: (c.maxWidth / 8 - 21.dp).clamp(0, 999),
                      ),
                      child: row(it),
                    ),
                  ),
              ],
            ] else
              for (final it in items) row(it),
          ],
        ),
      );
    },
  );
}

/// A yes/no confirmation sheet. Returns true if confirmed.
Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Yes',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async =>
    await askConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
    ) ??
    false;

/// Like [showConfirm], but null when the sheet is dismissed without either
/// button, for questions where "neither" must not mean the cancel answer.
Future<bool?> askConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Yes',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final result = await showGlassSheet<bool>(
    context,
    builder: (ctx) {
      final p = Pal.of(ctx);
      return Padding(
        padding: EdgeInsets.fromLTRB(20.dp, 14.dp, 20.dp, 16.dp),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: p.ink,
                fontSize: 18.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message != null) ...[
              SizedBox(height: 8.dp),
              Text(
                message,
                style: TextStyle(color: p.sub, fontSize: 14.sp, height: 1.35),
              ),
            ],
            SizedBox(height: 18.dp),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: cancelLabel,
                    onTap: () => Navigator.of(ctx).pop(false),
                  ),
                ),
                SizedBox(width: 10.dp),
                Expanded(
                  child: _SheetButton(
                    label: confirmLabel,
                    filled: true,
                    danger: danger,
                    onTap: () => Navigator.of(ctx).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  return result;
}

/// A single-field text prompt (new name, tag name). Returns the text or null.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? label,
  String initial = '',
  String hint = '',
  String confirmLabel = 'Save',
  TextCapitalization caps = TextCapitalization.sentences,
}) {
  final controller = TextEditingController(text: initial);
  final sheet = showGlassSheet<String>(
    context,
    builder: (ctx) {
      final p = Pal.of(ctx);
      void submit() {
        final v = controller.text.trim();
        Navigator.of(ctx).pop(v.isEmpty ? null : v);
      }

      return Padding(
        padding: EdgeInsets.fromLTRB(20.dp, 14.dp, 20.dp, 16.dp),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: p.ink,
                fontSize: 18.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 14.dp),
            GlassSurface(
              radius: 16.dp,
              padding: EdgeInsets.symmetric(horizontal: 14.dp, vertical: 4.dp),
              child: TextField(
                selectionWidthStyle: BoxWidthStyle.tight,
                // Off: the app is scaled to fit width, which puts Android's
                // loupe in the wrong place and leaves it stuck on screen.
                magnifierConfiguration: TextMagnifierConfiguration.disabled,
                controller: controller,
                autofocus: true,
                textCapitalization: caps,
                cursorColor: p.accent,
                // File names past ~255 bytes are refused by the file system.
                maxLength: 120,
                onSubmitted: (_) => submit(),
                style: TextStyle(color: p.ink, fontSize: 16.sp),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  labelText: label,
                  hintText: hint,
                  labelStyle: TextStyle(color: p.sub),
                  hintStyle: TextStyle(color: p.sub),
                  counterText: '',
                ),
              ),
            ),
            SizedBox(height: 16.dp),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(ctx).pop(null),
                  ),
                ),
                SizedBox(width: 10.dp),
                Expanded(
                  child: _SheetButton(
                    label: confirmLabel,
                    filled: true,
                    onTap: submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  // Disposed after the sheet's close animation, not at pop.
  return sheet.whenComplete(
    () => Future.delayed(const Duration(milliseconds: 400), controller.dispose),
  );
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    this.filled = false,
    this.danger = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final accent = danger ? const Color(0xFFE5484D) : p.accent;
    return GlassPress(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      label: label,
      child: GlassSurface(
        radius: 14.dp,
        thick: true,
        gradient: filled
            ? (danger
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFE5484D), Color(0xFFC52B30)],
                    )
                  : p.accentFill)
            : null,
        tint: (!filled && danger)
            ? accent.withValues(alpha: p.dark ? 0.18 : 0.10)
            : null,
        child: SizedBox(
          height: 48.dp,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: filled ? Colors.white : (danger ? accent : p.ink),
                fontSize: 15.5.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How to share files: picture tiles rather than a list of sentences.
/// One file: File or PDF. Several: File, PDF, ZIP, PDF ZIP. Each tile says
/// what arrives at the other end ("2 files", "1 file") in two words.
/// Returns 'files', 'pdfs', 'zip' or 'pdfzip'.
Future<String?> showShareFormat(BuildContext context, {required int count}) {
  final many = count > 1;
  final what = many ? '$count files' : '1 file';
  final tiles = [
    ('files', CupertinoIcons.doc_on_doc, false, 'File', what),
    ('pdfs', CupertinoIcons.doc, true, 'PDF', what),
    if (many) ('zip', CupertinoIcons.archivebox, false, 'ZIP', '1 file'),
    if (many) ('pdfzip', CupertinoIcons.archivebox, true, 'PDF ZIP', '1 file'),
  ];
  return showGlassSheet<String>(
    context,
    builder: (ctx) {
      final p = Pal.of(ctx);
      Widget tile((String, IconData, bool, String, String) t) => Expanded(
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(ctx).pop(t.$1);
          },
          child: Container(
            margin: EdgeInsets.all(5.dp),
            padding: EdgeInsets.symmetric(vertical: 16.dp),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: p.dark ? 0.12 : 0.09),
              borderRadius: BorderRadius.circular(18.dp),
              border: Border.all(color: p.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 46.dp,
                  height: 40.dp,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Icon(t.$2, size: 32.dp, color: p.accent),
                      if (t.$3)
                        Positioned(
                          right: -2.dp,
                          bottom: 0,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4.dp,
                              vertical: 1.dp,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5484D),
                              borderRadius: BorderRadius.circular(4.dp),
                            ),
                            child: Text(
                              'PDF',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.5.sp,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 8.dp),
                Text(
                  t.$4,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2.dp),
                Text(
                  t.$5,
                  style: TextStyle(color: p.sub, fontSize: 12.sp),
                ),
              ],
            ),
          ),
        ),
      );
      return Padding(
        padding: EdgeInsets.fromLTRB(11.dp, 6.dp, 11.dp, 12.dp),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(9.dp, 6.dp, 9.dp, 8.dp),
              child: Text(
                many ? 'Share $count files' : 'Share',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 20.sp,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            Row(children: [tile(tiles[0]), tile(tiles[1])]),
            if (many) Row(children: [tile(tiles[2]), tile(tiles[3])]),
          ],
        ),
      );
    },
  );
}

/// One choice among a few, as tiles in a row with the current one lit:
/// picking one applies it and closes. For short sets (views, layouts).
Future<T?> showChoiceTiles<T>(
  BuildContext context, {
  required String title,
  required List<(T value, IconData icon, String label)> options,
  required T selected,
}) => showGlassSheet<T>(
  context,
  // The pick lights up and springs before the sheet closes, so the
  // choice is seen landing instead of the sheet vanishing under the finger.
  builder: (ctx) =>
      _ChoiceTiles<T>(title: title, options: options, selected: selected),
);

class _ChoiceTiles<T> extends StatefulWidget {
  const _ChoiceTiles({
    required this.title,
    required this.options,
    required this.selected,
  });
  final String title;
  final List<(T value, IconData icon, String label)> options;
  final T selected;

  @override
  State<_ChoiceTiles<T>> createState() => _ChoiceTilesState<T>();
}

class _ChoiceTilesState<T> extends State<_ChoiceTiles<T>> {
  late T selected = widget.selected;
  bool _closing = false;

  void _pick(T v) {
    if (_closing) return;
    _closing = true;
    HapticFeedback.selectionClick();
    setState(() => selected = v);
    final reduce = MediaQuery.disableAnimationsOf(context);
    Future.delayed(Duration(milliseconds: reduce ? 0 : 300), () {
      if (mounted) Navigator.of(context).pop(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctx = context;
    final title = widget.title;
    final options = widget.options;
    final p = Pal.of(ctx);
    return Padding(
      padding: EdgeInsets.fromLTRB(16.dp, 6.dp, 16.dp, 16.dp),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(4.dp, 6.dp, 4.dp, 14.dp),
            child: Text(
              title,
              style: TextStyle(
                color: p.ink,
                fontSize: 20.sp,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          Row(
            children: [
              for (final (i, o) in options.indexed) ...[
                if (i > 0) SizedBox(width: 8.dp),
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: o.$1 == selected,
                    label: o.$3,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pick(o.$1),
                      child: TweenAnimationBuilder<double>(
                        // Replays for the tile just picked: a little press
                        // that springs back.
                        key: ValueKey(o.$1 == selected && _closing),
                        tween: Tween(begin: 0, end: 1),
                        duration: const Duration(milliseconds: kSpringMs),
                        curve: kSpring,
                        builder: (context, v, child) => Transform.scale(
                          scale: o.$1 == selected && _closing
                              ? 0.9 + 0.1 * v
                              : 1,
                          child: child,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: EdgeInsets.symmetric(vertical: 14.dp),
                          decoration: BoxDecoration(
                            gradient: o.$1 == selected ? p.accentFill : null,
                            color: o.$1 == selected
                                ? null
                                : p.ink.withValues(alpha: p.dark ? 0.05 : 0.04),
                            borderRadius: BorderRadius.circular(16.dp),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                o.$2,
                                size: 22.dp,
                                color: o.$1 == selected ? Colors.white : p.ink,
                              ),
                              SizedBox(height: 6.dp),
                              Text(
                                o.$3,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: o.$1 == selected
                                      ? Colors.white
                                      : p.ink,
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A two-way switch drawn as one pill with the picked half lit.
class SegmentedPick<T> extends StatelessWidget {
  const SegmentedPick({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T value, IconData icon, String label)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return Container(
      padding: EdgeInsets.all(4.dp),
      decoration: BoxDecoration(
        color: p.ink.withValues(alpha: p.dark ? 0.06 : 0.05),
        borderRadius: BorderRadius.circular(16.dp),
      ),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: Semantics(
                button: true,
                selected: o.$1 == value,
                label: o.$3,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (o.$1 == value) return;
                    HapticFeedback.selectionClick();
                    onChanged(o.$1);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 42.dp,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: o.$1 == value ? p.accentFill : null,
                      borderRadius: BorderRadius.circular(12.dp),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          o.$2,
                          size: 16.dp,
                          color: o.$1 == value ? Colors.white : p.sub,
                        ),
                        SizedBox(width: 6.dp),
                        Flexible(
                          child: Text(
                            o.$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: o.$1 == value ? Colors.white : p.ink,
                              fontSize: 14.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
