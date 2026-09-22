import Foundation
import Combine
import UIKit

final class CrashProcess: Identifiable, ObservableObject {
    let name: String
    let appIcon: UIImage?
    var logs: [CrashLog]
    var latestDate: Date?
    var id: String { name }

    init(name: String, logs: [CrashLog] = [], appIcon: UIImage? = nil) {
        self.name = name
        self.appIcon = appIcon
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
        let dir = logDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var groupedLogs: [String: [CrashLog]] = [:]
        for name in names where (name as NSString).pathExtension == "log" {
            let path = (dir as NSString).appendingPathComponent(name)
            let log = CrashLog(path: path)
            let procName = name.components(separatedBy: "@").first ?? "(null)"
            groupedLogs[procName, default: []].append(log)
        }
        var list = groupedLogs.map { name, logs in
            let latestLog = logs.max { $0.date < $1.date }
            return CrashProcess(
                name: name,
                logs: logs,
                appIcon: AppIconResolver.icon(for: latestLog)
            )
        }
        let method = CR4PrefsSortingMethod() as String? ?? "Date"
        if method == "Name" {
            list.sort { $0.name.lowercased() < $1.name.lowercased() }
        } else {
            list.sort { ($0.latestDate ?? .distantPast) > ($1.latestDate ?? .distantPast) }
        }
        processes = list.filter { !$0.logs.isEmpty }
    }

    private var logDirectory: String {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CR4_SIMULATOR_PREVIEW"] == "1",
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("Cr4shed", isDirectory: true).path
        }
        #endif
        return CR4LogDirectory() as String
    }
}

enum AppIconResolver {
    private typealias IconMethod = @convention(c) (
        AnyClass,
        Selector,
        NSString,
        Int32,
        CGFloat
    ) -> Unmanaged<AnyObject>?

    private static let iconSelector = NSSelectorFromString(
        "_applicationIconImageForBundleIdentifier:format:scale:"
    )
    private static let cache = NSCache<NSString, UIImage>()

    static func icon(for log: CrashLog?) -> UIImage? {
        guard let log else { return nil }

        let appURL = applicationBundleURL(in: log.contents)
        var identifiers: [String] = []
        if let identifier = appURL.flatMap(bundleIdentifier(at:)) {
            identifiers.append(identifier)
        }
        if let identifier = processBundleIdentifier(in: log),
           !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }

        for identifier in identifiers {
            if let cached = cache.object(forKey: identifier as NSString) {
                return cached
            }
            if let image = systemIcon(bundleIdentifier: identifier) {
                cache.setObject(image, forKey: identifier as NSString)
                return image
            }
        }

        // 私有图标接口不可用时，从日志中的宿主 .app 路径直接读取资源。
        if let appURL, let image = bundledIcon(at: appURL) {
            return image
        }
        return nil
    }

    static func applicationName(for log: CrashLog) -> String? {
        guard let appURL = applicationBundleURL(in: log.contents),
              let info = bundleInfo(at: appURL) else { return nil }
        for key in ["CFBundleDisplayName", kCFBundleNameKey as String] {
            if let name = info[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private static func systemIcon(bundleIdentifier: String) -> UIImage? {
        guard let method = class_getClassMethod(UIImage.self, iconSelector) else { return nil }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: IconMethod.self)
        return function(
            UIImage.self,
            iconSelector,
            bundleIdentifier as NSString,
            2,
            UIScreen.main.scale
        )?.takeUnretainedValue() as? UIImage
    }

    private static func applicationBundleURL(in contents: String) -> URL? {
        let imageList: Substring
        if let marker = contents.range(of: "Loaded images:") {
            imageList = contents[marker.upperBound...]
        } else {
            imageList = contents[contents.startIndex...]
        }

        for line in imageList.components(separatedBy: .newlines) {
            guard let appRange = line.range(of: ".app", options: .caseInsensitive) else { continue }
            guard let pathStart = line[..<appRange.lowerBound].firstIndex(of: "/") else { continue }
            let path = String(line[pathStart..<appRange.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    private static func processBundleIdentifier(in log: CrashLog) -> String? {
        if let identifier = log.info["ProcessBundleID"] as? String {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        for line in log.contents.components(separatedBy: .newlines) where line.hasPrefix("Bundle id: ") {
            let identifier = line.dropFirst("Bundle id: ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty { return identifier }
        }
        return nil
    }

    private static func bundleIdentifier(at appURL: URL) -> String? {
        guard let info = bundleInfo(at: appURL),
              let identifier = info[kCFBundleIdentifierKey as String] as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private static func bundleInfo(at appURL: URL) -> [String: Any]? {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }

    private static func bundledIcon(at appURL: URL) -> UIImage? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        for name in iconNames(in: bundle.infoDictionary ?? [:]) {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
            if let path = bundle.path(forResource: name, ofType: "png"),
               let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    private static func iconNames(in info: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let icons = info[key] as? [String: Any]
            let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
            names.append(contentsOf: (primary?["CFBundleIconFiles"] as? [String])?.reversed() ?? [])
            if let name = primary?["CFBundleIconName"] as? String {
                names.append(name)
            }
        }
        names.append(contentsOf: (info["CFBundleIconFiles"] as? [String])?.reversed() ?? [])
        if let name = info["CFBundleIconFile"] as? String {
            names.append(name)
        }
        return names
    }
}
