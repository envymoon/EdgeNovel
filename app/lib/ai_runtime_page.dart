import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'ai_runtime.dart';
import 'reader_state.dart';
import 'platform_services.dart';
import 'platform_support.dart';
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
  AppMemory? _memory;
  DeviceLoad? _load;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Often enough to watch the phone warm up under a model.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
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
      final memory = await AppMemory.read();
      final load = await DeviceLoad.read();
      if (mounted) {
        setState(() {
          _device = state;
          _memory = memory;
          _load = load;
        });
      }
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
        backgroundColor: t.topBar,
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
                // On iOS the queue runs whenever the app is open; one switch
                // is for the reader's page, the other for the locked phone,
                // where only the CPU windows the system grants are left.
                if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                  SwitchListTile(
                    value: runtime.lockedEnabled,
                    onChanged: runtime.setLockedEnabled,
                    title: Text(
                      '锁屏/后台运行',
                      style: TextStyle(color: t.text, fontSize: 14),
                    ),
                    subtitle: Text(
                      '会降速',
                      style: TextStyle(color: t.muted, fontSize: 12),
                    ),
                  ),
                  SwitchListTile(
                    value: runtime.backgroundEnabled,
                    onChanged: runtime.setBackgroundEnabled,
                    title: Text(
                      '允许阅读时后台处理',
                      style: TextStyle(color: t.text, fontSize: 14),
                    ),
                  ),
                ] else
                  SwitchListTile(
                    value: runtime.backgroundEnabled,
                    onChanged: runtime.setBackgroundEnabled,
                    title: Text(
                      '允许后台生成',
                      style: TextStyle(color: t.text, fontSize: 14),
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
            _section(t, '设备'),
            _deviceCard(t),
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
      color: t.surface,
      border: Border.all(color: t.outline),
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
        if (reader.aiActivity case final a?) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: a.fraction),
          const SizedBox(height: 6),
          Text(
            [
              a.label,
              if (a.total > 0) '${a.done} / ${a.total}',
              if (a.remaining != null) '剩余${formatRemaining(a.remaining!)}',
            ].join(' · '),
            style: TextStyle(color: t.muted, fontSize: 11.5),
          ),
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
        backgroundColor: t.raisedSurface,
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

  Widget _modeCard(ReadingTheme t, AiRunMode mode) {
    final selected = runtime.mode == mode;
    final (title, icon) = switch (mode) {
      AiRunMode.quiet => ('无感后台', Icons.nightlight_round),
      AiRunMode.balanced => ('智能平衡', Icons.auto_mode_outlined),
      AiRunMode.fast => ('立即完成', Icons.bolt),
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
              child: Text(
                title,
                style: TextStyle(
                  color: t.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
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
            d == null ? '稍候' : '$memory · $power\n$idle',
            style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.4),
          ),
          isThreeLine: d != null,
          trailing: IconButton(
            tooltip: context.tr('重新检测'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 19),
          ),
        ),
        if (_memory case final m?)
          ListTile(
            leading: Icon(Icons.memory_outlined, color: t.muted),
            title: Text(
              '应用内存',
              style: TextStyle(color: t.text, fontSize: 14),
            ),
            subtitle: Text(
              '当前 ${m.now} MB · 最高 ${m.peak} MB · 上限 ${m.limit} MB',
              style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.4),
            ),
          ),
        if (_loadLine(d) case final line?)
          ListTile(
            leading: Icon(Icons.thermostat_outlined, color: t.muted),
            title: Text('负载', style: TextStyle(color: t.text, fontSize: 14)),
            subtitle: Text(
              line,
              style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.4),
            ),
          ),
      ],
    );
  }

  /// CPU, GPU and heat on one line; what the phone does not tell is left out.
  /// iOS gives an app no temperature, only how warm it judges itself to be.
  String? _loadLine(AiDeviceState? d) {
    final l = _load;
    if (l == null) return null;
    final heat = switch (d?.thermalState) {
      'nominal' => '正常',
      'fair' => '偏热',
      'serious' => '很热',
      'critical' => '过热',
      _ => null,
    };
    final parts = [
      if (l.cpu != null) 'CPU ${l.cpu}%',
      if (l.gpu != null) 'GPU ${l.gpu}%',
      if (heat != null)
        l.batteryCelsius == null
            ? '温度 $heat'
            : '温度 $heat · 电池 ${l.batteryCelsius!.toStringAsFixed(1)} °C',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

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
        children: [
          ListTile(
            title: Text('处理器', style: TextStyle(color: t.text, fontSize: 13)),
            trailing: DropdownButton<AiBackend>(
              value: AppPlatformSupport.bundledEngineIsCpuOnly
                  ? AiBackend.cpu
                  : runtime.backend,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: AiBackend.auto, child: Text('自动')),
                DropdownMenuItem(value: AiBackend.cpu, child: Text('仅 CPU')),
                DropdownMenuItem(value: AiBackend.gpu, child: Text('优先 GPU')),
              ],
              onChanged: AppPlatformSupport.bundledEngineIsCpuOnly
                  ? null
                  : (value) {
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

  Widget _panel(ReadingTheme t, {required List<Widget> children}) => Material(
    clipBehavior: Clip.antiAlias,
    color: t.surface,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: t.outline),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(children: children),
  );
}
