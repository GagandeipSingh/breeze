import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'kit.dart';
import 'scale.dart';
import 'sheets.dart';

/// Where a file opened from elsewhere lives, in words, and whether its
/// folder can be opened in the phone's file manager.
class FileWhere {
  const FileWhere(this.where, this.canShow);
  final String where;
  final bool canShow;
}

const _files = MethodChannel('breeze/open');

/// Where the file at [uri] lives ("Internal storage › Download", or the app
/// that holds it, such as Google Drive).
Future<FileWhere> locateFile(String uri) async {
  try {
    final m = await _files.invokeMapMethod<String, dynamic>('locate', {
      'uri': uri,
    });
    return FileWhere(
      (m?['where'] as String?) ?? 'Another app',
      m?['canShow'] == true,
    );
  } catch (_) {
    return const FileWhere('On this phone', false);
  }
}

/// Opens the folder holding [uri] in the phone's file manager.
Future<bool> showFileInFiles(String uri) async {
  try {
    return await _files.invokeMethod<bool>('showInFiles', {'uri': uri}) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Where a file lives, as one small chip: its folder's name, and when the
/// phone's Files app can open that folder, a tap does so (the arrow says
/// it leaves the app). Used wherever an opened file shows its place.
class PlaceChip extends StatelessWidget {
  const PlaceChip({
    super.key,
    required this.uri,
    required this.at,
    this.inline = false,
  });

  final String uri;
  final FileWhere? at;

  /// Drawn as a link inside a line of text (a list row's subtitle) rather
  /// than as a chip of its own.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final canShow = at?.canShow == true;
    final chip = inline
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.folder_fill,
                size: 12.dp,
                color: canShow ? p.accent : p.sub,
              ),
              SizedBox(width: 4.dp),
              Flexible(
                child: Text(
                  at?.where ?? 'Opened file',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: canShow ? p.accent : p.sub,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          )
        : Container(
            padding: EdgeInsets.symmetric(horizontal: 9.dp, vertical: 4.dp),
            decoration: BoxDecoration(
              color: (canShow ? p.accent : p.ink).withValues(
                alpha: p.dark ? 0.14 : 0.08,
              ),
              borderRadius: BorderRadius.circular(10.dp),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.folder,
                  size: 13.dp,
                  color: canShow ? p.accent : p.sub,
                ),
                SizedBox(width: 5.dp),
                Flexible(
                  child: Text(
                    at?.where ?? 'Opened file',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: canShow ? p.accent : p.ink,
                      fontSize: 12.5.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (canShow) ...[
                  SizedBox(width: 3.dp),
                  Icon(
                    CupertinoIcons.arrow_up_right,
                    size: 11.dp,
                    color: p.accent,
                  ),
                ],
              ],
            ),
          );
    if (!canShow) return chip;
    return Semantics(
      button: true,
      label: 'Show in Files, ${at!.where}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          HapticFeedback.selectionClick();
          if (!await showFileInFiles(uri) && context.mounted) {
            showToast(
              context,
              message: 'No file manager could open its folder',
              icon: CupertinoIcons.folder,
            );
          }
        },
        child: chip,
      ),
    );
  }
}
