import 'package:flutter/widgets.dart';

import 'note_store.dart';

/// Makes the [NoteStore] reachable from any widget and rebuilds on change.
class NoteScope extends InheritedNotifier<NoteStore> {
  const NoteScope({super.key, required NoteStore store, required super.child})
    : super(notifier: store);

  static NoteStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteScope>()!.notifier!;
}
