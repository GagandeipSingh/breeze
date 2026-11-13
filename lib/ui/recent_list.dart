import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/note_store.dart';
import '../data/recent_files.dart';
import '../logic/list_text.dart';
import 'file_look.dart';
import 'glass_surface.dart';
import 'kit.dart';
import 'recent_sheet.dart';
import 'scale.dart';
import 'sheets.dart';

/// The home list in Recent mode: files opened from the phone or a cloud
/// app, newest first, with Browse at the top to open another. Shown in the
/// list's place (the clock in the header switches to it and back), so
/// there is no sheet to dismiss.
class RecentList extends StatefulWidget {
  const RecentList({
    super.key,
    required this.items,
    this.query = '',
    required this.onOpen,
    required this.onBrowse,
    required this.onRemove,
  });

  final List<RecentFile> items;

  /// The search typed above, matched against file names.
  final String query;
  final void Function(RecentFile) onOpen;
  final VoidCallback onBrowse;
  final Future<void> Function(RecentFile) onRemove;

  @override
  State<RecentList> createState() => _RecentListState();
}

class _RecentListState extends State<RecentList> {
  /// Where each file lives, looked up once.
  final _where = <String, Future<FileWhere>>{};

  Future<FileWhere> _locate(RecentFile r) =>
      _where[r.uri] ??= locateFile(r.uri);

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final q = widget.query.toLowerCase();
    final items = q.isEmpty
        ? widget.items
        : [
            for (final r in widget.items)
              if (r.name.toLowerCase().contains(q)) r,
          ];
    final pad = EdgeInsets.fromLTRB(16, 4.dp, 16, 120.dp);
    // Nothing to list: the message sits in the middle of the free space.
    if (items.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760.dp),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 4.dp, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: q.isEmpty ? _browse(p) : const SizedBox.shrink(),
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 100.dp),
                  child: Center(child: _empty(p, searching: q.isNotEmpty)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760.dp),
        child: Scrollbar(
          child: ListView(
            padding: pad,
            children: [
              if (q.isEmpty) ...[_browse(p), SizedBox(height: 10.dp)],
              for (final r in items)
                Padding(
                  padding: EdgeInsets.only(bottom: 10.dp),
                  child: _row(p, r),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _browse(Pal p) => Semantics(
    button: true,
    label: 'Browse files on this phone or in the cloud',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onBrowse();
        },
        child: GlassSurface(
        radius: 20.dp,
        padding: EdgeInsets.fromLTRB(16.dp, 14.dp, 14.dp, 14.dp),
        child: Row(
          children: [
            SizedBox(
              width: 44.dp,
              child: Icon(CupertinoIcons.folder, color: p.accent, size: 24.dp),
            ),
            SizedBox(width: 14.dp),
            Expanded(
              child: Text(
                'Browse files',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 16.dp, color: p.sub),
          ],
        ),
      ),
    )),
  );

  Widget _empty(Pal p, {required bool searching}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        searching ? CupertinoIcons.search : CupertinoIcons.clock,
        size: 34.dp,
        color: p.sub,
      ),
      SizedBox(height: 10.dp),
      Text(
        searching ? 'No matches' : 'No opened files yet',
        style: TextStyle(
          color: p.ink,
          fontSize: 16.sp,
          fontWeight: FontWeight.w600,
        ),
      ),
      SizedBox(height: 4.dp),
      Text(
        searching ? 'Try another name.' : 'Files you open show here.',
        style: TextStyle(color: p.sub, fontSize: 13.5.sp),
      ),
    ],
  );

  Widget _row(Pal p, RecentFile r) {
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final ext = NoteStore.realExt(r.name).toLowerCase();
    final look = FileLook.of(ext);
    final stem = ext.isEmpty
        ? r.name
        : r.name.substring(0, r.name.length - ext.length);
    return Semantics(
      button: true,
      label: '${r.name}, opened ${friendlyDate(r.openedAt, h24: h24)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onOpen(r);
        },
        onLongPress: () => _menu(r, look),
        child: GlassSurface(
          radius: 20.dp,
          padding: EdgeInsets.fromLTRB(16.dp, 14.dp, 8.dp, 14.dp),
          child: Row(
            children: [
              FileBadge(look: look, size: 44.dp),
              SizedBox(width: 14.dp),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stem.isEmpty ? r.name : stem,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.ink,
                        fontSize: 16.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 3.dp),
                    // Type, folder and time on one quiet line. Showing the
                    // folder in Files is in the ••• menu, not a link here.
                    FutureBuilder<FileWhere>(
                      future: _locate(r),
                      builder: (_, w) {
                        final when = friendlyDate(
                          r.openedAt,
                          h24: h24,
                        ).replaceFirst('Today, ', '');
                        final where = w.data?.where;
                        return Text.rich(
                          TextSpan(
                            children: [
                              if (ext.isNotEmpty)
                                TextSpan(
                                  text:
                                      '${ext.substring(1).toUpperCase()}  ·  ',
                                  style: TextStyle(
                                    color: look.ink(p),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              if (where != null) TextSpan(text: '$where  ·  '),
                              TextSpan(text: when),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.sub, fontSize: 13.sp),
                        );
                      },
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'More for ${r.name}',
                onPressed: () => _menu(r, look),
                icon: Icon(CupertinoIcons.ellipsis, size: 18.dp, color: p.sub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _show(RecentFile r) async {
    HapticFeedback.selectionClick();
    if (!await showFileInFiles(r.uri) && mounted) {
      showToast(
        context,
        message: 'No file manager could open its folder',
        icon: CupertinoIcons.folder,
      );
    }
  }

  Future<void> _menu(RecentFile r, FileLook look) async {
    final w = await _locate(r);
    if (!mounted) return;
    final pick = await showGlassMenu<String>(
      context,
      title: r.name,
      leading: FileBadge(look: look, size: 34.dp),
      items: [
        if (w.canShow)
          ('show', CupertinoIcons.folder_open, 'Show in Files', false),
        ('remove', CupertinoIcons.xmark_circle, 'Remove from Recent', true),
      ],
    );
    if (!mounted) return;
    if (pick == 'show') {
      await _show(r);
    } else if (pick == 'remove') {
      await widget.onRemove(r);
      if (mounted) {
        showToast(
          context,
          message: 'Removed from Recent. The file is not deleted.',
          icon: CupertinoIcons.checkmark_alt,
        );
      }
    }
  }
}
