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

    var dateName: String {
        let parts = fileName.components(separatedBy: "@")
        return parts.count > 1 ? parts[1] : parts[0]
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

    static func == (lhs: CrashLog, rhs: CrashLog) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
