import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

import 'platform_support.dart';

/// Desktop-only file dropping. Mobile pages only see paths and never depend on
/// the plugin's event types, so this file can later become a platform package
/// without touching the shelf.
class DesktopBookDrop extends StatelessWidget {
  const DesktopBookDrop({
    super.key,
    required this.child,
    required this.onDraggingChanged,
    required this.onPathsDropped,
  });

  final Widget child;
  final ValueChanged<bool> onDraggingChanged;
  final ValueChanged<Iterable<String>> onPathsDropped;

  @override
  Widget build(BuildContext context) {
    if (!AppPlatformSupport.supportsBookDrop) return child;
    return DropTarget(
      onDragEntered: (_) => onDraggingChanged(true),
      onDragExited: (_) => onDraggingChanged(false),
      onDragDone: (detail) {
        onDraggingChanged(false);
        onPathsDropped(detail.files.map((file) => file.path));
      },
      child: child,
    );
  }
}
