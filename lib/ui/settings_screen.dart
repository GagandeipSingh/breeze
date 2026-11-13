import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isDesktop = screenWidth >= 900.dp;

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
        final availableHeight = constraints.maxHeight - clearTop - bottomInset;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            36.dp,
            clearTop,
            36.dp,
            bottomInset + 28.dp,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, availableHeight - 32.dp),
            ),
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
        );
      },
    );
  }

  Widget _desktopLookPane(
    BuildContext context,
    Pal p,
    Settings s,
  ) {
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
                  Icon(
                    CupertinoIcons.paintbrush,
                    size: 20.dp,
                    color: p.accent,
                  ),
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
              } else if (await authenticate(
                context,
                'Turn off file lock',
              )) {
                s.lockFiles = false;
              }
            },
          ),
          FutureBuilder<bool>(
            future: hasBreezePin(),
            builder: (context, snap) => snap.data != true
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      const Hairline(),
                      TapRow(
                        icon: CupertinoIcons.number,
                        label: 'Change Breeze PIN',
                        hint: 'Used when phone has no screen lock',
                        onTap: () => changePin(context),
                      ),
                    ],
                  ),
          ),
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
              } else if (await authenticate(
                context,
                'Turn off file lock',
              )) {
                s.lockFiles = false;
              }
            },
          ),
          FutureBuilder<bool>(
            future: hasBreezePin(),
            builder: (context, snap) => snap.data != true
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      const Hairline(),
                      TapRow(
                        icon: CupertinoIcons.number,
                        label: 'Change Breeze PIN',
                        hint: 'Used when phone has no screen lock',
                        onTap: () => changePin(context),
                      ),
                    ],
                  ),
          ),
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
              Icon(
                CupertinoIcons.paintbrush,
                size: 20.dp,
                color: p.accent,
              ),
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

  Widget _otherPane(
    BuildContext context,
    Pal p,
    Settings s,
    NoteStore store,
  ) {
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
