import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'ai_page.dart';
import 'analysis_run_card.dart';
import 'app_localizations.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

class _QaTurn {
  final String question;
  final String phase; // searching | thinking | answering | done | error
  final String answer;
  final List<AskBookSource> sources;
  final String? error;

  const _QaTurn({
    required this.question,
    required this.phase,
    this.answer = '',
    this.sources = const [],
    this.error,
  });

  _QaTurn copyWith({
    String? phase,
    String? answer,
    List<AskBookSource>? sources,
    String? error,
  }) => _QaTurn(
    question: question,
    phase: phase ?? this.phase,
    answer: answer ?? this.answer,
    sources: sources ?? this.sources,
    error: error ?? this.error,
  );
}

/// 问问挚阅: single-question book Q&A powered by local BGE embeddings +
/// Qwen3 chat in thinking mode with live streaming output.
class AskBookPage extends StatefulWidget {
  const AskBookPage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
    required this.onOpenChapter,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;
  final Future<void> Function(int? chapter, int? offset) onOpenChapter;

  @override
  State<AskBookPage> createState() => _AskBookPageState();
}

class _AskBookPageState extends State<AskBookPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  _QaTurn? _turn;
  StreamSubscription<AskBookEvent>? _askSub;

  AiStatus? _ai;
  IndexStatus? _index;
  bool _loadingStatus = true;
  bool _asking = false;

  AiTaskState? _lastIndexState;
  int _lastIndexDone = -1;

  @override
  void initState() {
    super.initState();
    widget.reader.addListener(_onReader);
    _refreshStatus();
  }

  @override
  void dispose() {
    _askSub?.cancel();
    widget.reader.removeListener(_onReader);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onReader() {
    final state = widget.reader.indexStateFor(widget.book.id);
    final done = widget.reader.indexProgress?.done ?? 0;
    final changed = state != _lastIndexState;
    final stepped =
        state == AiTaskState.running && done != _lastIndexDone && done % 20 == 0;
    _lastIndexState = state;
    _lastIndexDone = done;
    if (changed || stepped) {
      _refreshStatus();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshStatus() async {
    try {
      final results = await Future.wait<Object>([
        aiStatus(),
        indexStatus(path: widget.book.path, bookId: widget.book.id),
      ]);
      if (!mounted) return;
      setState(() {
        _ai = results[0] as AiStatus;
        _index = results[1] as IndexStatus;
        _loadingStatus = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingStatus = false);
    }
  }

  bool get _hasChatModel => (_ai?.engine ?? false) && _ai?.model != null;
  bool get _hasEmbedModel => _ai?.embedModel != null;
  int get _indexedChapters => _index?.indexed ?? 0;
  int get _totalChapters => _index?.total ?? widget.book.chapterCount;
  bool get _indexComplete =>
      _totalChapters > 0 && _indexedChapters >= _totalChapters;
  bool get _canAsk =>
      !_loadingStatus &&
      _hasChatModel &&
      _hasEmbedModel &&
      _indexedChapters > 0 &&
      !_asking;

  Future<void> _openAiSetup() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AiPage(settings: widget.settings)),
    );
    if (mounted) _refreshStatus();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _submit() {
    final q = _input.text.trim();
    if (q.isEmpty || !_canAsk) return;
    _input.clear();
    _askSub?.cancel();

    setState(() {
      _asking = true;
      // Single-question window: each new question replaces the previous turn.
      _turn = _QaTurn(question: q, phase: 'searching');
    });
    _scrollToBottom();

    final stream = askBook(
      path: widget.book.path,
      bookId: widget.book.id,
      question: q,
    );

    _askSub = stream.listen(
      (event) {
        if (!mounted) return;
        final cur = _turn;
        if (cur == null) return;
        setState(() {
          switch (event.phase) {
            case 'searching':
              _turn = cur.copyWith(phase: 'searching');
            case 'thinking':
              _turn = cur.copyWith(
                phase: 'thinking',
                sources: event.sources.isNotEmpty ? event.sources : cur.sources,
              );
            case 'answering':
              _turn = cur.copyWith(
                phase: 'answering',
                answer: cur.answer + event.delta,
              );
            case 'done':
              _turn = cur.copyWith(
                phase: 'done',
                answer: event.answer.isNotEmpty ? event.answer : cur.answer,
                sources: event.sources.isNotEmpty ? event.sources : cur.sources,
              );
              _asking = false;
          }
        });
        _scrollToBottom();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _turn = _turn?.copyWith(phase: 'error', error: '$e');
          _asking = false;
        });
        _scrollToBottom();
      },
      onDone: () {
        if (!mounted) return;
        if (_asking) {
          setState(() {
            if (_turn != null && _turn!.phase != 'error') {
              _turn = _turn!.copyWith(phase: 'done');
            }
            _asking = false;
          });
        }
      },
      cancelOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final showDepCard =
        !_loadingStatus && (!_hasChatModel || !_hasEmbedModel || !_indexComplete);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '问问挚阅 · ${widget.book.title}',
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 16.5),
        ),
        actions: [
          IconButton(
            tooltip: 'AI 模型设置',
            icon: Icon(Icons.tune_outlined, color: t.muted, size: 20),
            onPressed: _openAiSetup,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Expanded(
                  child: _loadingStatus
                      ? Center(child: Bloom(color: t.muted, size: 30))
                      : ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                          children: [
                            if (showDepCard) ...[
                              _dependencyPanel(t),
                              const SizedBox(height: 16),
                            ],
                            if (_turn == null)
                              _emptyState(t)
                            else
                              _singleTurnView(t, _turn!),
                          ],
                        ),
                ),
                _inputBar(t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dependencyPanel(ReadingTheme t) {
    final modelsReady = _hasChatModel && _hasEmbedModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.outline),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '使用「问问挚阅」需要以下本地依赖',
                style: TextStyle(
                  color: t.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              _depRow(
                t,
                ok: _hasChatModel,
                title: '对话模型（Qwen3 0.6B 标准版 / 1.7B 高配版）',
                detail: _hasChatModel ? '已安装' : '未安装 · 负责理解问题并组织回答',
              ),
              const SizedBox(height: 7),
              _depRow(
                t,
                ok: _hasEmbedModel,
                title: '向量模型（BGE small 中文，约 48 MB）',
                detail: _hasEmbedModel ? '已安装' : '未安装 · 负责全书语义召回',
              ),
              const SizedBox(height: 7),
              _depRow(
                t,
                ok: _indexComplete,
                partial: _indexedChapters > 0 && !_indexComplete,
                title: '本书语义索引',
                detail: _indexComplete
                    ? '已完成（$_indexedChapters / $_totalChapters 章）'
                    : _indexedChapters > 0
                        ? '已建立 $_indexedChapters / $_totalChapters 章（已可提问，建议补全）'
                        : '尚未建立 · 需在下方建立后才能提问',
              ),
              if (!modelsReady) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _openAiSetup,
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: const Text('前往安装依赖模型'),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (modelsReady && !_indexComplete) ...[
          const SizedBox(height: 10),
          SearchIndexCard(
            book: widget.book,
            reader: widget.reader,
            settings: widget.settings,
            done: _indexedChapters,
            total: _totalChapters,
          ),
        ],
      ],
    );
  }

  Widget _depRow(
    ReadingTheme t, {
    required bool ok,
    bool partial = false,
    required String title,
    required String detail,
  }) {
    final color = ok
        ? const Color(0xFF4D8A64)
        : partial
            ? const Color(0xFFB3863E)
            : const Color(0xFFB3574D);
    final icon = ok
        ? Icons.check_circle_outline
        : partial
            ? Icons.timelapse_outlined
            : Icons.error_outline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: t.text, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(detail, style: TextStyle(color: t.muted, fontSize: 11.5)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyState(ReadingTheme t) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 44),
    child: Column(
      children: [
        Icon(
          Icons.forum_outlined,
          size: 32,
          color: t.muted.withValues(alpha: 0.55),
        ),
        const SizedBox(height: 12),
        Text(
          _canAsk
              ? '可以问关于《${widget.book.title}》的任何问题，\n挚阅会结合全书索引与人物档案为你作答。'
              : '完成上方依赖准备后，即可自由提问。',
          translate: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: t.muted,
            fontSize: 13,
            height: 1.6,
          ),
        ),
      ],
    ),
  );

  String? _statusLabel(String phase) => switch (phase) {
    'searching' => '查询中',
    'thinking' => '思考中',
    'answering' => '回答中',
    _ => null,
  };

  Widget _singleTurnView(ReadingTheme t, _QaTurn turn) {
    final status = _statusLabel(turn.phase);
    final showDots =
        (turn.phase == 'searching' || turn.phase == 'thinking') &&
        turn.answer.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User question bubble on the right
        Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: t.text.withValues(alpha: 0.09),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                turn.question,
                translate: false,
                style: TextStyle(color: t.text, fontSize: 14, height: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // Agent answer bubble on the left, with status label above the bubble
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (status != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 5),
                    child: Text(
                      status,
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                Container(
                  padding: showDots
                      ? const EdgeInsets.symmetric(horizontal: 16, vertical: 13)
                      : const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: t.surface,
                    border: Border.all(color: t.outline),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                  ),
                  child: showDots
                      ? _ThinkingDots(color: t.muted)
                      : turn.phase == 'error'
                          ? Text(
                              '回答失败：${turn.error ?? '未知错误'}',
                              translate: false,
                              style: const TextStyle(
                                color: Color(0xFFB3574D),
                                fontSize: 13,
                                height: 1.5,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  turn.answer,
                                  style: TextStyle(
                                    color: t.text,
                                    fontSize: 14,
                                    height: 1.65,
                                  ),
                                ),
                                if (turn.phase == 'done' &&
                                    turn.sources.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Divider(
                                    height: 1,
                                    color: t.muted.withValues(alpha: 0.14),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        '参考出处',
                                        style: TextStyle(
                                          color: t.muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                      for (final src in turn.sources)
                                        InkWell(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          onTap: () => widget.onOpenChapter(
                                            src.chapter,
                                            src.start.toInt(),
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: t.muted.withValues(
                                                alpha: 0.10,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              src.title.isEmpty
                                                  ? '第 ${src.chapter} 章'
                                                  : '第 ${src.chapter} 章 · ${src.title}',
                                              translate: false,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: t.text.withValues(
                                                  alpha: 0.85,
                                                ),
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _inputBar(ReadingTheme t) {
    final hint = !_hasChatModel || !_hasEmbedModel
        ? '请先安装对话模型与向量模型'
        : _indexedChapters == 0
            ? '请先在上方建立本书语义索引'
            : _turn == null
                ? '问问关于这本书的任何问题…'
                : '输入新问题（将替换当前问答）…';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: t.topBar,
        border: Border(top: BorderSide(color: t.outline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: _canAsk,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              style: TextStyle(color: t.text, fontSize: 14),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: t.muted.withValues(alpha: 0.75),
                  fontSize: 13.5,
                ),
                isDense: true,
                filled: true,
                fillColor: t.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: t.outline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: t.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: t.text.withValues(alpha: 0.35)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _canAsk ? _submit : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('提问'),
          ),
        ],
      ),
    );
  }
}

/// Three gently pulsing dots shown inside the left bubble while searching or
/// thinking in Qwen3's reasoning phase.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots({required this.color});

  final Color color;

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final phase = (_ctrl.value - i * 0.22) % 1.0;
        final wave = math.sin(phase * math.pi).clamp(0.0, 1.0);
        final alpha = 0.28 + 0.65 * wave;
        final dy = -2.5 * wave;
        return Padding(
          padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Container(
              width: 6.5,
              height: 6.5,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: alpha),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    ),
  );
}
