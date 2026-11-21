import ARKit
import AVFoundation
import BackgroundTasks
import Flutter
import MediaPlayer
import UIKit
import Vision
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

  /// iOS woke the app for a download that finished while it was away: reopen
  /// the session so its events arrive, and say when they have.
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == Transfers.identifier else {
      super.application(
        application, handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
      return
    }
    Transfers.shared.eventsDone = completionHandler
    Transfers.shared.wake()
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
        .setMethodCallHandler { call, result in
          if call.method == "load" {
            AppDelegate.readLoad(result)
          } else {
            result(AppDelegate.device())
          }
        }
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelAudio") {
      FlutterMethodChannel(name: "novel/audio", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          let args = call.arguments as? [String: Any] ?? [:]
          guard call.method == "m4a", let from = args["from"] as? String,
            let to = args["to"] as? String
          else {
            result(FlutterMethodNotImplemented)
            return
          }
          DispatchQueue.global(qos: .utility).async {
            let failure = AppDelegate.m4a(from: from, to: to)
            DispatchQueue.main.async {
              result(failure.map { FlutterError(code: "m4a", message: $0, details: nil) })
            }
          }
        }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelKeep") {
      FlutterMethodChannel(name: "novel/keep", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in KeepAlive.shared.handle(call, result) }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelNowPlaying") {
      let channel = FlutterMethodChannel(
        name: "novel/now_playing", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in NowPlaying.shared.handle(call, result) }
      NowPlaying.shared.channel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelSpeech") {
      let channel = FlutterMethodChannel(
        name: "novel/speech", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in SystemSpeech.shared.handle(call, result) }
      SystemSpeech.shared.channel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelGesture") {
      let channel = FlutterMethodChannel(
        name: "novel/gesture", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in GestureWatch.shared.handle(call, result) }
      GestureWatch.shared.channel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelTransfer") {
      let channel = FlutterMethodChannel(
        name: "novel/transfer", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in Transfers.shared.handle(call, result) }
      Transfers.shared.channel = channel
      // Reconnect now, on this thread: tasks begun before the app last ended
      // report in, and the session exists before Dart first asks for it.
      Transfers.shared.wake()
    }
  }

  /// A spoken chapter's WAV as AAC in an .m4a (tts_chapters.dart): speech at
  /// 64 kbit/s, which is what a book app's audio is, a sixth of the WAV. The
  /// encoder may not take that rate at every sample rate, so lower ones are
  /// tried after it. Nil when written, why not otherwise.
  static func m4a(from: String, to: String) -> String? {
    var why = "无法编码"
    for rate in [64000, 48000, 32000] {
      do {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: from))
        let format = input.processingFormat
        try? FileManager.default.removeItem(atPath: to)
        // Closed, and so finished, when it goes out of scope.
        let output = try AVAudioFile(
          forWriting: URL(fileURLWithPath: to),
          settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: rate,
          ],
          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 15) else {
          return why
        }
        while input.framePosition < input.length {
          try input.read(into: buffer)
          if buffer.frameLength == 0 { break }
          try output.write(from: buffer)
        }
        return nil
      } catch {
        why = error.localizedDescription
        try? FileManager.default.removeItem(atPath: to)
      }
    }
    return why
  }

  /// What the phone is doing, for the 设备 card: how busy its CPU is across all
  /// cores since the last read, and, where iOS lets an app see them, the GPU's
  /// busy share and the battery's temperature. Taken off the main thread: the
  /// first read waits a moment for a second sample.
  private static var lastTicks: (busy: UInt64, total: UInt64)?

  static func readLoad(_ result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async {
      if lastTicks == nil {
        _ = cpuBusy()
        usleep(300_000)
      }
      var state: [String: Any] = [:]
      if let cpu = cpuBusy() { state["cpu"] = cpu }
      if let gpu = registryNumber(service: "IOAccelerator", key: "PerformanceStatistics",
        inner: "Device Utilization %")
      {
        state["gpu"] = gpu.intValue
      }
      if let temp = registryNumber(service: "IOPMPowerSource", key: "Temperature") {
        state["batteryTenths"] = temp.intValue / 10
      }
      DispatchQueue.main.async { result(state) }
    }
  }

  private static func cpuBusy() -> Int? {
    var cpus: natural_t = 0
    var info: processor_info_array_t?
    var count: mach_msg_type_number_t = 0
    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count)
        == KERN_SUCCESS, let info = info
    else { return nil }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
    }
    var busy: UInt64 = 0
    var total: UInt64 = 0
    for cpu in 0..<Int(cpus) {
      func ticks(_ state: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int(state)]))
      }
      let used = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
      busy += used
      total += used + ticks(CPU_STATE_IDLE)
    }
    defer { lastTicks = (busy, total) }
    guard let last = lastTicks, busy >= last.busy, total > last.total else { return nil }
    return Int((Double(busy - last.busy) / Double(total - last.total) * 100).rounded())
  }

  /// A number from the I/O registry, looked up at run time: iOS has no public
  /// interface for these, and refuses some apps; then this is nil.
  private static func registryNumber(service: String, key: String, inner: String? = nil)
    -> NSNumber?
  {
    typealias Matching = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFMutableDictionary>?
    typealias Service = @convention(c) (mach_port_t, CFMutableDictionary) -> mach_port_t
    typealias Property = @convention(c) (mach_port_t, CFString, CFAllocator?, UInt32) ->
      Unmanaged<CFTypeRef>?
    typealias Release = @convention(c) (mach_port_t) -> kern_return_t
    guard let kit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
      let m = dlsym(kit, "IOServiceMatching"), let s = dlsym(kit, "IOServiceGetMatchingService"),
      let p = dlsym(kit, "IORegistryEntryCreateCFProperty"), let r = dlsym(kit, "IOObjectRelease")
    else { return nil }
    let matching = unsafeBitCast(m, to: Matching.self)
    let getService = unsafeBitCast(s, to: Service.self)
    let property = unsafeBitCast(p, to: Property.self)
    let release = unsafeBitCast(r, to: Release.self)
    guard let dict = service.withCString({ matching($0) }) else { return nil }
    // The lookup takes the matching dictionary's reference.
    let entry = getService(0, dict.takeUnretainedValue())
    guard entry != 0 else { return nil }
    defer { _ = release(entry) }
    guard let value = property(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else { return nil }
    if let inner = inner {
      return (value as? NSDictionary)?[inner] as? NSNumber
    }
    return value as? NSNumber
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

/// Downloads handed to iOS: a background URLSession goes on fetching while the
/// app is suspended, and even after iOS has ended it. Dart asks for the rest of
/// a file from an offset; the bytes are added to the end of its .part file,
/// exactly where the app's own download would have written them.
final class Transfers: NSObject, URLSessionDownloadDelegate {
  static let shared = Transfers()
  static let identifier = "com.novel.novel.transfer"

  var channel: FlutterMethodChannel?
  var eventsDone: (() -> Void)?

  /// Start, pause and cancel, one at a time and in the order Dart sent them.
  private let control = DispatchQueue(label: "com.novel.novel.transfer.control")
  /// Touched only on the session's own queue.
  private var lastProgress: [Int: CFAbsoluteTime] = [:]
  private var failures: [Int: String] = [:]

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: Transfers.identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    config.allowsCellularAccess = true
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }()

  func wake() { _ = session }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// What a task is for, written on the task so it outlives the app:
  /// "<offset>|<path of the .part file>". The path is kept from the app's
  /// home on ("~/Library/…"): reinstalling a sideloaded app moves its home,
  /// and a task begun before must still find its file in the new one.
  private static func job(_ task: URLSessionTask) -> (part: String, offset: Int64)? {
    guard let d = task.taskDescription, let bar = d.firstIndex(of: "|"),
      let offset = Int64(d[..<bar])
    else { return nil }
    return (resolve(String(d[d.index(after: bar)...])), offset)
  }

  private static func describe(_ part: String, offset: Int64) -> String {
    let home = NSHomeDirectory()
    let kept = part.hasPrefix(home + "/") ? "~" + part.dropFirst(home.count) : part
    return "\(offset)|\(kept)"
  }

  private static func resolve(_ kept: String) -> String {
    if kept.hasPrefix("~/") { return NSHomeDirectory() + kept.dropFirst() }
    // Written whole by an older build: ".../Data/Application/<id>/Library/…".
    guard let apps = kept.range(of: "/Data/Application/"),
      let slash = kept[apps.upperBound...].firstIndex(of: "/")
    else { return kept }
    return NSHomeDirectory() + kept[slash...]
  }

  private static func resumeFile(_ part: String) -> String { part + ".resume" }

  /// Bytes a stopped task had fetched, kept with the offset it started at.
  private static func keep(_ data: Data, part: String, offset: Int64) {
    let saved: NSDictionary = ["offset": NSNumber(value: offset), "data": data]
    saved.write(toFile: resumeFile(part), atomically: true)
  }

  private func tasks(for part: String) -> [URLSessionTask] {
    let done = DispatchSemaphore(value: 0)
    var found: [URLSessionTask] = []
    session.getAllTasks { all in
      found = all.filter {
        Transfers.job($0)?.part == part && ($0.state == .running || $0.state == .suspended)
      }
      done.signal()
    }
    done.wait()
    return found
  }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let part = args["part"] as? String else {
      result(FlutterError(code: "args", message: "part", details: nil))
      return
    }
    control.async {
      let running = self.tasks(for: part)
      var reply: Any? = nil
      switch call.method {
      case "start":
        // Already under way (the app was away, or ended and opened again).
        if !running.isEmpty {
          reply = "attached"
          break
        }
        let offset = (args["offset"] as? NSNumber)?.int64Value ?? 0
        var task: URLSessionDownloadTask?
        if let saved = NSDictionary(contentsOfFile: Transfers.resumeFile(part)),
          let data = saved["data"] as? Data,
          (saved["offset"] as? NSNumber)?.int64Value == offset
        {
          task = self.session.downloadTask(withResumeData: data)
        }
        try? FileManager.default.removeItem(atPath: Transfers.resumeFile(part))
        if task == nil {
          guard let url = URL(string: args["url"] as? String ?? "") else {
            reply = FlutterError(code: "url", message: "下载地址无效", details: nil)
            break
          }
          var request = URLRequest(url: url)
          request.setValue("novel-reader", forHTTPHeaderField: "User-Agent")
          if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
          task = self.session.downloadTask(with: request)
        }
        task!.taskDescription = Transfers.describe(part, offset: offset)
        task!.resume()
        reply = "started"
      case "pause":
        for task in running {
          guard let download = task as? URLSessionDownloadTask,
            let job = Transfers.job(task)
          else {
            task.cancel()
            continue
          }
          download.cancel(byProducingResumeData: { data in
            if let data = data { Transfers.keep(data, part: job.part, offset: job.offset) }
          })
        }
      case "cancel":
        running.forEach { $0.cancel() }
        try? FileManager.default.removeItem(atPath: Transfers.resumeFile(part))
      default:
        reply = FlutterMethodNotImplemented
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private func send(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { self.channel?.invokeMethod(method, arguments: args) }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard let job = Transfers.job(downloadTask) else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now - (lastProgress[downloadTask.taskIdentifier] ?? 0) < 0.25 { return }
    lastProgress[downloadTask.taskIdentifier] = now
    // A 200 is the whole file, whatever was asked for.
    let ranged = (downloadTask.response as? HTTPURLResponse)?.statusCode == 206
    let base = ranged ? job.offset : 0
    var event: [String: Any] = ["part": job.part, "received": base + totalBytesWritten]
    if totalBytesExpectedToWrite > 0 { event["total"] = base + totalBytesExpectedToWrite }
    send("progress", event)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let job = Transfers.job(downloadTask) else { return }
    let response = downloadTask.response as? HTTPURLResponse
    let status = response?.statusCode ?? 0
    let fm = FileManager.default
    let size = ((try? fm.attributesOfItem(atPath: job.part))?[.size] as? NSNumber)?.int64Value ?? 0
    do {
      switch status {
      case 200, 206 where job.offset == 0:
        try? fm.removeItem(atPath: job.part)
        try fm.moveItem(at: location, to: URL(fileURLWithPath: job.part))
      case 206:
        guard size == job.offset else { throw Failure("续传位置不对，请重新下载") }
        try Transfers.append(location, to: job.part)
      case 416:
        // Asked for bytes past the end: the .part may be whole already.
        let range = response?.allHeaderFields["Content-Range"] as? String ?? ""
        let total = range.split(separator: "/").last.flatMap { Int64($0) }
        if total == nil || total != size { throw Failure("HTTP 416") }
      default:
        throw Failure("HTTP \(status)")
      }
    } catch {
      failures[downloadTask.taskIdentifier] = error.localizedDescription
    }
  }

  private static func append(_ file: URL, to part: String) throws {
    guard let input = InputStream(url: file),
      let output = OutputStream(toFileAtPath: part, append: true)
    else { throw Failure("写入下载文件失败") }
    input.open()
    output.open()
    defer {
      input.close()
      output.close()
    }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let n = input.read(&buffer, maxLength: buffer.count)
      if n < 0 { throw input.streamError ?? Failure("读取下载文件失败") }
      if n == 0 { return }
      var written = 0
      while written < n {
        let w = buffer.withUnsafeBufferPointer {
          output.write($0.baseAddress! + written, maxLength: n - written)
        }
        if w <= 0 { throw output.streamError ?? Failure("写入下载文件失败") }
        written += w
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let job = Transfers.job(task) else { return }
    lastProgress[task.taskIdentifier] = nil
    var event: [String: Any] = ["part": job.part]
    if let error = error as NSError? {
      if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
        Transfers.keep(data, part: job.part, offset: job.offset)
      }
      event["error"] = error.code == NSURLErrorCancelled ? "stopped" : error.localizedDescription
    } else if let failure = failures[task.taskIdentifier] {
      event["error"] = failure
    }
    failures[task.taskIdentifier] = nil
    send("done", event)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async {
      self.eventsDone?()
      self.eventsDone = nil
    }
  }
}

/// 听书 without the AI voice: the phone's own (tts_controller.dart). A
/// chapter from a sentence on is queued all at once, so it goes on with the
/// screen locked with nothing asked of Dart between sentences; Dart hears
/// which sentence has begun, and when the last has been said.
final class SystemSpeech: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = SystemSpeech()

  var channel: FlutterMethodChannel?
  private let synth = AVSpeechSynthesizer()
  /// What is queued, in order; the first is sentence [from].
  private var queued: [AVSpeechUtterance] = []
  private var from = 0

  override init() {
    super.init()
    synth.delegate = self
  }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "speak":
      let texts = args["texts"] as? [String] ?? []
      let gaps = args["gaps"] as? [Double] ?? []
      let rate = Float(args["rate"] as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
      clear()
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio)
      try? session.setActive(true)
      let voice = AVSpeechSynthesisVoice(language: "zh-CN")
      from = args["from"] as? Int ?? 0
      for (k, text) in texts.enumerated() {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        if k < gaps.count { u.postUtteranceDelay = gaps[k] }
        queued.append(u)
        synth.speak(u)
      }
    case "pause":
      synth.pauseSpeaking(at: .immediate)
    case "resume":
      if !synth.continueSpeaking() {
        result(false)
        return
      }
    case "stop":
      clear()
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(true)
  }

  /// What was queued is let go first, so nothing it says on its way out is
  /// taken for what follows.
  private func clear() {
    queued = []
    synth.stopSpeaking(at: .immediate)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    guard let k = queued.firstIndex(where: { $0 === utterance }) else { return }
    channel?.invokeMethod("sentence", arguments: from + k)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let last = queued.last, last === utterance else { return }
    queued = []
    channel?.invokeMethod("end", arguments: nil)
  }
}

/// Keeps the app running behind the screen (keep_alive.dart): a second of
/// silence played over and over by the system itself, which never stops
/// between rounds. A player looped from Dart stops at the end of each round
/// and is started again from there; behind a locked screen that start never
/// comes, and iOS suspends the app a few seconds later.
final class KeepAlive {
  static let shared = KeepAlive()

  /// Who wants it, and whether each lets other apps' sound go on.
  private var holders: [Int: Bool] = [:]
  private var player: AVAudioPlayer?
  /// Started again after a call or another app's sound took the session,
  /// or the app's own players let it go; checked while it runs.
  private var watch: Timer?

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard call.method == "set", let id = args["id"] as? Int else {
      result(FlutterMethodNotImplemented)
      return
    }
    if args["on"] as? Bool ?? false {
      holders[id] = args["mix"] as? Bool ?? false
    } else {
      holders[id] = nil
    }
    result(update())
  }

  private func update() -> Bool {
    let session = AVAudioSession.sharedInstance()
    if holders.isEmpty {
      watch?.invalidate()
      watch = nil
      player?.stop()
      player = nil
      return true
    }
    if watch == nil {
      watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        if let self = self, !self.holders.isEmpty, self.player?.isPlaying != true { _ = self.update() }
      }
    }
    // Listening owns the sound, so it shows on the lock screen.
    let mix = !NowPlaying.shared.isOn && !holders.values.contains(false)
    try? session.setCategory(.playback, mode: .default, options: mix ? [.mixWithOthers] : [])
    try? session.setActive(true)
    if player == nil {
      guard let p = try? AVAudioPlayer(data: KeepAlive.silence()) else { return false }
      p.numberOfLoops = -1
      player = p
    }
    if player?.isPlaying != true {
      player?.prepareToPlay()
      return player?.play() ?? false
    }
    return true
  }

  /// The sound setting again, for listening starting or ending.
  func refresh() {
    if !holders.isEmpty { _ = update() }
  }

  /// A second of 24 kHz 16-bit mono, all zeros, as a WAV file.
  private static func silence() -> Data {
    let rate: UInt32 = 24_000
    let bytes = rate * 2
    var d = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
    d.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1)
    le32(rate); le32(rate * 2); le16(2); le16(16)
    d.append(contentsOf: Array("data".utf8)); le32(bytes)
    d.append(Data(count: Int(bytes)))
    return d
  }
}

/// 听书 on the lock screen, in Control Center and on headphones
/// (tts_controller.dart): the chapter and the book, playing or paused, and
/// play, pause and the sentence before or after from there. Shown only while
/// something is being listened to; silence kept playing for work behind the
/// screen never shows. A call or another app's sound pauses it, and it plays
/// on after a call; headphones taken out pause it.
final class NowPlaying: NSObject {
  static let shared = NowPlaying()

  var channel: FlutterMethodChannel?
  private(set) var isOn = false
  private var playing = false

  override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(interrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(
      self, selector: #selector(routeChanged(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
  }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "set":
      show(
        title: args["title"] as? String ?? "", book: args["book"] as? String ?? "",
        playing: args["playing"] as? Bool ?? false)
    case "clear":
      hide()
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  private func show(title: String, book: String, playing: Bool) {
    self.playing = playing
    if !isOn {
      isOn = true
      let commands = MPRemoteCommandCenter.shared()
      let send = { (name: String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
        { [weak self] _ in
          self?.send(name)
          return .success
        }
      }
      commands.playCommand.addTarget(handler: send("play"))
      commands.pauseCommand.addTarget(handler: send("pause"))
      commands.togglePlayPauseCommand.addTarget(handler: send("toggle"))
      commands.nextTrackCommand.addTarget(handler: send("next"))
      commands.previousTrackCommand.addTarget(handler: send("previous"))
      for command in [
        commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
        commands.nextTrackCommand, commands.previousTrackCommand,
      ] {
        command.isEnabled = true
      }
      KeepAlive.shared.refresh()
    }
    if playing {
      try? AVAudioSession.sharedInstance().setActive(true)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: book,
      MPMediaItemPropertyAlbumTitle: book,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
  }

  private func hide() {
    guard isOn else { return }
    isOn = false
    playing = false
    let commands = MPRemoteCommandCenter.shared()
    for command in [
      commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
      commands.nextTrackCommand, commands.previousTrackCommand,
    ] {
      command.removeTarget(nil)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    KeepAlive.shared.refresh()
  }

  private func send(_ command: String) {
    DispatchQueue.main.async { self.channel?.invokeMethod("command", arguments: command) }
  }

  /// Paused when a call or another app takes the sound; on again after,
  /// when iOS says it should.
  private var pausedByInterruption = false

  @objc private func interrupted(_ note: Notification) {
    guard isOn, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      if playing {
        pausedByInterruption = true
        send("pause")
      }
    case .ended:
      let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
        AVAudioSession.InterruptionOptions(rawValue: $0)
      }
      if pausedByInterruption, options?.contains(.shouldResume) == true {
        send("play")
      }
      pausedByInterruption = false
    @unknown default:
      break
    }
  }

  @objc private func routeChanged(_ note: Notification) {
    guard isOn, playing, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
    else { return }
    send("pause")
  }
}

/// 隔空翻页: the front camera, small and slow, read by the system's own face
/// and hand recognition (Vision), so there is nothing to download. What it
/// sees is said to Dart by name; Dart decides which names turn the page.
///
/// Names: turnLeft / turnRight (head), nod, winkLeft / winkRight, blink (both
/// eyes held shut), swipeLeft / swipeRight (a hand across the camera). Left
/// and right are as on screen, the picture mirrored like a mirror.
final class GestureWatch: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  ARSessionDelegate
{
  static let shared = GestureWatch()
  var channel: FlutterMethodChannel?

  private let session = AVCaptureSession()
  /// Phones with Face ID see the face by infrared, so in the dark too; the
  /// hand is still looked for in the colour picture.
  private let depth = ARFaceTrackingConfiguration.isSupported
  private lazy var arSession: ARSession = {
    let s = ARSession()
    s.delegate = self
    s.delegateQueue = queue
    return s
  }()
  private var arRunning = false
  /// Where the head rests, relative to the phone.
  private var rest: simd_quatf?
  private let queue = DispatchQueue(label: "novel.gesture")
  private var configured = false
  /// Last asked for, on `queue`: a stop that overtakes a start still wins.
  private var wanted = false
  /// The gestures looked for, on `queue`. Nothing else is fired, and with no
  /// wave among them the hand is not looked for at all.
  private var enabled: Set<String> = []
  /// The reader's own lines, on `queue`: how far the head turns or drops
  /// (radians) and how long an eye stays shut (seconds) to count.
  private var turnLine = 0.35
  private var nodLine = 0.21
  private var eyeHold = 0.45
  /// What was measured last, said with the status so the lines can be set.
  private var lastTurn = 0.0
  private var lastNod = 0.0
  private var lastFrame = Date.distantPast
  private var lastFire = Date.distantPast
  private var lastStatus = Date.distantPast

  // Head: an event when it goes past the line, again only after it is back.
  private var headArmed = true
  private var pitchBase: Double?
  // Eyes: how open each is when open, and since when it has been shut.
  private var openLeft: Double = 0
  private var openRight: Double = 0
  private var shutLeft: Date?
  private var shutRight: Date?
  private var shutBoth: Date?
  private var eyesArmed = true
  // Hand: where it has been over the last moment.
  private var wrists: [(Date, CGFloat)] = []

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard #available(iOS 15.0, *) else {
        result(FlutterError(code: "ios", message: "需要 iOS 15 或以上", details: nil))
        return
      }
      let gestures = GestureWatch.gestures(call)
      let lines = GestureWatch.lines(call)
      queue.async {
        self.wanted = true
        self.enabled = gestures
        self.setLines(lines)
      }
      AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else {
          DispatchQueue.main.async {
            result(FlutterError(code: "camera", message: "没有相机权限", details: nil))
          }
          return
        }
        self.queue.async {
          let failure = self.begin()
          DispatchQueue.main.async {
            result(failure.map { FlutterError(code: "camera", message: $0, details: nil) })
          }
        }
      }
    case "watch":
      let gestures = GestureWatch.gestures(call)
      let lines = GestureWatch.lines(call)
      queue.async {
        self.enabled = gestures
        self.setLines(lines)
      }
      result(nil)
    case "stop":
      queue.async {
        self.wanted = false
        if self.session.isRunning { self.session.stopRunning() }
        if self.arRunning {
          self.arSession.pause()
          self.arRunning = false
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func gestures(_ call: FlutterMethodCall) -> Set<String> {
    Set((call.arguments as? [String: Any])?["gestures"] as? [String] ?? [])
  }

  /// Degrees for the head, milliseconds for the eyes.
  private static func lines(_ call: FlutterMethodCall) -> (Double?, Double?, Double?) {
    let a = call.arguments as? [String: Any]
    func n(_ k: String) -> Double? { (a?[k] as? NSNumber)?.doubleValue }
    return (n("turn"), n("nod"), n("hold"))
  }

  private func setLines(_ l: (Double?, Double?, Double?)) {
    if let t = l.0 { turnLine = t * .pi / 180 }
    if let n = l.1 { nodLine = n * .pi / 180 }
    if let h = l.2 { eyeHold = h / 1000 }
  }

  private func begin() -> String? {
    guard wanted else { return nil }
    if depth {
      resetState()
      if !arRunning {
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        // The slowest picture offered is plenty, and cheapest.
        if let slow = ARFaceTrackingConfiguration.supportedVideoFormats.min(by: {
          $0.framesPerSecond < $1.framesPerSecond
        }) {
          config.videoFormat = slow
        }
        arSession.run(config, options: [.resetTracking])
        arRunning = true
      }
      return nil
    }
    if !configured {
      guard
        let device = AVCaptureDevice.default(
          .builtInWideAngleCamera, for: .video, position: .front),
        let input = try? AVCaptureDeviceInput(device: device)
      else { return "没有前置相机" }
      session.beginConfiguration()
      session.sessionPreset = .vga640x480
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        return "相机打不开"
      }
      session.addInput(input)
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ]
      output.setSampleBufferDelegate(self, queue: queue)
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        return "相机打不开"
      }
      session.addOutput(output)
      session.commitConfiguration()
      // Fifteen frames a second is plenty for a head turn, and cheap.
      if (try? device.lockForConfiguration()) != nil {
        let fifteen = CMTime(value: 1, timescale: 15)
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
          $0.minFrameDuration <= fifteen && fifteen <= $0.maxFrameDuration
        }) {
          device.activeVideoMinFrameDuration = fifteen
          device.activeVideoMaxFrameDuration = fifteen
        }
        device.unlockForConfiguration()
      }
      configured = true
    }
    resetState()
    if !session.isRunning { session.startRunning() }
    return nil
  }

  private func resetState() {
    headArmed = true
    pitchBase = nil
    rest = nil
    openLeft = 0
    openRight = 0
    shutLeft = nil
    shutRight = nil
    shutBoth = nil
    eyesArmed = true
    wrists = []
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard #available(iOS 15.0, *), arRunning else { return }
    let now = Date()
    if now.timeIntervalSince(lastFrame) < 0.1 { return }
    lastFrame = now
    var seenFace = false
    if let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked {
      seenFace = true
      read(face: face, camera: frame.camera.transform, at: now)
    } else {
      rest = nil
    }
    var seenHand = false
    if enabled.contains("swipeLeft") || enabled.contains("swipeRight") {
      let handRequest = VNDetectHumanHandPoseRequest()
      handRequest.maximumHandCount = 1
      let handler = VNImageRequestHandler(
        cvPixelBuffer: frame.capturedImage, orientation: .leftMirrored)
      try? handler.perform([handRequest])
      // A frame missed in the blur of a wave does not end it; the moment
      // it is measured over does.
      if let hand = handRequest.results?.first {
        seenHand = true
        read(hand: hand, at: now)
      }
    }
    status(face: seenFace, hand: seenHand, at: now)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    arRunning = false
  }

  func sessionWasInterrupted(_ session: ARSession) {
    rest = nil
  }

  /// The infrared face: how far the head has turned from where it rests,
  /// and how shut each eye is.
  private func read(face: ARFaceAnchor, camera: simd_float4x4, at now: Date) {
    let toPhone = simd_mul(simd_inverse(camera), face.transform)
    let turn = simd_quatf(
      simd_float3x3(
        simd_make_float3(toPhone.columns.0),
        simd_make_float3(toPhone.columns.1),
        simd_make_float3(toPhone.columns.2)))
    let base = rest ?? turn
    // Where the face points, seen from how it rests: +x is the face's own
    // left, +y up, +z towards the phone.
    let ahead = simd_act(simd_mul(base.inverse, turn), SIMD3<Float>(0, 0, 1))
    let yaw = Double(atan2(ahead.x, ahead.z))
    let pitch = Double(atan2(ahead.y, ahead.z))
    lastTurn = abs(yaw)
    lastNod = max(0, -pitch)
    if headArmed {
      if yaw > turnLine {
        headArmed = false
        fire("turnLeft", at: now)
      } else if yaw < -turnLine {
        headArmed = false
        fire("turnRight", at: now)
      } else if pitch < -nodLine {
        headArmed = false
        fire("nod", at: now)
      }
    } else if abs(yaw) < turnLine * 0.4 && abs(pitch) < nodLine * 0.4 {
      headArmed = true
    }
    // The resting place follows, slowly, only a head that is quite still,
    // so a slow nod is not followed down.
    if rest == nil {
      rest = turn
    } else if headArmed && abs(yaw) < turnLine * 0.25 && abs(pitch) < nodLine * 0.25 {
      rest = simd_slerp(base, turn, 0.03)
    }

    // Eyes are read unless the head is turned well away. Waiting for it to
    // be back where it rests kept them unread with a nod line of a few
    // degrees, the head never quite that still.
    guard abs(yaw) < turnLine * 0.6 else { return }
    let left = face.blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0
    let right = face.blendShapes[.eyeBlinkRight]?.doubleValue ?? 0
    eyes(left: left, right: right, at: now)
  }

  private func status(face: Bool, hand: Bool, at now: Date) {
    if now.timeIntervalSince(lastStatus) > 0.2 {
      lastStatus = now
      let turn = face ? lastTurn * 180 / .pi : 0
      let nod = face ? lastNod * 180 / .pi : 0
      DispatchQueue.main.async {
        self.channel?.invokeMethod(
          "seen", arguments: ["face": face, "hand": hand, "turn": turn, "nod": nod])
      }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard #available(iOS 15.0, *) else { return }
    let now = Date()
    // At most ten a second are read.
    if now.timeIntervalSince(lastFrame) < 0.1 { return }
    lastFrame = now
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let faceRequest = VNDetectFaceLandmarksRequest()
    faceRequest.revision = VNDetectFaceLandmarksRequestRevision3
    let handRequest = VNDetectHumanHandPoseRequest()
    handRequest.maximumHandCount = 1
    let wantHand = enabled.contains("swipeLeft") || enabled.contains("swipeRight")
    // The front camera, phone upright, shown as in a mirror.
    let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .leftMirrored)
    try? handler.perform(wantHand ? [faceRequest, handRequest] : [faceRequest])
    var seenFace = false
    var seenHand = false
    if let face = faceRequest.results?.first {
      seenFace = true
      read(face: face, at: now)
    }
    if wantHand, let hand = handRequest.results?.first {
      seenHand = true
      read(hand: hand, at: now)
    } else if !wantHand {
      wrists.removeAll()
    }
    status(face: seenFace, hand: seenHand, at: now)
  }

  private func fire(_ name: String, at now: Date) {
    guard enabled.contains(name) else { return }
    // One gesture is one page: nothing more for a little while.
    if now.timeIntervalSince(lastFire) < 0.8 { return }
    lastFire = now
    DispatchQueue.main.async { self.channel?.invokeMethod("gesture", arguments: name) }
  }

  @available(iOS 15.0, *)
  private func read(face: VNFaceObservation, at now: Date) {
    let yaw = face.yaw?.doubleValue ?? 0
    let pitch = face.pitch?.doubleValue ?? 0
    let drop = pitchBase.map { abs(pitch - $0) } ?? 0
    lastTurn = abs(yaw)
    lastNod = drop
    if headArmed {
      if yaw > turnLine {
        headArmed = false
        fire("turnRight", at: now)
      } else if yaw < -turnLine {
        headArmed = false
        fire("turnLeft", at: now)
      } else if drop > nodLine {
        headArmed = false
        fire("nod", at: now)
      }
    } else if abs(yaw) < turnLine * 0.4 && drop < nodLine * 0.4 {
      headArmed = true
    }
    // Where the head rests, followed slowly while it is quite still.
    if headArmed && abs(yaw) < turnLine * 0.25 && drop < nodLine * 0.25 {
      pitchBase = pitchBase.map { $0 * 0.97 + pitch * 0.03 } ?? pitch
    }

    guard abs(yaw) < turnLine * 0.6,
      let leftEye = face.landmarks?.leftEye,
      let rightEye = face.landmarks?.rightEye
    else { return }
    let left = openness(leftEye)
    let right = openness(rightEye)
    // How open an eye is when open: the highest lately, let down slowly.
    openLeft = max(left, openLeft * 0.995)
    openRight = max(right, openRight * 0.995)
    guard openLeft > 0, openRight > 0 else { return }
    eyes(left: 1 - left / openLeft, right: 1 - right / openRight, at: now)
  }

  /// How shut each eye is, 0 open to 1 shut. Both shut a moment: meant, not
  /// a blink. One clearly more shut than the other: a wink, though the other
  /// narrows with it.
  private func eyes(left: Double, right: Double, at now: Date) {
    let both = left > 0.5 && right > 0.5 && abs(left - right) < 0.3
    let leftShut = !both && left > 0.5 && left - right > 0.25
    let rightShut = !both && right > 0.5 && right - left > 0.25
    shutBoth = both ? (shutBoth ?? now) : nil
    shutLeft = leftShut ? (shutLeft ?? now) : nil
    shutRight = rightShut ? (shutRight ?? now) : nil
    if !both && !leftShut && !rightShut {
      if left < 0.4 && right < 0.4 { eyesArmed = true }
      return
    }
    guard eyesArmed else { return }
    // A blink is over in a tenth of a second; held this long it is meant.
    if let b = shutBoth, now.timeIntervalSince(b) > eyeHold {
      eyesArmed = false
      fire("blink", at: now)
    } else if let l = shutLeft, now.timeIntervalSince(l) > eyeHold {
      eyesArmed = false
      fire("winkLeft", at: now)
    } else if let r = shutRight, now.timeIntervalSince(r) > eyeHold {
      eyesArmed = false
      fire("winkRight", at: now)
    }
  }

  /// Height over width of an eye's outline.
  private func openness(_ eye: VNFaceLandmarkRegion2D) -> Double {
    let points = eye.normalizedPoints
    guard let minX = points.map({ $0.x }).min(), let maxX = points.map({ $0.x }).max(),
      let minY = points.map({ $0.y }).min(), let maxY = points.map({ $0.y }).max(),
      maxX > minX
    else { return 0 }
    return Double((maxY - minY) / (maxX - minX))
  }

  @available(iOS 15.0, *)
  private func read(hand: VNHumanHandPoseObservation, at now: Date) {
    // The middle of what is seen of it: a hand waved close to the camera
    // often has its wrist out of the picture.
    guard let points = try? hand.recognizedPoints(.all) else { return }
    let seen = points.values.filter { $0.confidence > 0.3 }
    guard seen.count >= 3 else { return }
    let x = seen.map { $0.location.x }.reduce(0, +) / CGFloat(seen.count)
    wrists.append((now, x))
    wrists.removeAll { now.timeIntervalSince($0.0) > 1.0 }
    guard let first = wrists.first?.1, let last = wrists.last?.1 else { return }
    // Across a quarter of the picture inside the moment: a swipe.
    if last - first > 0.25 {
      wrists.removeAll()
      fire("swipeRight", at: now)
    } else if first - last > 0.25 {
      wrists.removeAll()
      fire("swipeLeft", at: now)
    }
  }
}
