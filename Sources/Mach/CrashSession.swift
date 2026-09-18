import Foundation
import ObjectiveC

final class CrashSession: NSObject {
    var crashTime: time_t = time(nil)
    var far: UInt64 = 0
    var realCrashedNumber: Int = -1
    var hasBeenHandled = false
    var didGenerate = false
    var stackSymbols: [String] = []
    var registers: [(String, UInt64)] = []
    var images: [String] = []
    var swiftError: String?
    var threadName: String?
    var processName: String = ""
    var bundleID: String = ""
    var exceptionType: String = ""
    var exceptionSubtype: String = ""
    var exceptionCodes: String = ""
    var vmInfo: String?
    var threadNum: UInt64 = 0
    var version: String = ""
    var terminationReason: String = ""
    var collected = false
}

enum CrashSessionStore {
    private static var key: UInt8 = 0

    static func session(for object: AnyObject) -> CrashSession {
        if let existing = objc_getAssociatedObject(object, &key) as? CrashSession {
            return existing
        }
        let session = CrashSession()
        objc_setAssociatedObject(object, &key, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }
}
