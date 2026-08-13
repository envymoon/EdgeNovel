import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/rust/api/ai.dart';
import 'platform_services.dart';

enum AiRunMode { quiet, balanced, fast }

enum AiBackend { auto, cpu, gpu }

enum AiThermalBias { conservative, balanced, performance }

/// User intent for local inference. This is deliberately platform-neutral:
/// Windows supplies power/idle facts today; Android and iOS will supply the
/// same facts through their native schedulers later.
class AiRuntimeSettings extends ChangeNotifier {
  AiRuntimeSettings._();

  static final instance = AiRuntimeSettings._();

  static const _prefix = 'aiRuntime.';
  SharedPreferences? _prefs;
  DeviceStatusReader _deviceStatus = const NativeDeviceStatusReader();

  bool backgroundEnabled = true;
  bool chargingOnly = true;
  AiRunMode mode = AiRunMode.quiet;
  int batteryFloor = 40;
  int idleMinutes = 5;
  AiBackend backend = AiBackend.auto;
  int threadLimit = 0;
  AiThermalBias thermalBias = AiThermalBias.balanced;
  int unloadMinutes = 2;
  int engineRevision = 0;
  int? detectedMemoryMb;

  Future<void> initialize({DeviceStatusReader? deviceStatus}) async {
    if (deviceStatus != null) _deviceStatus = deviceStatus;
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    backgroundEnabled =
        p.getBool('${_prefix}backgroundEnabled') ?? backgroundEnabled;
    chargingOnly = p.getBool('${_prefix}chargingOnly') ?? chargingOnly;
    mode =
        AiRunMode.values[(p.getInt('${_prefix}mode') ?? mode.index).clamp(
          0,
          AiRunMode.values.length - 1,
        )];
    batteryFloor = (p.getInt('${_prefix}batteryFloor') ?? batteryFloor).clamp(
      10,
      90,
    );
    idleMinutes = (p.getInt('${_prefix}idleMinutes') ?? idleMinutes).clamp(
      1,
      30,
    );
    backend =
        AiBackend.values[(p.getInt('${_prefix}backend') ?? backend.index).clamp(
          0,
          AiBackend.values.length - 1,
        )];
    threadLimit = (p.getInt('${_prefix}threadLimit') ?? threadLimit).clamp(
      0,
      64,
    );
    thermalBias =
        AiThermalBias.values[(p.getInt('${_prefix}thermalBias') ??
                thermalBias.index)
            .clamp(0, AiThermalBias.values.length - 1)];
    unloadMinutes = (p.getInt('${_prefix}unloadMinutes') ?? unloadMinutes)
        .clamp(1, 30);
    try {
      detectedMemoryMb = (await _deviceStatus.read()).totalMemoryMb?.toInt();
    } catch (_) {}
    await _applyEngineConfig();
  }

  String get modeName => switch (mode) {
    AiRunMode.quiet => '无感后台',
    AiRunMode.balanced => '智能平衡',
    AiRunMode.fast => '立即完成',
  };

  String get modeDescription => switch (mode) {
    AiRunMode.quiet => '设备空闲时分段处理，阅读时主动暂停',
    AiRunMode.balanced => '根据设备状态调整速度，兼顾等待时间',
    AiRunMode.fast => '使用较高性能连续完成，仍保留温度保护',
  };

  String? waitingReason(
    AiDeviceState state, {
    required bool reading,
    bool forceNow = false,
  }) {
    if (forceNow) return null;
    if (!backgroundEnabled) return '后台生成已关闭';
    if (chargingOnly && state.charging == false) return '等待接通电源';
    final battery = state.batteryPercent;
    if (state.charging != true && battery != null && battery < batteryFloor) {
      return '电量低于 $batteryFloor%';
    }
    if (state.thermalState == 'serious' || state.thermalState == 'critical') {
      return '设备温度较高，等待冷却';
    }
    if (mode != AiRunMode.fast && reading) return '正在阅读，AI 已让路';
    if (mode == AiRunMode.quiet) {
      final idle = state.idleSeconds;
      if (idle != null && idle < idleMinutes * 60) {
        return '等待设备空闲 $idleMinutes 分钟';
      }
    }
    return null;
  }

  Future<AiDeviceState> readDeviceState() async {
    final state = await _deviceStatus.read();
    final memory = state.totalMemoryMb?.toInt();
    if (memory != detectedMemoryMb) {
      detectedMemoryMb = memory;
      engineRevision++;
      notifyListeners();
      await _applyEngineConfig();
    }
    return state;
  }

  bool get isVeryLowMemory =>
      detectedMemoryMb != null && detectedMemoryMb! < 5120;

  bool get isLowMemory => detectedMemoryMb != null && detectedMemoryMb! < 7168;

  String get deviceAiTier {
    final memory = detectedMemoryMb;
    if (memory == null) return '等待检测';
    if (memory < 4096) return '仅建议阅读与语义搜索';
    if (memory < 5120) return '固定 8K 生成不建议';
    if (memory < 7168) return '固定 8K · 前台试运行';
    if (memory < 10240) return '标准 AI';
    return '高性能 AI';
  }

  Duration get engineIdleDuration {
    if (isVeryLowMemory) return const Duration(seconds: 10);
    if (isLowMemory) return const Duration(seconds: 30);
    return Duration(minutes: unloadMinutes);
  }

  Future<void> setBackgroundEnabled(bool value) async {
    backgroundEnabled = value;
    await _changed();
  }

  Future<void> setChargingOnly(bool value) async {
    chargingOnly = value;
    await _changed();
  }

  Future<void> setMode(AiRunMode value) async {
    mode = value;
    engineRevision++;
    await _changed();
  }

  Future<void> setBatteryFloor(int value) async {
    batteryFloor = value.clamp(10, 90);
    await _changed();
  }

  Future<void> setIdleMinutes(int value) async {
    idleMinutes = value.clamp(1, 30);
    await _changed();
  }

  Future<void> setBackend(AiBackend value) async {
    backend = value;
    engineRevision++;
    await _changed();
  }

  Future<void> setThreadLimit(int value) async {
    threadLimit = value.clamp(0, 64);
    engineRevision++;
    await _changed();
  }

  Future<void> setThermalBias(AiThermalBias value) async {
    thermalBias = value;
    await _changed();
  }

  Future<void> setUnloadMinutes(int value) async {
    unloadMinutes = value.clamp(1, 30);
    await _changed();
  }

  Future<void> _changed() async {
    notifyListeners();
    final p = _prefs;
    if (p != null) {
      await Future.wait([
        p.setBool('${_prefix}backgroundEnabled', backgroundEnabled),
        p.setBool('${_prefix}chargingOnly', chargingOnly),
        p.setInt('${_prefix}mode', mode.index),
        p.setInt('${_prefix}batteryFloor', batteryFloor),
        p.setInt('${_prefix}idleMinutes', idleMinutes),
        p.setInt('${_prefix}backend', backend.index),
        p.setInt('${_prefix}threadLimit', threadLimit),
        p.setInt('${_prefix}thermalBias', thermalBias.index),
        p.setInt('${_prefix}unloadMinutes', unloadMinutes),
      ]);
    }
    await _applyEngineConfig();
  }

  Future<void> _applyEngineConfig() => setAiRuntimeConfig(
    mode: mode.index,
    backend: backend.index,
    threadLimit: threadLimit,
    thermalBias: thermalBias.index,
    totalMemoryMb: BigInt.from(detectedMemoryMb ?? 0),
  );
}
