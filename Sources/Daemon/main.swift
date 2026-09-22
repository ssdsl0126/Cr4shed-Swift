import Foundation
import UserNotifications

enum ReportCrashPrewarmer {
    private static let queue = DispatchQueue(label: "com.muirey03.cr4shedd.reportcrash", qos: .utility)
    private static var readyPIDs = Set<pid_t>()
    private static var processExitSource: DispatchSourceProcess?
    private static var watchedPID: pid_t = 0
    private static var watchGeneration: UInt64 = 0
    private static let restartDelay: TimeInterval = 2
    private static let launchRetryDelays: [TimeInterval] = [5, 10, 20, 30, 60]
    private static let verificationDelays: [TimeInterval] = [1, 2, 4]

    static func recordReady(pid: pid_t, targetClass: String, hookCount: Int64) -> Bool {
        guard hookCount > 0, CR4IsReportCrashPID(pid) else {
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] Rejected invalid Cr4shedMach ready message for PID %d", pid)
            #endif
            return false
        }
        queue.async {
            readyPIDs.insert(pid)
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] Cr4shedMach ready in ReportCrash[%d], class=%@, hooks=%lld", pid, targetClass, hookCount)
            #endif
        }
        return true
    }

    static func start() {
        // 给 launchd 注入链留出初始化时间，避免越狱激活早期争抢系统服务。
        queue.asyncAfter(deadline: .now() + 8) {
            startAndReport(attempt: 1)
        }
    }

    private static func startAndReport(attempt: Int) {
        guard !CR4IsSafeModeActive() else {
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash start skipped: safe mode is active")
            #endif
            return
        }

        let currentPID = CR4FindReportCrashPID()
        if currentPID > 0 {
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash is already running, PID=%d", currentPID)
            #endif
            monitorExit(of: currentPID)
            verifyInjection(of: currentPID, afterDelayAt: 0)
            return
        }

        // 安全模式可能在启动延迟期间刚刚建立；执行外部操作前再次确认。
        guard !CR4IsSafeModeActive() else {
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash start cancelled: safe mode became active")
            #endif
            return
        }

        var launchStatus: Int32 = 0
        let pid = CR4StartReportCrash(&launchStatus)
        guard pid > 0 else {
            let delayIndex = min(max(attempt - 1, 0), launchRetryDelays.count - 1)
            let retryDelay = launchRetryDelays[delayIndex]
            let nextAttempt = min(attempt + 1, launchRetryDelays.count)
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash start attempt %d failed, launchctl status=%d; retrying in %.0f seconds", attempt, launchStatus, retryDelay)
            #endif
            queue.asyncAfter(deadline: .now() + retryDelay) {
                startAndReport(attempt: nextAttempt)
            }
            return
        }
        #if CR4_DEBUG_LOGGING
        NSLog("[cr4shedd] ReportCrash started successfully on attempt %d, PID=%d, launchctl status=%d", attempt, pid, launchStatus)
        #endif
        monitorExit(of: pid)
        verifyInjection(of: pid, afterDelayAt: 0)
    }

    private static func monitorExit(of pid: pid_t) {
        guard pid > 0 else { return }
        if watchedPID == pid, processExitSource != nil { return }

        watchGeneration &+= 1
        let generation = watchGeneration
        processExitSource?.cancel()

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler {
            guard generation == watchGeneration, watchedPID == pid else { return }

            processExitSource = nil
            watchedPID = 0
            readyPIDs.remove(pid)

            guard !CR4IsSafeModeActive() else {
                #if CR4_DEBUG_LOGGING
                NSLog("[cr4shedd] ReportCrash[%d] exited; restart skipped because safe mode is active", pid)
                #endif
                return
            }

            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash[%d] exited; restarting in %.0f seconds", pid, restartDelay)
            #endif
            queue.asyncAfter(deadline: .now() + restartDelay) {
                guard !CR4IsSafeModeActive() else {
                    #if CR4_DEBUG_LOGGING
                    NSLog("[cr4shedd] ReportCrash restart cancelled: safe mode became active")
                    #endif
                    return
                }
                startAndReport(attempt: 1)
            }
        }

        watchedPID = pid
        processExitSource = source
        source.activate()
        #if CR4_DEBUG_LOGGING
        NSLog("[cr4shedd] Monitoring ReportCrash[%d] exit events", pid)
        #endif
    }

    private static func verifyInjection(of expectedPID: pid_t, afterDelayAt index: Int) {
        guard index < verificationDelays.count else {
            let currentPID = CR4FindReportCrashPID()
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] ReportCrash injection handshake not received; expected PID=%d, current PID=%d", expectedPID, currentPID)
            #endif
            return
        }
        queue.asyncAfter(deadline: .now() + verificationDelays[index]) {
            guard !CR4IsSafeModeActive() else {
                #if CR4_DEBUG_LOGGING
                NSLog("[cr4shedd] ReportCrash verification stopped: safe mode is active")
                #endif
                return
            }
            let currentPID = CR4FindReportCrashPID()
            guard currentPID == expectedPID else {
                #if CR4_DEBUG_LOGGING
                NSLog("[cr4shedd] ReportCrash changed before injection verification; expected PID=%d, current PID=%d", expectedPID, currentPID)
                #endif
                startAndReport(attempt: 1)
                return
            }
            if readyPIDs.contains(expectedPID) {
                #if CR4_DEBUG_LOGGING
                NSLog("[cr4shedd] ReportCrash[%d] start and injection verified", expectedPID)
                #endif
                return
            }
            verifyInjection(of: expectedPID, afterDelayAt: index + 1)
        }
    }
}

enum LogWriter {
    static func write(string: String, filename: String, eventID: String?) -> String? {
        // 与本地回退共用事件标识和原子发布逻辑；兼容未携带标识的旧客户端。
        CR4LocalWriteLogForEvent(string, filename, eventID ?? UUID().uuidString)
    }
}

enum Notifier {
    private static let queue = DispatchQueue(label: "com.muirey03.cr4shedd.notifications", autoreleaseFrequency: .workItem)
    // 守护进程内复用通知中心，避免每条通知重新分配并初始化客户端。
    private static let center = (CR4CreateNotificationCenter(CR4SHED_GUI_BUNDLE) as? UNUserNotificationCenter)
        ?? UNUserNotificationCenter.current()
    private static var lastNotified: [String: Date] = [:]

    static func post(content: String, logPath: String?) {
        // XPC 和目录监听共用串行去重入口，通知服务不会阻塞保存请求的回复。
        queue.async {
            let path = logPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
            let key = path ?? UUID().uuidString
            let now = Date()
            lastNotified = lastNotified.filter { now.timeIntervalSince($0.value) < 300 }
            guard lastNotified[key] == nil else { return }
            lastNotified[key] = now
            deliver(content: path.map { contentForLog(at: $0, fallback: content) } ?? content,
                    logPath: logPath, key: key, attempt: now)
        }
    }

    private static func contentForLog(at path: String, fallback: String) -> String {
        // 只读取 Cr4 报告头部，监听回退与 XPC 使用相同的事件分类。
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return fallback }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 64 * 1024) else { return fallback }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        func field(_ name: String) -> String? {
            lines.first(where: { $0.hasPrefix(name) }).map { String($0.dropFirst(name.count)) }
        }
        guard let exception = field("Exception type: ") else { return fallback }
        let process = field("Process: ") ?? (path as NSString).lastPathComponent.components(separatedBy: "@")[0]
        let date = field("Date: ") ?? (CR4StringFromDate(Date(), .pretty) ?? "")
        if exception.hasPrefix("EXC_RESOURCE") {
            let isMemory = field("Exception subtype: ")?.contains("RESOURCE_TYPE_MEMORY") == true
            return "\(process) reported a \(isMemory ? "memory resource" : "resource") event at \(date)"
        }
        return "\(process) crashed at \(date)"
    }

    private static func deliver(content: String, logPath: String?, key: String, attempt: Date) {
        let note = UNMutableNotificationContent()
        note.title = "Cr4shed"
        note.body = content
        if let logPath {
            note.userInfo = ["logPath": logPath]
        }
        note.sound = .default
        let request = UNNotificationRequest(identifier: "cr4shed:\(key)", content: note, trigger: nil)
        center.add(request) { error in
            if let error = error {
                #if CR4_DEBUG_LOGGING
                NSLog("[cr4shedd] UNUserNotificationCenter error: %@", error.localizedDescription)
                #endif
                queue.async {
                    if lastNotified[key] == attempt { lastNotified.removeValue(forKey: key) }
                }
            }
        }
    }
}

private func handle(_ messageID: Int64, userInfo: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    switch messageID {
    case 1:
        let notifyOnly = (userInfo["notifyOnly"] as? NSNumber)?.boolValue ?? false
        if notifyOnly {
            let content = userInfo["content"] as? String ?? "Process crashed"
            let logPath = userInfo["logPath"] as? String
            Notifier.post(content: content, logPath: logPath)
            break
        }
        let string = userInfo["string"] as? String ?? ""
        let filename = userInfo["filename"] as? String ?? ""
        if let path = LogWriter.write(string: string, filename: filename, eventID: userInfo["eventID"] as? String) {
            out["path"] = path
            let process = (filename as NSString).components(separatedBy: "@").first ?? filename
            let pretty = CR4StringFromDate(Date(), .pretty) ?? ""
            let notification = userInfo["notificationContent"] as? String
            Notifier.post(content: notification ?? "\(process) crashed at \(pretty)", logPath: path)
        }
    case 2:
        let name = userInfo["value"] as? String ?? ""
        out["ret"] = NSNumber(value: (CR4PrefsBlacklist() as? [String])?.contains(name) ?? false)
    case 3:
        out["ret"] = NSNumber(value: CR4PrefsEnableJetsam())
    case 4:
        let t = time_t((userInfo["time"] as? NSNumber)?.intValue ?? 0)
        let type = CR4DateFormat(rawValue: (userInfo["type"] as? NSNumber)?.intValue ?? 0) ?? .pretty
        if let str = CR4StringFromDate(Date(timeIntervalSince1970: TimeInterval(t)), type) {
            out["ret"] = str
        }
    case 5:
        let pid = pid_t((userInfo["pid"] as? NSNumber)?.int32Value ?? 0)
        let targetClass = userInfo["targetClass"] as? String ?? ""
        let hookCount = (userInfo["hookCount"] as? NSNumber)?.int64Value ?? 0
        out["accepted"] = NSNumber(value: ReportCrashPrewarmer.recordReady(pid: pid, targetClass: targetClass, hookCount: hookCount))
    default:
        break
    }
    return out
}

enum LogMonitor {
    private static var source: DispatchSourceFileSystemObject?

    static func startMonitoring() {
        let dir = CR4LogDirectory() as String
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o755,
                .ownerAccountName: "mobile",
                .groupOwnerAccountName: "mobile"
            ])
        }
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            #if CR4_DEBUG_LOGGING
            NSLog("[cr4shedd] Failed to open log directory for monitoring: %d", errno)
            #endif
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .global(qos: .userInitiated))
        s.setEventHandler {
            checkNewLogs()
        }
        s.setCancelHandler {
            close(fd)
        }
        s.resume()
        source = s
        #if CR4_DEBUG_LOGGING
        NSLog("[cr4shedd] Started monitoring log directory: %@", dir)
        #endif
    }

    private static func checkNewLogs() {
        let dir = CR4LogDirectory() as String
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let now = Date()
        for file in files where file.hasSuffix(".log") {
            let fullPath = (dir as NSString).appendingPathComponent(file)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let cdate = attrs[.creationDate] as? Date else { continue }
            // 只补充近期新文件的通知；去重和分类交给统一通知入口。
            if (0..<10.0).contains(now.timeIntervalSince(cdate)) {
                let process = file.components(separatedBy: "@").first ?? file
                let pretty = CR4StringFromDate(cdate, .pretty) ?? ""
                let content = "\(process) generated a report at \(pretty)"
                Notifier.post(content: content, logPath: fullPath)
            }
        }
    }
}

autoreleasepool {
    LogMonitor.startMonitoring()
    CR4RunXPCListener { messageID, userInfo in
        handle(messageID, userInfo: userInfo)
    }
    ReportCrashPrewarmer.start()
    RunLoop.current.run()
}
