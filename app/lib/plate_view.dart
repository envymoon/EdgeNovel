import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'theme.dart';

/// 章间立绘 as the reader meets it: between two chapters, the whole page, the
/// way a light novel puts a plate. Any tap, wheel or key goes on to the next
/// chapter; the reader does that part, this only shows the picture.
class PlateView extends StatelessWidget {
  const PlateView({
    super.key,
    required this.path,
    required this.theme,
    required this.onDone,
  });

  final String path;
  final ReadingTheme theme;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (e) {
      if (e is PointerScrollEvent) onDone();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDone,
      child: ColoredBox(
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
                            (_) => onDone(),
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
      ),
    ),
  );
}
