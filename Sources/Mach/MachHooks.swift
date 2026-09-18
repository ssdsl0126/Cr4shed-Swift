import Foundation
import ObjectiveC

private typealias VoidIMP = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void
private typealias Init6IMP = @convention(c) (
    UnsafeMutableRawPointer,
    Selector,
    UInt32,
    Int32,
    UInt32,
    UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<UInt32>?,
    UInt32
) -> UnsafeMutableRawPointer?

private typealias Init7IMP = @convention(c) (
    UnsafeMutableRawPointer,
    Selector,
    UInt32,
    Int32,
    UInt32,
    UInt64,
    UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<UInt32>?,
    UInt32
) -> UnsafeMutableRawPointer?

private typealias GenLogIMP = @convention(c) (UnsafeMutableRawPointer, Selector, Bool, AnyObject?) -> Void

private var origLoadBundleInfo: VoidIMP?
private var origGenerateLog: GenLogIMP?
private var origGenerateCustomLog: GenLogIMP?
private var origInit6: Init6IMP?
private var origInit7: Init7IMP?

private let hookedLoadBundleInfo: VoidIMP = { selfPtr, sel in
    origLoadBundleInfo?(selfPtr, sel)
    let obj = Unmanaged<AnyObject>.fromOpaque(selfPtr).takeUnretainedValue()
    MachReport.collect(obj)
    MachReport.generate(obj)
}

private let hookedGenerateLog: GenLogIMP = { selfPtr, sel, flag, block in
    origGenerateLog?(selfPtr, sel, flag, block)
    let obj = Unmanaged<AnyObject>.fromOpaque(selfPtr).takeUnretainedValue()
    MachReport.generate(obj)
}

private let hookedGenerateCustomLog: GenLogIMP = { selfPtr, sel, flag, block in
    origGenerateCustomLog?(selfPtr, sel, flag, block)
    let obj = Unmanaged<AnyObject>.fromOpaque(selfPtr).takeUnretainedValue()
    MachReport.generate(obj)
}

private let hookedInit6: Init6IMP = { selfPtr, sel, task, type, thread, flavor, state, count in
    let result = origInit6?(selfPtr, sel, task, type, thread, flavor, state, count) ?? selfPtr
    let obj = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
    MachReport.sharedInit(obj, task: task, thread: thread)
    return result
}

private let hookedInit7: Init7IMP = { selfPtr, sel, task, type, thread, threadId, flavor, state, count in
    let result = origInit7?(selfPtr, sel, task, type, thread, threadId, flavor, state, count) ?? selfPtr
    let obj = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
    MachReport.sharedInit(obj, task: task, thread: thread)
    return result
}

private func hookMessage(_ cls: AnyClass, _ name: String, _ imp: IMP, orig: UnsafeMutablePointer<IMP?>) {
    let sel = NSSelectorFromString(name)
    guard class_getInstanceMethod(cls, sel) != nil else { return }
    CR4HookMessage(cls, sel, imp, orig)
}

private func install(on cls: AnyClass, includeLegacyExtras: Bool) {
    var loadOrig: IMP?
    hookMessage(cls, "loadBundleInfo", unsafeBitCast(hookedLoadBundleInfo, to: IMP.self), orig: &loadOrig)
    if let loadOrig { origLoadBundleInfo = unsafeBitCast(loadOrig, to: VoidIMP.self) }

    var genOrig: IMP?
    hookMessage(cls, "generateLogAtLevel:withBlock:", unsafeBitCast(hookedGenerateLog, to: IMP.self), orig: &genOrig)
    if let genOrig { origGenerateLog = unsafeBitCast(genOrig, to: GenLogIMP.self) }

    var init7: IMP?
    hookMessage(cls, "initWithTask:exceptionType:thread:threadId:threadStateFlavor:threadState:threadStateCount:", unsafeBitCast(hookedInit7, to: IMP.self), orig: &init7)
    if let init7 { origInit7 = unsafeBitCast(init7, to: Init7IMP.self) }

    var init6: IMP?
    hookMessage(cls, "initWithTask:exceptionType:thread:threadStateFlavor:threadState:threadStateCount:", unsafeBitCast(hookedInit6, to: IMP.self), orig: &init6)
    if let init6 { origInit6 = unsafeBitCast(init6, to: Init6IMP.self) }

    if includeLegacyExtras {
        var custom: IMP?
        hookMessage(cls, "generateCustomLogAtLevel:withBlock:", unsafeBitCast(hookedGenerateCustomLog, to: IMP.self), orig: &custom)
        if let custom { origGenerateCustomLog = unsafeBitCast(custom, to: GenLogIMP.self) }
    }
}

@_cdecl("cr4shed_mach_init")
public func cr4shed_mach_init() {
    autoreleasepool {
        NSLog("[Cr4shedMach] Initializing in process: %@", ProcessInfo.processInfo.processName)
        var targetClass: AnyClass? = nil
        
        let numClasses = objc_getClassList(nil, 0)
        if numClasses > 0 {
            let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(numClasses))
            defer { classes.deallocate() }
            let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), numClasses)
            for i in 0..<Int(count) {
                guard let cls = classes[i] else { continue }
                if strcmp(class_getName(cls), "CrashReport") == 0 {
                    let bundle = Bundle(for: cls)
                    if bundle.bundleIdentifier == "com.apple.CrashReporter" {
                        targetClass = cls
                        break
                    }
                }
            }
        }
        
        if targetClass == nil {
            targetClass = NSClassFromString("OSACrashReport") ?? NSClassFromString("CrashReport") ?? NSClassFromString("LegacyCrashReport")
        }
        
        guard let cls = targetClass else {
            NSLog("[Cr4shedMach] Target CrashReport class not found")
            return
        }
        
        let name = NSStringFromClass(cls)
        NSLog("[Cr4shedMach] Installing hooks on single target class: %@", name)
        let isLegacy = (name == "LegacyCrashReport" || name == "CrashReport")
        install(on: cls, includeLegacyExtras: isLegacy)
    }
}
