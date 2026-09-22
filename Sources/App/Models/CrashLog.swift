import Foundation

final class CrashLog: Identifiable, Hashable {
    let path: String
    let date: Date
    private var cachedContents: String?
    private var cachedInfo: [String: Any]?

    var id: String { path }

    init(path: String) {
        self.path = path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        self.date = (attrs?[.creationDate] as? Date) ?? Date()
    }

    var fileName: String { (path as NSString).lastPathComponent }

    var processName: String {
        if let name = info["ProcessName"] as? String, !name.isEmpty { return name }
        return fileName.components(separatedBy: "@").first ?? fileName
    }

    var bundleIdentifier: String {
        if let identifier = info["ProcessBundleID"] as? String, !identifier.isEmpty {
            return identifier
        }
        return value(after: "Bundle id: ") ?? ""
    }

    var exceptionTypeText: String? {
        if let type = info["ExceptionType"] as? String, !type.isEmpty { return type }
        return value(after: "Exception type: ")
    }

    var culpritText: String {
        let culprit = (info["Culprit"] as? String) ?? ""
        if culprit.isEmpty || culprit == "Unknown" {
            return String(localized: "Unknown")
        }
        return culprit
    }

    var reasonText: String? {
        for key in ["NSExceptionReason", "CrashReason", "Reason"] {
            if let reason = info[key] as? String, !reason.isEmpty { return reason }
        }
        return value(after: "Reason: ")
            ?? value(after: "Swift Error Message: ")
            ?? value(after: "Exception subtype: ")
    }

    var dateName: String {
        let parts = fileName.components(separatedBy: "@")
        let name = parts.count > 1 ? parts[1] : parts[0]
        let stem = (name as NSString).deletingPathExtension
        // 事件标识用于保存去重，界面标题仍只展示报告时间。
        if let suffix = stem.range(of: " (", options: .backwards), stem.hasSuffix(")"),
           UUID(uuidString: String(stem[suffix.upperBound...].dropLast())) != nil {
            return String(stem[..<suffix.lowerBound])
        }
        return name
    }

    var contents: String {
        if let cachedContents { return cachedContents }
        let value = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        cachedContents = value
        return value
    }

    var info: [String: Any] {
        if let cachedInfo { return cachedInfo }
        let parsed = (CR4GetInfoFromLog(contents) as? [String: Any]) ?? [:]
        cachedInfo = parsed
        return parsed
    }

    private func value(after prefix: String) -> String? {
        for line in contents.components(separatedBy: .newlines) where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func == (lhs: CrashLog, rhs: CrashLog) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
