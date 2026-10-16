import Flutter
import UIKit
import os

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelMemory") {
      FlutterMethodChannel(name: "novel/memory", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { _, result in result(AppDelegate.memory()) }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelDevice") {
      UIDevice.current.isBatteryMonitoringEnabled = true
      FlutterMethodChannel(name: "novel/device", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { _, result in result(AppDelegate.device()) }
    }
  }

  /// What the AI queue waits on: how hot the phone is, its power, its memory.
  private static func device() -> [String: Any] {
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unavailable"
    }
    var state: [String: Any] = [
      "thermal": thermal,
      "memoryMb": Int(ProcessInfo.processInfo.physicalMemory >> 20),
    ]
    let device = UIDevice.current
    if device.batteryLevel >= 0 {
      state["battery"] = Int((device.batteryLevel * 100).rounded())
      state["charging"] = device.batteryState == .charging || device.batteryState == .full
    }
    return state
  }

  /// What iOS counts against the app when it decides to end it, in bytes: now,
  /// the most since launch, and how much more it would allow.
  private static func memory() -> [String: Int] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return [:] }
    return [
      "now": Int(info.phys_footprint),
      "peak": Int(info.ledger_phys_footprint_peak),
      "left": Int(os_proc_available_memory()),
    ]
  }
}
