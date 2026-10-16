import BackgroundTasks
import Flutter
import UIKit
import os

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 锁屏后继续: a stretch of CPU iOS lends the app off screen when it sees
  /// fit. Dart runs the queue in it and says when it is done (main.dart).
  private static let analysisTask = "com.novel.novel.analysis"
  private var backgroundChannel: FlutterMethodChannel?
  private var lent: BGProcessingTask?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Must be registered before launch finishes, or iOS drops the task.
    BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.analysisTask, using: .main) {
      [weak self] task in
      self?.run(task as! BGProcessingTask)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func run(_ task: BGProcessingTask) {
    // Launched off screen with nobody to run the queue: try again later.
    guard let channel = backgroundChannel else {
      task.setTaskCompleted(success: false)
      AppDelegate.schedule()
      return
    }
    lent?.setTaskCompleted(success: false)
    lent = task
    task.expirationHandler = { [weak self] in
      self?.backgroundChannel?.invokeMethod("expire", arguments: nil)
      self?.finish(success: false, more: true)
    }
    channel.invokeMethod("run", arguments: nil)
  }

  private func finish(success: Bool, more: Bool) {
    lent?.setTaskCompleted(success: success)
    lent = nil
    if more { AppDelegate.schedule() }
  }

  private static func schedule() {
    let request = BGProcessingTaskRequest(identifier: analysisTask)
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false
    try? BGTaskScheduler.shared.submit(request)
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelBackground") {
      let channel = FlutterMethodChannel(
        name: "novel/background", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "schedule":
          AppDelegate.schedule()
        case "done":
          let more = (call.arguments as? [String: Any])?["more"] as? Bool ?? false
          self?.finish(success: true, more: more)
        default:
          break
        }
        result(nil)
      }
      backgroundChannel = channel
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
