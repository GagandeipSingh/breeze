import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../data/note_scope.dart';
import '../data/note_store.dart';
import '../state/settings.dart';
import 'glass_chrome.dart';
import 'kit.dart';
import 'lock_gate.dart';
import 'scale.dart';
import 'sheets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final s = SettingsScope.of(context);
    final store = NoteScope.of(context);
    final screen = MediaQuery.sizeOf(context);
    // Two columns from ~760 wide, so an unfolded foldable gets them too,
    // not just a desktop; and only with the height to hold them, as the
    // page is fitted to the screen. A phone on its side is wide but short,
    // and keeps the scrolling single column.
    final isDesktop = screen.width >= 760.dp && screen.height >= 560.dp;

    return GlassScaffold(
      background: const GradientBackground(),
      statusBarStyle: p.dark
          ? GlassStatusBarStyle.light
          : GlassStatusBarStyle.dark,
      appBar: GlassAppBar(
        centerTitle: false,
        leading: Padding(
          padding: EdgeInsets.only(left: 8.dp),
          child: RoundGlassButton(
            icon: CupertinoIcons.chevron_back,
            semanticLabel: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(
          'Settings',
          style: TextStyle(
            color: p.ink,
            fontSize: 17.sp,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: isDesktop
          ? _desktopLayout(context, p, s, store)
          : _mobileLayout(context, p, s, store),
    );
  }

  Widget _mobileLayout(
    BuildContext context,
    Pal p,
    Settings s,
    NoteStore store,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640.dp),
        child: Scrollbar(
          child: ListView(
            padding: pagePadding(context),
            children: [
              const SectionTitle('Security'),
              _securityPane(context, p, s, store),
              const SectionTitle('Look'),
              _lookPane(context, p, s),
              const SectionTitle('Feel'),
              _feelPane(context, p, s),
              const SectionTitle('Other'),
              _otherPane(context, p, s, store),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopLayout(
    BuildContext context,
    Pal p,
    Settings s,
    NoteStore store,
  ) {
    final topOffset = GlassAppBar.bottomOf(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final clearTop = math.max(topOffset + 24.dp, 84.dp);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The whole page fits the screen, never scrolls, and spans the same
        // width as the home list. When the two columns are taller than the
        // room (an unfolded foldable), _FitToScreen lays them out wider and
        // scales them down to fit, so they still fill the width edge to
        // edge. A screen with room keeps it at full size.
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24.dp,
            clearTop,
            24.dp,
            bottomInset + 28.dp,
          ),
          child: _FitToScreen(
            child: SizedBox(
              child: SizedBox(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 1140.dp),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Left Column: Look & Reading
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SectionTitle('Look'),
                                Expanded(
                                  child: _desktopLookPane(context, p, s),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 24.dp),
                          // Right Column: Security & Feel
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SectionTitle('Security & Feel'),
                                Expanded(
                                  child: _desktopSecurityAndFeelPane(
                                    context,
                                    p,
                                    s,
                                    store,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
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

  Widget _desktopLookPane(BuildContext context, Pal p, Settings s) {
    return Pane(
      expand: true,
      padding: EdgeInsets.fromLTRB(22.dp, 18.dp, 22.dp, 18.dp),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Theme
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    CupertinoIcons.circle_lefthalf_fill,
                    size: 20.dp,
                    color: p.accent,
                  ),
                  SizedBox(width: 12.dp),
                  Text(
                    'Theme',
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15.5.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.dp),
              Segments<Appearance>(
                values: const [
                  Appearance.system,
                  Appearance.light,
                  Appearance.dark,
                ],
                labels: const ['System', 'Light', 'Dark'],
                selected: s.appearance,
                onChanged: (v) => s.appearance = v,
              ),
            ],
          ),
          const Hairline(),
          // Accent
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.paintbrush, size: 20.dp, color: p.accent),
                  SizedBox(width: 12.dp),
                  Text(
                    'Accent',
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15.5.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.dp),
              _AccentRow(s: s),
            ],
          ),
          const Hairline(),
          // Text size
          _TextSizeRow(s: s),
          const Hairline(),
          // Monospace font
          SwitchRow(
            icon: CupertinoIcons.textformat,
            label: 'Use monospace font',
            hint: 'For reading and writing text files',
            value: s.monospace,
            onChanged: (v) => s.monospace = v,
          ),
          const Hairline(),
          // Text formatting
          SwitchRow(
            icon: Icons.format_bold_rounded,
            label: 'Text formatting',
            hint: 'Bold, italic, headings and lists',
            value: s.formatting,
            onChanged: (v) => s.formatting = v,
          ),
          const Hairline(),
          // Code colours
          SwitchRow(
            icon: Icons.code_rounded,
            label: 'Code colours',
            hint: 'Syntax highlighting in code blocks',
            value: s.codeColours,
            onChanged: (v) => s.codeColours = v,
          ),
          const Hairline(),
          // Remember scroll position
          SwitchRow(
            icon: CupertinoIcons.arrow_up_arrow_down,
            label: 'Remember scroll position',
            hint: 'Resume reading where you left off',
            value: s.rememberScroll,
            onChanged: (v) => s.rememberScroll = v,
          ),
        ],
      ),
    );
  }

  Widget _desktopSecurityAndFeelPane(
    BuildContext context,
    Pal p,
    Settings s,
    NoteStore store,
  ) {
    return Pane(
      expand: true,
      padding: EdgeInsets.fromLTRB(22.dp, 18.dp, 22.dp, 18.dp),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Security: Lock all files
          SwitchRow(
            icon: CupertinoIcons.lock_shield,
            label: 'Lock all files',
            hint: 'Require biometric or screen lock to open files',
            value: s.lockFiles,
            onChanged: (v) async {
              if (v) {
                final noteStore = NoteScope.of(context);
                final anyLocked =
                    noteStore.notes.any((n) => n.locked) ||
                    noteStore.anyTrashedLocked;
                if (await ensureCanLock(context, anyLocked: anyLocked)) {
                  s.lockFiles = true;
                }
              } else if (await authenticate(context, 'Turn off file lock')) {
                s.lockFiles = false;
              }
            },
          ),
          const _BreezePinRow(),
          const Hairline(),
          // File list layout
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    CupertinoIcons.rectangle_grid_1x2,
                    size: 20.dp,
                    color: p.accent,
                  ),
                  SizedBox(width: 12.dp),
                  Text(
                    'File list',
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15.5.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.dp),
              Segments<ListLayout>(
                values: ListLayout.values,
                labels: const ['Compact', 'Standard', 'Detailed', 'Grid'],
                selected: s.listLayout,
                onChanged: (v) => s.listLayout = v,
              ),
            ],
          ),
          const Hairline(),
          // Autosave
          SwitchRow(
            icon: CupertinoIcons.floppy_disk,
            label: 'Autosave',
            hint: 'Save notes while typing',
            value: s.autosave,
            onChanged: (v) => s.autosave = v,
          ),
          const Hairline(),
          // Delete by swiping
          SwitchRow(
            icon: CupertinoIcons.hand_draw,
            label: 'Delete by swiping',
            hint: 'Swipe left on a file to delete',
            value: s.swipeDelete,
            onChanged: (v) => s.swipeDelete = v,
          ),
          const Hairline(),
          // Tags
          SwitchRow(
            icon: CupertinoIcons.tag,
            label: 'Tags',
            hint: 'Organize files with tag folders',
            value: s.tagsEnabled,
            onChanged: (v) => s.tagsEnabled = v,
          ),
          const Hairline(),
          // Trash
          SwitchRow(
            icon: CupertinoIcons.trash,
            label: 'Trash',
            hint: 'Keep deleted files for 30 days',
            value: s.trashEnabled,
            onChanged: (v) => s.trashEnabled = v,
          ),
          const Hairline(),
          // Storage: Path to files
          TapRow(
            icon: CupertinoIcons.folder,
            label: 'Path to files',
            hint: store.folderPath,
            chevron: false,
            onTap: () {
              Clipboard.setData(ClipboardData(text: store.folderPath));
              showToast(
                context,
                message: 'Path copied',
                icon: CupertinoIcons.checkmark_alt,
              );
            },
          ),
          const Hairline(),
          // Storage: Encoding
          TapRow(
            icon: CupertinoIcons.textformat_abc,
            label: 'Encoding',
            hint: 'UTF-8',
            chevron: false,
            onTap: () {},
          ),
        ],
      ),
    );
  }

  // --- Mobile 4-Section Helpers ---

  Widget _securityPane(
    BuildContext context,
    Pal p,
    Settings s,
    NoteStore store,
  ) {
    return Pane(
      child: Column(
        children: [
          SwitchRow(
            icon: CupertinoIcons.lock_shield,
            label: 'Lock all files',
            hint: 'Require biometric or screen lock to open files',
            value: s.lockFiles,
            onChanged: (v) async {
              if (v) {
                final noteStore = NoteScope.of(context);
                final anyLocked =
                    noteStore.notes.any((n) => n.locked) ||
                    noteStore.anyTrashedLocked;
                if (await ensureCanLock(context, anyLocked: anyLocked)) {
                  s.lockFiles = true;
                }
              } else if (await authenticate(context, 'Turn off file lock')) {
                s.lockFiles = false;
              }
            },
          ),
          const _BreezePinRow(),
        ],
      ),
    );
  }

  Widget _lookPane(BuildContext context, Pal p, Settings s) {
    return Pane(
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.circle_lefthalf_fill,
                size: 20.dp,
                color: p.accent,
              ),
              SizedBox(width: 12.dp),
              Text(
                'Theme',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 15.5.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.dp),
          Segments<Appearance>(
            values: const [
              Appearance.system,
              Appearance.light,
              Appearance.dark,
            ],
            labels: const ['System', 'Light', 'Dark'],
            selected: s.appearance,
            onChanged: (v) => s.appearance = v,
          ),
          const Hairline(),
          Row(
            children: [
              Icon(CupertinoIcons.paintbrush, size: 20.dp, color: p.accent),
              SizedBox(width: 12.dp),
              Text(
                'Accent',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 15.5.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.dp),
          _AccentRow(s: s),
          const Hairline(),
          _TextSizeRow(s: s),
          const Hairline(),
          SwitchRow(
            icon: CupertinoIcons.textformat,
            label: 'Use monospace font',
            hint: 'For reading and writing text files',
            value: s.monospace,
            onChanged: (v) => s.monospace = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: Icons.format_bold_rounded,
            label: 'Text formatting',
            hint: 'Bold, italic, headings and lists in notes',
            value: s.formatting,
            onChanged: (v) => s.formatting = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: Icons.code_rounded,
            label: 'Code colours',
            hint: 'Colour keywords, strings and comments in code files',
            value: s.codeColours,
            onChanged: (v) => s.codeColours = v,
          ),
          const Hairline(),
          Row(
            children: [
              Icon(
                CupertinoIcons.rectangle_grid_1x2,
                size: 20.dp,
                color: p.accent,
              ),
              SizedBox(width: 12.dp),
              Text(
                'File list',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 15.5.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.dp),
          Segments<ListLayout>(
            values: ListLayout.values,
            labels: const ['Compact', 'Standard', 'Detailed', 'Grid'],
            selected: s.listLayout,
            onChanged: (v) => s.listLayout = v,
          ),
        ],
      ),
    );
  }

  Widget _feelPane(BuildContext context, Pal p, Settings s) {
    return Pane(
      child: Column(
        children: [
          SwitchRow(
            icon: CupertinoIcons.hand_draw,
            label: 'Delete by swiping',
            hint: 'Swipe right-to-left on a file to delete',
            value: s.swipeDelete,
            onChanged: (v) => s.swipeDelete = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: CupertinoIcons.floppy_disk,
            label: 'Autosave',
            hint: 'Save notes automatically while typing',
            value: s.autosave,
            onChanged: (v) => s.autosave = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: CupertinoIcons.arrow_up_arrow_down,
            label: 'Remember scroll position',
            hint: 'Return to where you left off in a note',
            value: s.rememberScroll,
            onChanged: (v) => s.rememberScroll = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: CupertinoIcons.tag,
            label: 'Tags',
            hint: 'Organize files with tag folders',
            value: s.tagsEnabled,
            onChanged: (v) => s.tagsEnabled = v,
          ),
          const Hairline(),
          SwitchRow(
            icon: CupertinoIcons.trash,
            label: 'Trash',
            hint: 'Deleted files are kept for 30 days',
            value: s.trashEnabled,
            onChanged: (v) => s.trashEnabled = v,
          ),
        ],
      ),
    );
  }

  Widget _otherPane(BuildContext context, Pal p, Settings s, NoteStore store) {
    return Pane(
      child: Column(
        children: [
          TapRow(
            icon: CupertinoIcons.folder,
            label: 'Path to files',
            hint: store.folderPath,
            chevron: false,
            onTap: () {
              Clipboard.setData(ClipboardData(text: store.folderPath));
              showToast(
                context,
                message: 'Path copied',
                icon: CupertinoIcons.checkmark_alt,
              );
            },
          ),
          const Hairline(),
          TapRow(
            icon: CupertinoIcons.textformat_abc,
            label: 'Encoding',
            hint: 'UTF-8',
            chevron: false,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _AccentRow extends StatelessWidget {
  const _AccentRow({required this.s});
  final Settings s;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34.dp,
      child: Row(
        children: [
          for (var i = 0; i < accents.length; i++) ...[
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                s.accentIndex = i;
              },
              child: Container(
                width: 30.dp,
                height: 30.dp,
                decoration: BoxDecoration(
                  color: accents[i].color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: s.accentIndex == i
                        ? Colors.white
                        : Colors.transparent,
                    width: 2.4,
                  ),
                  boxShadow: s.accentIndex == i
                      ? [
                          BoxShadow(
                            color: accents[i].color.withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
            SizedBox(width: 12.dp),
          ],
        ],
      ),
    );
  }
}

class _TextSizeRow extends StatefulWidget {
  const _TextSizeRow({required this.s});
  final Settings s;

  @override
  State<_TextSizeRow> createState() => _TextSizeRowState();
}

class _TextSizeRowState extends State<_TextSizeRow> {
  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.textformat_size, size: 20.dp, color: p.accent),
            SizedBox(width: 12.dp),
            Text(
              'Text size',
              style: TextStyle(
                color: p.ink,
                fontSize: 15.5.sp,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              '${widget.s.textSize.round()}',
              style: TextStyle(
                color: p.sub,
                fontSize: 14.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: p.accent,
            inactiveTrackColor: p.faint,
            thumbColor: p.accent,
            overlayColor: p.accent.withValues(alpha: 0.15),
            trackHeight: 3.dp,
          ),
          child: Slider(
            min: 12,
            max: 28,
            divisions: 16,
            value: widget.s.textSize,
            onChanged: (v) => setState(() => widget.s.textSize = v),
          ),
        ),
        Text(
          'The quick brown fox jumps over the lazy dog.',
          style: TextStyle(
            color: p.sub,
            fontSize: widget.s.textSize.sp,
            fontFamily: widget.s.monospace ? 'monospace' : 'Inter',
          ),
        ),
      ],
    );
  }
}

/// The Breeze PIN row, always shown so the option is never a mystery:
/// * a PIN exists: change it;
/// * no screen lock and nothing locked yet: make one;
/// * the phone has its own screen lock: greyed out, as that lock is used;
/// * no screen lock but files already locked: greyed out. A PIN made now
///   would open files that were locked under a screen lock since removed.
class _BreezePinRow extends StatefulWidget {
  const _BreezePinRow();

  @override
  State<_BreezePinRow> createState() => _BreezePinRowState();
}

class _BreezePinRowState extends State<_BreezePinRow> {
  late Future<(bool, bool)> _state = _read();

  static Future<(bool, bool)> _read() async =>
      (await hasBreezePin(), await hasScreenLock());

  void _refresh() => setState(() => _state = _read());

  @override
  Widget build(BuildContext context) {
    final store = NoteScope.of(context);
    final anyLocked =
        store.notes.any((n) => n.locked) || store.anyTrashedLocked;
    return FutureBuilder<(bool, bool)>(
      future: _state,
      builder: (context, snap) {
        final (hasPin, hasLock) = snap.data ?? (false, true);
        final String label;
        final String hint;
        VoidCallback? onTap;
        if (hasPin) {
          label = 'Change Breeze PIN';
          hint = 'Used when the phone has no screen lock';
          onTap = () async {
            await changePin(context);
            if (mounted) _refresh();
          };
        } else if (hasLock) {
          label = 'Breeze PIN';
          hint = "Not needed: your phone's screen lock protects files";
        } else if (anyLocked) {
          label = 'Breeze PIN';
          hint = "Turn the phone's screen lock back on to open locked files";
        } else {
          label = 'Set Breeze PIN';
          hint = 'Your phone has no screen lock; use a PIN instead';
          onTap = () async {
            await createPin(context);
            if (mounted) _refresh();
          };
        }
        final row = TapRow(
          icon: CupertinoIcons.number,
          label: label,
          hint: hint,
          onTap: onTap,
          chevron: onTap != null,
        );
        return Column(
          children: [
            const Hairline(),
            onTap == null
                ? Semantics(
                    enabled: false,
                    child: Opacity(opacity: 0.45, child: row),
                  )
                : row,
          ],
        );
      },
    );
  }
}

/// Fits its child to the box it is given without leaving side margins.
///
/// The child is laid out at the box's width, and if it is taller than the
/// box, at a wider width instead, until it fits the height at the scale that
/// maps that width back onto the box (a wider layout wraps fewer lines, so
/// it is also shorter). It is then painted scaled down by that factor, so it
/// spans the full width and the full height. A FittedBox could only shrink
/// it about its centre, leaving empty margins on both sides.
class _FitToScreen extends SingleChildRenderObjectWidget {
  const _FitToScreen({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFitToScreen();
}

class _RenderFitToScreen extends RenderProxyBox {
  double _scale = 1;

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  void performLayout() {
    final c = child!;
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;
    size = constraints.biggest;
    if (!h.isFinite) {
      c.layout(BoxConstraints.tightFor(width: w), parentUsesSize: true);
      _scale = 1;
      return;
    }
    // Laid out at width `x`, the child must fit the height h * x / w (the
    // box's height as seen at that scale), and is asked to fill it.
    bool fits(double x) {
      final room = h * x / w;
      c.layout(
        BoxConstraints(minWidth: x, maxWidth: x, minHeight: room),
        parentUsesSize: true,
      );
      return c.size.height <= room + 0.5;
    }

    if (fits(w)) {
      _scale = 1;
      return;
    }
    var lo = w, hi = w * 1.8;
    if (fits(hi)) {
      for (var i = 0; i < 8; i++) {
        final mid = (lo + hi) / 2;
        if (fits(mid)) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
    }
    fits(hi);
    // Never taller than the box, even if the widest try did not fit.
    _scale = math.min(w / hi, h / c.size.height);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scale == 1) return super.paint(context, offset);
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child!, offset),
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            child!.hitTest(result, position: position),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);
}
