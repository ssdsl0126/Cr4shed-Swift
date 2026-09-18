import Foundation
import Combine

final class CrashProcess: Identifiable, ObservableObject {
    let name: String
    var logs: [CrashLog]
    var latestDate: Date?
    var id: String { name }

    init(name: String, logs: [CrashLog] = []) {
        self.name = name
        self.logs = logs
        self.latestDate = logs.map { $0.date }.max()
    }

    var isBlacklisted: Bool {
        (CR4PrefsBlacklist() as? [String])?.contains(name) ?? false
    }

    func addToBlacklist() {
        var set = Set((CR4PrefsBlacklist() as? [String]) ?? [])
        set.insert(name)
        CR4PrefsSetObject(Array(set) as NSArray, kProcessBlacklist)
        NotificationCenter.default.post(name: Notification.Name(CR4BlacklistDidChangeNotificationName as String), object: nil)
    }

    func removeFromBlacklist() {
        var list = (CR4PrefsBlacklist() as? [String]) ?? []
        list.removeAll { $0 == name }
        CR4PrefsSetObject(list as NSArray, kProcessBlacklist)
        NotificationCenter.default.post(name: Notification.Name(CR4BlacklistDidChangeNotificationName as String), object: nil)
    }

    func deleteAllLogs() {
        for log in logs {
            try? FileManager.default.removeItem(atPath: log.path)
        }
        logs = []
        latestDate = nil
    }
}

final class ProcessStore: ObservableObject {
    @Published var processes: [CrashProcess] = []
    @Published var pendingLogPath: String?

    func refresh() {
        let dir = CR4LogDirectory() as String
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var map: [String: CrashProcess] = [:]
        for name in names where (name as NSString).pathExtension == "log" {
            let path = (dir as NSString).appendingPathComponent(name)
            let log = CrashLog(path: path)
            let procName = name.components(separatedBy: "@").first ?? "(null)"
            let proc = map[procName] ?? CrashProcess(name: procName)
            proc.logs.append(log)
            if proc.latestDate == nil || log.date > proc.latestDate! {
                proc.latestDate = log.date
            }
            map[procName] = proc
        }
        var list = Array(map.values)
        let method = CR4PrefsSortingMethod() as String? ?? "Date"
        if method == "Name" {
            list.sort { $0.name.lowercased() < $1.name.lowercased() }
        } else {
            list.sort { ($0.latestDate ?? .distantPast) > ($1.latestDate ?? .distantPast) }
        }
        processes = list.filter { !$0.logs.isEmpty }
    }
}
