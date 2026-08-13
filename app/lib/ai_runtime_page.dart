import 'dart:async';

import 'package:flutter/material.dart';

import 'ai_runtime.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'theme.dart';

class AiRuntimePage extends StatefulWidget {
  const AiRuntimePage({super.key, required this.settings, this.reader});

  final ReadingSettings settings;
  final ReaderState? reader;

  @override
  State<AiRuntimePage> createState() => _AiRuntimePageState();
}

class _AiRuntimePageState extends State<AiRuntimePage> {
  final runtime = AiRuntimeSettings.instance;
  AiDeviceState? _device;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final state = await runtime.readDeviceState();
      if (mounted) setState(() => _device = state);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final listenable = widget.reader == null
        ? runtime
        : Listenable.merge([runtime, widget.reader!]);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('AI 运行与设备', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            if (widget.reader != null) ...[
              _queueCard(t, widget.reader!),
              const SizedBox(height: 20),
            ],
            _section(t, '后台生成'),
            _panel(
              t,
              children: [
                SwitchListTile(
                  value: runtime.backgroundEnabled,
                  onChanged: runtime.setBackgroundEnabled,
                  title: Text(
                    '允许后台生成',
                    style: TextStyle(color: t.text, fontSize: 14),
                  ),
                  subtitle: Text(
                    '关闭后只手动运行',
                    style: TextStyle(color: t.muted, fontSize: 11.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _section(t, '运行方式'),
            for (final mode in AiRunMode.values) ...[
              _modeCard(t, mode),
              if (mode != AiRunMode.values.last) const SizedBox(height: 8),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                '不影响模型与 8K 上下文。',
                style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.45),
              ),
            ),
            const SizedBox(height: 20),
            _section(t, '电量与空闲条件'),
            _panel(
              t,
              children: [
                SwitchListTile(
                  value: runtime.chargingOnly,
                  onChanged: runtime.setChargingOnly,
                  title: Text(
                    '仅充电时运行',
                    style: TextStyle(color: t.text, fontSize: 14),
                  ),
                  subtitle: Text(
                    '减少电池消耗',
                    style: TextStyle(color: t.muted, fontSize: 11.5),
                  ),
                ),
                if (!runtime.chargingOnly)
                  _sliderTile(
                    t,
                    title: '最低电量',
                    value: runtime.batteryFloor.toDouble(),
                    min: 10,
                    max: 90,
                    divisions: 8,
                    label: '${runtime.batteryFloor}%',
                    onChanged: (v) => runtime.setBatteryFloor(v.round()),
                  ),
                if (runtime.mode == AiRunMode.quiet)
                  _sliderTile(
                    t,
                    title: '空闲多久后开始',
                    value: runtime.idleMinutes.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: '${runtime.idleMinutes} 分钟',
                    onChanged: (v) => runtime.setIdleMinutes(v.round()),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _section(t, '设备与模型'),
            _deviceCard(t),
            const SizedBox(height: 8),
            _supportRangeCard(t),
            const SizedBox(height: 8),
            _panel(
              t,
              children: [
                ListTile(
                  leading: Icon(Icons.memory_outlined, color: t.muted),
                  title: Text(
                    '标准模型 · Qwen3 0.6B Q8',
                    style: TextStyle(color: t.text, fontSize: 14),
                  ),
                  subtitle: Text(
                    '固定 Q8，不自动降为 Q4',
                    style: TextStyle(color: t.muted, fontSize: 11.5),
                  ),
                  trailing: const Icon(
                    Icons.check_circle,
                    color: Color(0xFF4E7956),
                    size: 20,
                  ),
                ),
                ListTile(
                  enabled: false,
                  leading: const Icon(Icons.upgrade_outlined),
                  title: const Text('增强模型', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '待兼容性验证',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  trailing: const Text('待验证', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _section(t, '高级设置'),
            _advanced(t),
          ],
        ),
      ),
    );
  }

  Widget _queueCard(ReadingTheme t, ReaderState reader) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: t.text.withValues(alpha: 0.035),
      border: Border.all(color: t.muted.withValues(alpha: 0.18)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              reader.aiBusy ? Icons.sync : Icons.schedule_outlined,
              color: t.muted,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                reader.aiQueueState,
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${reader.aiQueuedCount} 项',
              style: TextStyle(color: t.muted, fontSize: 11.5),
            ),
          ],
        ),
        if (reader.aiQueueDetail != null) ...[
          const SizedBox(height: 6),
          Text(
            reader.aiQueueDetail!,
            style: TextStyle(color: t.muted, fontSize: 12),
          ),
        ],
        if (reader.enrichProgress != null || reader.indexProgress != null) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _progress(reader)),
        ],
        if (reader.aiQueuedCount > 0) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: reader.runNextAiNow,
                icon: const Icon(Icons.bolt, size: 17),
                label: const Text('本次立即运行'),
              ),
              if (reader.aiBusy)
                TextButton.icon(
                  onPressed: reader.pauseAllAi,
                  icon: const Icon(Icons.pause, size: 17),
                  label: const Text('暂停'),
                ),
              if (reader.aiHasPaused)
                TextButton.icon(
                  onPressed: () => _confirmCancelPaused(reader),
                  icon: const Icon(Icons.close, size: 17),
                  label: const Text('取消任务'),
                ),
              if (reader.aiHasFailed)
                TextButton.icon(
                  onPressed: reader.retryFailedAi,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('重试失败任务'),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Future<void> _confirmCancelPaused(ReaderState reader) async {
    final t = widget.settings.theme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text('取消暂停的任务？', style: TextStyle(color: t.text)),
        content: Text(
          '任务会从后台队列中移除，已经生成的章节内容会保留，以后可以重新开始。',
          style: TextStyle(color: t.muted, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('返回', style: TextStyle(color: t.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
    if (confirmed == true) await reader.cancelPausedAi();
  }

  double? _progress(ReaderState reader) {
    final done = reader.enrichProgress?.done ?? reader.indexProgress?.done;
    final total = reader.enrichProgress?.total ?? reader.indexProgress?.total;
    if (done == null || total == null || total == 0) return null;
    return done / total;
  }

  Widget _modeCard(ReadingTheme t, AiRunMode mode) {
    final selected = runtime.mode == mode;
    final (title, subtitle, icon) = switch (mode) {
      AiRunMode.quiet => (
        '无感后台',
        '空闲时分段处理，阅读时暂停，优先保持低温',
        Icons.nightlight_round,
      ),
      AiRunMode.balanced => (
        '智能平衡',
        '自动调整处理速度，兼顾等待时间与设备负担',
        Icons.auto_mode_outlined,
      ),
      AiRunMode.fast => ('立即完成', '连续处理，使用较高性能；温度过高仍会暂停', Icons.bolt),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => runtime.setMode(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? t.text.withValues(alpha: 0.07) : null,
          border: Border.all(
            color: selected
                ? t.text.withValues(alpha: 0.42)
                : t.muted.withValues(alpha: 0.16),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? t.text : t.muted, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: t.muted,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? t.text : t.muted,
              size: 19,
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(ReadingTheme t) {
    final d = _device;
    final power = d?.charging == null
        ? '电源状态不可用'
        : d!.charging!
        ? '已接通电源'
        : '正在使用电池${d.batteryPercent == null ? '' : ' · ${d.batteryPercent}%'}';
    final idle = d?.idleSeconds == null
        ? '空闲状态不可用'
        : '已空闲 ${_duration(d!.idleSeconds!)}';
    final memory = d?.totalMemoryMb == null
        ? '内存容量不可用'
        : '${(d!.totalMemoryMb!.toInt() / 1024).toStringAsFixed(1)} GB 内存';
    return _panel(
      t,
      children: [
        ListTile(
          leading: Icon(Icons.computer_outlined, color: t.muted),
          title: Text(
            d == null
                ? '正在检测设备'
                : '${runtime.deviceAiTier} · ${d.logicalCores} 线程',
            style: TextStyle(color: t.text, fontSize: 14),
          ),
          subtitle: Text(
            d == null
                ? '稍候'
                : '$memory · $power\n$idle\nWindows 暂无统一温度读数，移动端将使用系统温控',
            style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.4),
          ),
          isThreeLine: d != null,
          trailing: IconButton(
            tooltip: '重新检测',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 19),
          ),
        ),
      ],
    );
  }

  Widget _supportRangeCard(ReadingTheme t) => _panel(
    t,
    children: [
      ExpansionTile(
        iconColor: t.muted,
        collapsedIconColor: t.muted,
        leading: Icon(Icons.phone_android_outlined, color: t.muted),
        title: Text('移动端支持标准', style: TextStyle(color: t.text, fontSize: 14)),
        subtitle: Text(
          '完整 AI 以 8GB Android / iPhone 13 级别为主力目标',
          style: TextStyle(color: t.muted, fontSize: 11.5),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          Text(
            '4GB 及以下：阅读功能与语义搜索，不作为生成 AI 支持范围。\n'
            '6GB：可尝试固定 8K 的标准 Q8，建议前台单任务运行，后台可能被系统中止。\n'
            '8GB：完整 AI 功能的标准支持范围。\n'
            '12GB 以上：快速模式与未来增强模型。\n'
            'iPhone：iPhone 11 为最低测试线，iPhone 13 及以上为推荐范围。',
            style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.6),
          ),
        ],
      ),
    ],
  );

  String _duration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '$minutes 分钟';
    return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
  }

  Widget _advanced(ReadingTheme t) => _panel(
    t,
    children: [
      ExpansionTile(
        iconColor: t.muted,
        collapsedIconColor: t.muted,
        title: Text(
          '处理器、线程与模型驻留',
          style: TextStyle(color: t.text, fontSize: 14),
        ),
        subtitle: Text(
          '通常保持自动即可',
          style: TextStyle(color: t.muted, fontSize: 11.5),
        ),
        children: [
          ListTile(
            title: Text('处理器', style: TextStyle(color: t.text, fontSize: 13)),
            trailing: DropdownButton<AiBackend>(
              value: runtime.backend,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: AiBackend.auto, child: Text('自动')),
                DropdownMenuItem(value: AiBackend.cpu, child: Text('仅 CPU')),
                DropdownMenuItem(value: AiBackend.gpu, child: Text('优先 GPU')),
              ],
              onChanged: (value) {
                if (value != null) runtime.setBackend(value);
              },
            ),
          ),
          _sliderTile(
            t,
            title: '线程上限',
            value: runtime.threadLimit.toDouble(),
            min: 0,
            max: 16,
            divisions: 16,
            label: runtime.threadLimit == 0 ? '自动' : '${runtime.threadLimit}',
            onChanged: (v) => runtime.setThreadLimit(v.round()),
          ),
          ListTile(
            title: Text('温控倾向', style: TextStyle(color: t.text, fontSize: 13)),
            trailing: DropdownButton<AiThermalBias>(
              value: runtime.thermalBias,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(
                  value: AiThermalBias.conservative,
                  child: Text('保守'),
                ),
                DropdownMenuItem(
                  value: AiThermalBias.balanced,
                  child: Text('平衡'),
                ),
                DropdownMenuItem(
                  value: AiThermalBias.performance,
                  child: Text('积极'),
                ),
              ],
              onChanged: (value) {
                if (value != null) runtime.setThermalBias(value);
              },
            ),
          ),
          _sliderTile(
            t,
            title: '空闲后释放模型',
            value: runtime.unloadMinutes.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '${runtime.unloadMinutes} 分钟',
            onChanged: (v) => runtime.setUnloadMinutes(v.round()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
            child: Text(
              '更改处理器或线程后，会在下一次模型启动时生效。降低线程主要减少瞬时负担，不保证降低总耗电。',
              style: TextStyle(color: t.muted, fontSize: 11, height: 1.45),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _sliderTile(
    ReadingTheme t, {
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 12, 5),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: TextStyle(color: t.text, fontSize: 13)),
            ),
            Text(label, style: TextStyle(color: t.muted, fontSize: 11.5)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _section(ReadingTheme t, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      title,
      style: TextStyle(
        color: t.muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _panel(ReadingTheme t, {required List<Widget> children}) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      border: Border.all(color: t.muted.withValues(alpha: 0.16)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(children: children),
  );
}
