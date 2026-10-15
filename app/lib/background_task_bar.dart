import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'theme.dart';

/// The one place background model work shows itself, at the top of every
/// screen except the reader's page — where nothing should sit between the
/// reader and the text. Tapping it opens the background settings, which is
/// where the work is paused, resumed or given more or less of the device.
///
/// It appears when something is running, waiting to run, or has failed. Work
/// the reader paused on purpose stays out of sight until they come back to it.
class BackgroundTaskBar extends StatelessWidget {
  const BackgroundTaskBar({
    super.key,
    required this.reader,
    required this.settings,
    required this.onOpen,
  });

  final ReaderState reader;
  final ReadingSettings settings;
  final VoidCallback onOpen;

  static bool shows(ReaderState r) =>
      r.aiBusy || r.aiHasRunnable || r.aiHasFailed;

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    final top = MediaQuery.paddingOf(context).top;
    final activity = reader.aiActivity;
    final failed = activity == null && reader.aiHasFailed;
    final line = activity != null
        ? _running(activity)
        : failed
        ? '有后台任务失败'
        : [reader.aiQueueState, ?reader.aiQueueDetail].join(' · ');
    return Material(
      color: t.surface,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.outline)),
          ),
          padding: EdgeInsets.fromLTRB(16, top + 6, 10, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (activity != null)
                    Bloom(color: t.muted, size: 16)
                  else
                    Icon(
                      failed ? Icons.error_outline : Icons.schedule_outlined,
                      size: 16,
                      color: failed ? const Color(0xFFB3574D) : t.muted,
                    ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      line,
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: 12),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: t.muted),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 2,
                child: activity == null
                    ? null
                    : LinearProgressIndicator(
                        value: activity.fraction,
                        minHeight: 2,
                        color: t.text.withValues(alpha: 0.55),
                        backgroundColor: t.muted.withValues(alpha: 0.14),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「《诡秘之主》章节分析 · 120 / 1392 · 约 15 分钟」
  String _running(AiActivity a) => [
    '《${a.title}》${a.label}',
    if (a.total > 0) '${a.done} / ${a.total}' else '正在启动本机引擎…',
    if (a.remaining != null) formatRemaining(a.remaining!),
  ].join(' · ');
}
