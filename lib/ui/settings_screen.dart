import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'glass_chrome.dart';

import '../data/note_scope.dart';
import '../state/settings.dart';
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
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 720.dp),
          child: Scrollbar(
            child: ListView(
              padding: pagePadding(context),
              children: [
          const SectionTitle('Security'),
          Pane(
            child: Column(
              children: [
                SwitchRow(
                  icon: CupertinoIcons.lock_shield,
                  label: 'Lock all files',
                  hint:
                      'Your fingerprint or screen lock (or a Breeze PIN on a phone '
                      'without one) to open any file. You can also lock single files '
                      'from their ⋯ menu.',
                  value: s.lockFiles,
                  // On needs a screen lock to mean anything; off needs the same
                  // proof as opening, or the switch is a way round every lock.
                  onChanged: (v) async {
                    if (v) {
                      final store = NoteScope.of(context);
                      final anyLocked =
                          store.notes.any((n) => n.locked) ||
                          store.anyTrashedLocked;
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
                // Only once a Breeze PIN exists (made when locking on a phone
                // with no screen lock).
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
                              hint:
                                  'Used to open locked files on a phone with no screen lock',
                              onTap: () => changePin(context),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),

          const SectionTitle('Look'),
          Pane(
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
                    const Spacer(),
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
          ),

          const SectionTitle('Feel'),
          Pane(
            child: Column(
              children: [
                SwitchRow(
                  icon: CupertinoIcons.hand_draw,
                  label: 'Delete by swiping',
                  hint: 'Swipe a file from right to left to delete',
                  value: s.swipeDelete,
                  onChanged: (v) => s.swipeDelete = v,
                ),
                const Hairline(),
                SwitchRow(
                  icon: CupertinoIcons.floppy_disk,
                  label: 'Autosave',
                  hint: 'Keeps your note if you quit by accident',
                  value: s.autosave,
                  onChanged: (v) => s.autosave = v,
                ),
                const Hairline(),
                SwitchRow(
                  icon: CupertinoIcons.arrow_up_arrow_down,
                  label: 'Remember scroll position',
                  hint: 'Return to where you left off in a file',
                  value: s.rememberScroll,
                  onChanged: (v) => s.rememberScroll = v,
                ),
                const Hairline(),
                SwitchRow(
                  icon: CupertinoIcons.tag,
                  label: 'Tags',
                  hint: 'Use virtual folders to organize files',
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
          ),

          const SectionTitle('Other'),
          Pane(
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
          ),
        ],
      ),
    ))),
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
