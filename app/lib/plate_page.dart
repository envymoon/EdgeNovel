import 'package:flutter/material.dart' hide Text;

import 'analysis_run_card.dart';
import 'app_localizations.dart';
import 'cover_generator.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/image.dart';
import 'theme.dart';

/// 章间立绘: the reader picks how far apart and presses 生成; the pictures are
/// drawn once, in the background queue, and shown between chapters. What they
/// show is for the reader to find there, so this page says how many there are
/// and nothing about them.
class PlatePage extends StatefulWidget {
  const PlatePage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;

  static const choices = [5, 10, 20, 50];

  @override
  State<PlatePage> createState() => _PlatePageState();
}

class _PlatePageState extends State<PlatePage> {
  late int _every = widget.reader.plateEveryFor(widget.book.id) ?? 10;
  int _drawn = 0;
  int _seen = -1;

  @override
  void initState() {
    super.initState();
    widget.reader.addListener(_onReader);
    _count();
  }

  @override
  void dispose() {
    widget.reader.removeListener(_onReader);
    super.dispose();
  }

  /// Count again as each picture lands, and when a job ends.
  void _onReader() {
    final done = widget.reader.plateProgress?.done ?? -1;
    if (done != _seen) {
      _seen = done;
      _count();
    }
  }

  Future<void> _count() async {
    // Every plate there is, whatever spacing drew it.
    final n = await platesDrawn(bookId: widget.book.id, every: 1);
    if (mounted) setState(() => _drawn = n);
  }

  Future<void> _clear() async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text('清除已画的立绘？', style: TextStyle(color: t.text, fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.reader.deletePlatesFor(widget.book.id);
    await _count();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final reader = widget.reader;
    final id = widget.book.id;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('章间立绘', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListenableBuilder(
              listenable: reader,
              builder: (context, _) {
                final state = reader.plateStateFor(id);
                final job = reader.plateEveryFor(id);
                // A job in hand keeps its spacing until it ends or is cancelled.
                final every = state == AiTaskState.none
                    ? _every
                    : job ?? _every;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: [
                    AnalysisRunCard(
                      reader: reader,
                      settings: widget.settings,
                      icon: Icons.photo_outlined,
                      title: '章间立绘',
                      coverage: _drawn > 0 ? '已画 $_drawn 张' : '',
                      options: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final n in PlatePage.choices)
                            ChoiceChip(
                              label: Text('每 $n 章'),
                              selected: n == every,
                              visualDensity: VisualDensity.compact,
                              onSelected: state == AiTaskState.none
                                  ? (_) => setState(() => _every = n)
                                  : null,
                            ),
                        ],
                      ),
                      complete: false,
                      state: state,
                      startLabel: '生成',
                      idleText: _drawn == 0 ? '尚未生成' : '',
                      error: reader.plateError,
                      onStart: () => startWithModel(
                        context,
                        widget.settings,
                        hasModel: coverGeneratorReady,
                        missing: AppPlatformSupport.hasBundledImageEngine
                            ? '需要先下载生图模型'
                            : '需要先下载生图引擎和模型',
                        start: () => reader.drawPlatesFor(widget.book, every),
                      ),
                      onPause: () => reader.stopPlatesFor(id),
                      onRunNow: () => reader.runPlatesNow(id),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      children: [
                        if (state != AiTaskState.none)
                          TextButton(
                            onPressed: () => reader.cancelPlatesFor(id),
                            child: const Text('取消生成'),
                          ),
                        if (_drawn > 0)
                          TextButton(
                            onPressed: _clear,
                            child: const Text(
                              '清除已画的立绘',
                              style: TextStyle(color: Color(0xFFB3574D)),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
