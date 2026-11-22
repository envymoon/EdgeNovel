import 'package:flutter/material.dart';

import 'easter_eggs.dart';
import 'theme.dart';

/// 彩蛋 — local reading achievements & rare in-reader surprise banners.
///
/// Undiscovered eggs stay hidden behind `???`; once triggered organically
/// during reading, they unlock here with their title, latest stat line, and
/// unlock date.
class EasterEggsPage extends StatefulWidget {
  final ReadingSettings settings;

  const EasterEggsPage({super.key, required this.settings});

  @override
  State<EasterEggsPage> createState() => _EasterEggsPageState();
}

class _EasterEggsPageState extends State<EasterEggsPage> {
  @override
  void initState() {
    super.initState();
    EasterEggEngine.instance.ensureLoaded();
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settings, EasterEggEngine.instance]),
      builder: (context, _) {
        final engine = EasterEggEngine.instance;
        final total = EasterEggEngine.catalog.length;
        final got = engine.unlockedCount;
        return Scaffold(
          backgroundColor: t.background,
          appBar: AppBar(
            backgroundColor: t.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: t.muted),
            title: Text(
              '彩蛋',
              style: TextStyle(color: t.text, fontSize: 17),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Material(
                color: t.muted.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  title: Text(
                    '阅读彩蛋',
                    style: TextStyle(color: t.text, fontSize: 14.5),
                  ),
                  subtitle: Text(
                    '仅使用本地阅读记录，偶尔在阅读时弹出轻量互动横幅，可一划关闭',
                    style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
                  ),
                  value: widget.settings.easterEggs,
                  onChanged: widget.settings.setEasterEggs,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text(
                    '已发现 $got / $total',
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '未触发的彩蛋保持神秘',
                    style: TextStyle(color: t.muted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final def in EasterEggEngine.catalog)
                _card(t, def, engine.unlocked[def.id]),
            ],
          ),
        );
      },
    );
  }

  Widget _card(ReadingTheme t, EasterEggDef def, EasterEggRecord? rec) {
    final unlocked = rec != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.muted.withValues(alpha: unlocked ? 0.09 : 0.045),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: t.muted.withValues(alpha: unlocked ? 0.22 : 0.10),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.text.withValues(alpha: unlocked ? 0.10 : 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: unlocked
                ? Icon(def.icon, color: t.text, size: 19)
                : Text(
                    '?',
                    style: TextStyle(
                      color: t.muted.withValues(alpha: 0.7),
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: unlocked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            def.title,
                            style: TextStyle(
                              color: t.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            rec.count > 1
                                ? '${_formatDate(rec.unlockedAtMs)} · ${rec.count} 次'
                                : _formatDate(rec.unlockedAtMs),
                            style: TextStyle(color: t.muted, fontSize: 11),
                          ),
                        ],
                      ),
                      if (rec.lastDetail.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          rec.lastDetail,
                          style: TextStyle(
                            color: t.muted,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (rec.bookTitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '《${rec.bookTitle}》',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.muted.withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      '???',
                      style: TextStyle(
                        color: t.muted.withValues(alpha: 0.65),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
