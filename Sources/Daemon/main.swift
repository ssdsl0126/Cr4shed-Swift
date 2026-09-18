import Foundation
import UserNotifications

enum LogWriter {
    static func write(string: String, filename rawName: String) -> String? {
        let filename = (rawName as NSString).lastPathComponent
        if filename.isEmpty { return nil }
        var full = (filename as NSString).appendingPathExtension("log") ?? "\(filename).log"
        if (full as NSString).pathComponents.count > 1 { return nil }
        let dir = CR4LogDirectory() as String
        var path = (dir as NSString).appendingPathComponent(full)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: dir, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            if exists { try? fm.removeItem(atPath: dir) }
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
                    .posixPermissions: 0o755,
                    .ownerAccountName: "mobile",
                    .groupOwnerAccountName: "mobile"
                ])
            } catch {
                return nil
            }
        }
        var i: UInt64 = 1
        while fm.fileExists(atPath: path) {
            let stem = (filename as NSString).deletingPathExtension
            full = "\(stem) (\(i)).log"
            path = (dir as NSString).appendingPathComponent(full)
            i += 1
        }
        let data = string.data(using: .utf8) ?? Data()
        fm.createFile(atPath: path, contents: data, attributes: [
            .posixPermissions: 0o666,
            .ownerAccountName: "mobile",
            .groupOwnerAccountName: "mobile"
        ])
        return path
    }
}

enum Notifier {
    static func post(content: String, logPath: String?) {
        let center: UNUserNotificationCenter
        let sel = NSSelectorFromString("initWithBundleIdentifier:")
        if UNUserNotificationCenter.instancesRespond(to: sel),
           let allocated = UNUserNotificationCenter.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
           let inited = allocated.perform(sel, with: CR4SHED_GUI_BUNDLE as NSString)?.takeUnretainedValue() as? UNUserNotificationCenter {
            center = inited
        } else {
            center = UNUserNotificationCenter.current()
        }
        let note = UNMutableNotificationContent()
        note.title = "Cr4shed"
        note.body = content
        if let logPath {
            note.userInfo = ["logPath": logPath]
        }
        note.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil)
        center.add(request) { error in
            if let error = error {
                NSLog("[cr4shedd] UNUserNotificationCenter error: %@", error.localizedDescription)
            }
        }
    }
}

private func handle(_ message: xpc_object_t) -> xpc_object_t {
    let reply = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
    let id = xpc_dictionary_get_int64(message, "id")
    let userInfoXPC = xpc_dictionary_get_value(message, "userInfo")
    var userInfo: [String: Any] = [:]
    if let userInfoXPC, xpc_get_type(userInfoXPC) == XPC_TYPE_DICTIONARY {
        xpc_dictionary_apply(userInfoXPC) { key, value in
            let nsKey = String(cString: key)
            let type = xpc_get_type(value)
            if type == XPC_TYPE_STRING, let ptr = xpc_string_get_string_ptr(value) {
                userInfo[nsKey] = String(cString: ptr)
            } else if type == XPC_TYPE_INT64 {
                userInfo[nsKey] = NSNumber(value: xpc_int64_get_value(value))
            } else if type == XPC_TYPE_BOOL {
                userInfo[nsKey] = NSNumber(value: xpc_bool_get_value(value))
            }
            return true
        }
    }

    var out: [String: Any] = [:]
    switch id {
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
        if let path = LogWriter.write(string: string, filename: filename) {
            out["path"] = path
            let process = (filename as NSString).components(separatedBy: "@").first ?? filename
            let pretty = CR4StringFromDate(Date(), .pretty) ?? ""
            Notifier.post(content: "\(process) crashed at \(pretty)", logPath: path)
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
    default:
        break
    }

    let xpcOut = xpc_dictionary_create(nil, nil, 0)
    for (key, value) in out {
        if let s = value as? String {
            xpc_dictionary_set_string(xpcOut, key, s)
        } else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                xpc_dictionary_set_bool(xpcOut, key, n.boolValue)
            } else {
                xpc_dictionary_set_int64(xpcOut, key, n.int64Value)
            }
        }
    }
    xpc_dictionary_set_value(reply, "userInfo", xpcOut)
    return reply
}

enum LogMonitor {
    private static var source: DispatchSourceFileSystemObject?
    private static var lastNotified: [String: Date] = [:]

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
            NSLog("[cr4shedd] Failed to open log directory for monitoring: %d", errno)
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
        NSLog("[cr4shedd] Started monitoring log directory: %@", dir)
    }

    private static func checkNewLogs() {
        let dir = CR4LogDirectory() as String
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let now = Date()
        for file in files where file.hasSuffix(".log") {
            let fullPath = (dir as NSString).appendingPathComponent(file)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let cdate = attrs[.creationDate] as? Date else { continue }
            // 只处理 10 秒内创建的新文件，防止重复通知
            if now.timeIntervalSince(cdate) < 10.0 {
                if let prev = lastNotified[fullPath], now.timeIntervalSince(prev) < 15.0 {
                    continue
                }
                lastNotified[fullPath] = now
                let process = file.components(separatedBy: "@").first ?? file
                let pretty = CR4StringFromDate(cdate, .pretty) ?? ""
                let content = "\(process) crashed at \(pretty)"
                NSLog("[cr4shedd] Detected new log file: %@, notifying...", file)
                Notifier.post(content: content, logPath: fullPath)
            }
        }
    }
}

autoreleasepool {
    LogMonitor.startMonitoring()
    CR4RunXPCListener { raw in
        let message = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as! OS_xpc_object
        let reply = handle(message)
        return Unmanaged.passRetained(reply as AnyObject).toOpaque()
    }
    RunLoop.current.run()
}
