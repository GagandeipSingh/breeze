import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scrollbar;
import 'glass_chrome.dart';

import '../data/note_scope.dart';
import '../state/settings.dart';
import '../data/note_store.dart';
import '../logic/list_text.dart';
import '../logic/text_stats.dart';
import 'file_look.dart';
import 'glass_surface.dart';
import 'kit.dart';
import 'lock_gate.dart';
import 'scale.dart';
import 'sheets.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashedNote>? _items;

  /// Multi-select, by trash file path. Non-empty means selecting.
  final Set<String> _sel = {};
  bool get _selecting => _sel.isNotEmpty;

  void _toggle(TrashedNote t) => setState(() {
    final k = t.file.path;
    if (!_sel.remove(k)) _sel.add(k);
  });

  List<TrashedNote> get _chosen =>
      (_items ?? const []).where((t) => _sel.contains(t.file.path)).toList();

  Future<void> _restoreSelected() async {
    final store = NoteScope.of(context);
    final chosen = _chosen;
    var done = 0;
    // One file failing does not abandon the rest, or leave them selected.
    for (final t in chosen) {
      try {
        await store.restore(t);
        done++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(_sel.clear);
    await _reload();
    if (!mounted) return;
    showToast(
      context,
      message: done < chosen.length
          ? 'Restored $done of ${chosen.length}'
          : done == 1
          ? 'Restored'
          : 'Restored $done files',
      icon: CupertinoIcons.arrow_uturn_left,
    );
  }

  Future<void> _deleteSelected() async {
    final store = NoteScope.of(context);
    final chosen = _chosen;
    final what = chosen.length == 1
        ? chosen.first.originalName
        : '${chosen.length} files';
    final ok = await showConfirm(
      context,
      title: 'Delete forever?',
      message: '$what will be permanently deleted. This cannot be undone.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok) return;
    // A file that was locked when trashed is still locked here.
    if (!mounted) return;
    if ((SettingsScope.of(context).lockFiles ||
            chosen.any(store.trashedLocked)) &&
        !await authenticate(context, 'Delete locked files')) {
      return;
    }
    for (final t in chosen) {
      await store.deleteForever(t);
    }
    if (!mounted) return;
    setState(_sel.clear);
    await _reload();
  }

  @override
  void initState() {
    super.initState();
    // After the first frame: _reload reads NoteScope, and an inherited
    // lookup inside initState throws — which left the list loading forever,
    // so neither the files nor the empty state ever showed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final store = NoteScope.of(context);
    final items = await store.trash();
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final store = NoteScope.of(context);
    final items = _items;

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_sel.clear);
      },
      child: GlassScaffold(
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
            'Trash',
            style: TextStyle(
              color: p.ink,
              fontSize: 17.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            if (items != null && items.isNotEmpty)
              RoundGlassButton(
                icon: CupertinoIcons.trash,
                semanticLabel: 'Empty trash',
                onPressed: () async {
                  final lockAll = SettingsScope.of(context).lockFiles;
                  final ok = await showConfirm(
                    context,
                    title: 'Empty trash?',
                    message:
                        'All files in the trash will be permanently deleted.',
                    confirmLabel: 'Empty',
                    danger: true,
                  );
                  if (ok &&
                      context.mounted &&
                      (!(lockAll || items.any(store.trashedLocked)) ||
                          await authenticate(
                            context,
                            'Empty trash with locked files',
                          ))) {
                    await store.emptyTrash();
                    if (mounted) setState(_sel.clear);
                    await _reload();
                  }
                },
              ),
            SizedBox(width: 8.dp),
          ],
        ),
        body: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width >= 720.dp ? 1400.dp : 760.dp,
                ),
                child: Padding(
                  padding: pagePadding(context),
                  child: Column(
                children: [
                  Pane(
                    tint: p.accent.withValues(alpha: 0.06),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          CupertinoIcons.info_circle_fill,
                          size: 20.dp,
                          color: p.accent,
                        ),
                        SizedBox(width: 12.dp),
                        Expanded(
                          child: Text(
                            'Files deleted in Breeze stay here for 30 days, then are deleted '
                            'permanently. Files deleted outside Breeze don\'t go to trash.',
                            style: TextStyle(
                              color: p.sub,
                              fontSize: 13.sp,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Gap(16),
                  Expanded(
                    child: items == null
                        ? const SizedBox.shrink()
                        : items.isEmpty
                        // Lifted: centred in the space under the info card it sat
                        // visibly below the middle of the screen.
                        ? Transform.translate(
                            offset: Offset(0, -56.dp),
                            child: const EmptyState(
                              icon: CupertinoIcons.trash,
                              title: 'Trash is empty',
                              hint:
                                  'Deleted files will appear here for 30 days.',
                              bg: false,
                            ),
                          )
                        : MediaQuery.sizeOf(context).width >= 720.dp
                        ? Scrollbar(
                            child: GridView.builder(
                              padding: EdgeInsets.only(
                                bottom: _selecting ? 90.dp : 24.dp,
                              ),
                              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 520.dp,
                                mainAxisSpacing: 10.dp,
                                crossAxisSpacing: 10.dp,
                                mainAxisExtent: 84.dp,
                              ),
                              itemCount: items.length,
                              itemBuilder: (c, i) => _TrashTile(
                                item: items[i],
                                selecting: _selecting,
                                selected: _sel.contains(items[i].file.path),
                                onTap: () =>
                                    _selecting ? _toggle(items[i]) : _menu(items[i]),
                                onLong: () => _toggle(items[i]),
                              ),
                            ),
                          )
                        : Scrollbar(
                            child: ListView(
                              padding: EdgeInsets.only(
                                bottom: _selecting ? 90.dp : 0,
                              ),
                              children: [
                                for (final t in items)
                                  Padding(
                                    padding: EdgeInsets.only(bottom: 10.dp),
                                    child: _TrashTile(
                                      item: t,
                                      selecting: _selecting,
                                      selected: _sel.contains(t.file.path),
                                      onTap: () =>
                                          _selecting ? _toggle(t) : _menu(t),
                                      onLong: () => _toggle(t),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_selecting) _selectBar(p, items ?? const []),
          ],
        ),
      ),
    );
  }

  Widget _selectBar(Pal p, List<TrashedNote> items) {
    final all = _sel.length == items.length;
    Widget action(
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color? color,
    }) => GlassPress(
      onTap: onTap,
      label: label,
      child: Padding(
        padding: EdgeInsets.all(10.dp),
        child: Icon(icon, size: 21.dp, color: color ?? p.accent),
      ),
    );
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: math.max(bottomInset + 18.dp, 24.dp),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760.dp),
          child: GlassSurface(
            radius: 24.dp,
            thick: true,
            padding: EdgeInsets.symmetric(horizontal: 8.dp, vertical: 6.dp),
            child: Row(
              children: [
                action(
                  CupertinoIcons.xmark,
                  'Cancel',
                  () => setState(_sel.clear),
                  color: p.ink,
                ),
                SizedBox(width: 4.dp),
                Text(
                  '${_sel.length} selected',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 14.5.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                action(
                  all
                      ? CupertinoIcons.checkmark_square_fill
                      : CupertinoIcons.checkmark_square,
                  all ? 'Select none' : 'Select all',
                  () => setState(() {
                    if (all) {
                      _sel.clear();
                    } else {
                      _sel.addAll(items.map((t) => t.file.path));
                    }
                  }),
                ),
                action(
                  CupertinoIcons.arrow_uturn_left,
                  'Restore',
                  _restoreSelected,
                ),
                action(
                  CupertinoIcons.trash,
                  'Delete forever',
                  _deleteSelected,
                  color: const Color(0xFFE5484D),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(TrashedNote t) async {
    final store = NoteScope.of(context);
    final choice = await showGlassMenu<String>(
      context,
      title: t.originalName,
      items: [
        ('restore', CupertinoIcons.arrow_uturn_left, 'Restore', false),
        ('delete', CupertinoIcons.trash, 'Delete forever', true),
      ],
    );
    if (choice == 'restore') {
      try {
        await store.restore(t);
      } catch (_) {
        if (mounted) {
          showToast(
            context,
            message: "Couldn't restore ${t.originalName}",
            icon: CupertinoIcons.exclamationmark_circle,
          );
        }
      }
      await _reload();
    } else if (choice == 'delete') {
      if (!mounted) return;
      final ok = await showConfirm(
        context,
        title: 'Delete forever?',
        message:
            '${t.originalName} will be permanently deleted. This cannot be undone.',
        confirmLabel: 'Delete',
        danger: true,
      );
      if (!ok || !mounted) return;
      if ((SettingsScope.of(context).lockFiles || store.trashedLocked(t)) &&
          !await authenticate(context, 'Delete ${t.originalName}')) {
        return;
      }
      await store.deleteForever(t);
      await _reload();
    }
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({
    required this.item,
    required this.onTap,
    this.onLong,
    this.selecting = false,
    this.selected = false,
  });
  final TrashedNote item;
  final VoidCallback onTap;
  final VoidCallback? onLong;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final days = item.remaining.inDays;
    final name = item.originalName;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot).toLowerCase() : '';
    final look = FileLook.of(ext);
    // The last few days are worth a warmer word.
    final soon = days <= 3;
    final left = days <= 0
        ? 'goes today'
        : (days == 1 ? '1 day left' : '$days days left');
    return GlassPress(
      onTap: onTap,
      onLongPress: onLong,
      label: name,
      child: GlassSurface(
        radius: 20.dp,
        tint: selected ? p.accent.withValues(alpha: 0.18) : null,
        padding: EdgeInsets.fromLTRB(16.dp, 14.dp, 8.dp, 14.dp),
        child: Row(
          children: [
            // Its type's badge, faded: the file is set aside, not gone.
            Opacity(
              opacity: selecting ? 1 : 0.7,
              child: FileBadge(
                look: look,
                size: 40.dp,
                selecting: selecting,
                selected: selected,
              ),
            ),
            SizedBox(width: 14.dp),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 16.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 3.dp),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              '${friendlyDate(item.deletedAt, short: true, h24: MediaQuery.alwaysUse24HourFormatOf(context))}  ·  ${humanSize(item.size)}  ·  ',
                        ),
                        TextSpan(
                          text: left,
                          style: soon
                              ? const TextStyle(
                                  color: Color(0xFFE5484D),
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.sub, fontSize: 12.sp),
                  ),
                ],
              ),
            ),
            if (!selecting)
              Padding(
                padding: EdgeInsets.all(8.dp),
                child: Icon(CupertinoIcons.ellipsis, size: 20.dp, color: p.sub),
              ),
          ],
        ),
      ),
    );
  }
}
