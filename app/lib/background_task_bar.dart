import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'theme.dart';
import 'tts_prepare.dart';

/// The one place background model work shows itself, at the top of every
/// screen except the reader's page — where nothing should sit between the
/// reader and the text. Tapping it opens the background settings, which is
/// where the work is paused, resumed or given more or less of the device.
///
/// It appears when something is running, waiting to run, or has failed. Work
/// the reader paused on purpose stays out of sight until they come back to it.
/// 提前合成 runs beside the queue rather than in it, so it gets a line of its
/// own, which opens 听书设置 instead.
class BackgroundTaskBar extends StatelessWidget {
  const BackgroundTaskBar({
    super.key,
    required this.reader,
    required this.settings,
    required this.onOpen,
    required this.onOpenSpeech,
  });

  final ReaderState reader;
  final ReadingSettings settings;
  final VoidCallback onOpen;
  final VoidCallback onOpenSpeech;

  static bool _queue(ReaderState r) =>
      r.aiBusy || r.aiHasRunnable || r.aiHasFailed;

  static bool shows(ReaderState r) => _queue(r) || TtsPrepare.instance.running;

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    final top = MediaQuery.paddingOf(context).top;
    final activity = reader.aiActivity;
    final failed = activity == null && reader.aiHasFailed;
    final speech = TtsPrepare.instance.activity;
    return Material(
      color: t.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.outline)),
        ),
        padding: EdgeInsets.only(top: top),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_queue(reader))
              TaskLine(
                theme: t,
                text: activity != null
                    ? describeActivity(activity)
                    : failed
                    ? '有后台任务失败'
                    : [reader.aiQueueState, ?reader.aiQueueDetail].join(' · '),
                activity: activity,
                icon: failed ? Icons.error_outline : Icons.schedule_outlined,
                iconColor: failed ? const Color(0xFFB3574D) : null,
                onTap: onOpen,
              ),
            if (speech != null)
              TaskLine(
                theme: t,
                text: describeActivity(speech),
                activity: speech,
                onTap: onOpenSpeech,
              ),
          ],
        ),
      ),
    );
  }
}

/// One task's line: the star while it runs (an icon while it waits or has
/// failed), what it is, and a hairline of progress under it.
class TaskLine extends StatelessWidget {
  const TaskLine({
    super.key,
    required this.theme,
    required this.text,
    required this.activity,
    required this.onTap,
    this.icon = Icons.schedule_outlined,
    this.iconColor,
  });

  final ReadingTheme theme;
  final String text;

  /// The running work; null when it is waiting or has failed.
  final AiActivity? activity;
  final VoidCallback onTap;
  final IconData icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final a = activity;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 10, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (a != null)
                  Bloom(color: t.muted, size: 16)
                else
                  Icon(icon, size: 16, color: iconColor ?? t.muted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    text,
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
              child: a == null
                  ? null
                  : LinearProgressIndicator(
                      value: a.fraction,
                      minHeight: 2,
                      color: t.text.withValues(alpha: 0.55),
                      backgroundColor: t.muted.withValues(alpha: 0.14),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「《诡秘之主》章节分析 · 120 / 1392 · 约 15 分钟」
String describeActivity(AiActivity a) => [
  '《${a.title}》${a.label}',
  if (a.total > 0) '${a.done} / ${a.total}' else '正在启动本机引擎…',
  if (a.remaining != null) formatRemaining(a.remaining!),
].join(' · ');
