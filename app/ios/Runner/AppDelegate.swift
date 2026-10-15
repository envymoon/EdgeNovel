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
