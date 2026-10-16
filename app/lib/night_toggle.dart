import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'theme.dart';

/// One tap to 夜读 and back (see [ReadingSettings.toggleNight]): a toolbar icon
/// on the shelf, and in the reader a button where a left thumb rests.
class NightToggle extends StatelessWidget {
  final ReadingSettings settings;
  final bool floating;

  const NightToggle({super.key, required this.settings, this.floating = false});

  @override
  Widget build(BuildContext context) {
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
