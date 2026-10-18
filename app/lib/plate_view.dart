import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'reader_interaction.dart';
import 'theme.dart';

/// 章间立绘 as the reader meets it: between two chapters, the whole page, the
/// way a light novel puts a plate — a page of its own, met reading on and
/// reading back. It turns like a page: a tap on the back side, a swipe to the
/// right or the wheel up goes back into the chapter before it; anything else
/// goes on. The reader does the going, this only shows the picture.
class PlateView extends StatelessWidget {
  const PlateView({
    super.key,
    required this.path,
    required this.theme,
    required this.compactTapZones,
    required this.onForward,
    required this.onBack,
  });

  final String path;
  final ReadingTheme theme;
  final bool compactTapZones;
  final VoidCallback onForward;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (e) {
      if (e is PointerScrollEvent) {
        e.scrollDelta.dy < 0 ? onBack() : onForward();
      }
    },
    child: LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) =>
            resolveReaderTap(
                  x: d.localPosition.dx,
                  width: constraints.maxWidth,
                  compact: compactTapZones,
                  annotationMode: false,
                ) ==
                ReaderTapAction.previousPage
            ? onBack()
            : onForward(),
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 0) onBack();
          if (v < 0) onForward();
        },
        child: _picture(),
      ),
    ),
  );

  Widget _picture() => ColoredBox(
        color: theme.background,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          builder: (context, v, child) => Opacity(opacity: v, child: child),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(path),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        // A plate deleted under us is simply not shown.
                        errorBuilder: (context, _, _) {
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => onForward(),
                          );
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  '轻触继续',
                  style: TextStyle(color: theme.muted, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
      );
}
