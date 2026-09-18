import Foundation
import ObjectiveC

enum IvarAccess {
    static func exists(_ object: AnyObject, _ name: String) -> Bool {
        guard let cls = object_getClass(object) else { return false }
        return class_getInstanceVariable(cls, name) != nil
    }

    static func objectValue(_ object: AnyObject, _ name: String) -> AnyObject? {
        guard let cls = object_getClass(object),
              let ivar = class_getInstanceVariable(cls, name) else { return nil }
        return object_getIvar(object, ivar) as AnyObject?
    }

    static func string(_ object: AnyObject, _ name: String) -> String? {
        objectValue(object, name) as? String
    }

    static func array(_ object: AnyObject, _ name: String) -> [Any]? {
        objectValue(object, name) as? [Any]
    }

    static func dictionary(_ object: AnyObject, _ name: String) -> [AnyHashable: Any]? {
        objectValue(object, name) as? [AnyHashable: Any]
    }

    static func value<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
        guard let cls = object_getClass(object),
              let ivar = class_getInstanceVariable(cls, name) else { return nil }
        let offset = ivar_getOffset(ivar)
        let base = Unmanaged.passUnretained(object).toOpaque()
        return base.advanced(by: offset).assumingMemoryBound(to: T.self).pointee
    }

    static func int32(_ object: AnyObject, _ name: String) -> Int32? {
        value(object, name, as: Int32.self)
    }

    static func uint32(_ object: AnyObject, _ name: String) -> UInt32? {
        value(object, name, as: UInt32.self)
    }

    static func uint64(_ object: AnyObject, _ name: String) -> UInt64? {
        value(object, name, as: UInt64.self)
    }
}
