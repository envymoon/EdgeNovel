import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'theme.dart';

/// One tap to 夜读 and back (see [ReadingSettings.toggleNight]): a toolbar icon
/// on the shelf, and in the reader a button where a left thumb rests.
class NightToggle extends StatelessWidget {
  final ReadingSettings settings;
  final bool floating;

  /// The reader keeps the button in its Scaffold and only hides it: a Scaffold
  /// scales a floating button in each time one arrives, so it would rise into
  /// place with every tap instead of being there with the bars.
  final bool visible;

  const NightToggle({
    super.key,
    required this.settings,
    this.floating = false,
    this.visible = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final t = settings.theme;
        final icon = Icon(
          t.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        );
        final tooltip = context.tr(t.isDark ? '日间' : '夜间');
        if (!floating) {
          return IconButton(
            tooltip: tooltip,
            icon: icon,
            color: t.muted,
            onPressed: settings.toggleNight,
          );
        }
        return FloatingActionButton.small(
          heroTag: null,
          tooltip: tooltip,
          elevation: 1,
          backgroundColor: t.raisedSurface,
          foregroundColor: t.text,
          onPressed: settings.toggleNight,
          child: icon,
        );
      },
    );
  }
}
