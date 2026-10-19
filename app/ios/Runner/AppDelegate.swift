import AVFoundation
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelSpeech") {
      let channel = FlutterMethodChannel(
        name: "novel/speech", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in SystemSpeech.shared.handle(call, result) }
      SystemSpeech.shared.channel = channel
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
  /// "<offset>|<path of the .part file>".
  private static func job(_ task: URLSessionTask) -> (part: String, offset: Int64)? {
    guard let d = task.taskDescription, let bar = d.firstIndex(of: "|"),
      let offset = Int64(d[..<bar])
    else { return nil }
    return (String(d[d.index(after: bar)...]), offset)
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
        task!.taskDescription = "\(offset)|\(part)"
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
