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
    autoreleasepool {
        MachReport.collect(obj)
        MachReport.generate(obj)
    }
}

private let hookedGenerateLog: GenLogIMP = { selfPtr, sel, flag, block in
    origGenerateLog?(selfPtr, sel, flag, block)
    let obj = Unmanaged<AnyObject>.fromOpaque(selfPtr).takeUnretainedValue()
    autoreleasepool { MachReport.generate(obj) }
}

private let hookedGenerateCustomLog: GenLogIMP = { selfPtr, sel, flag, block in
    origGenerateCustomLog?(selfPtr, sel, flag, block)
    let obj = Unmanaged<AnyObject>.fromOpaque(selfPtr).takeUnretainedValue()
    autoreleasepool { MachReport.generate(obj) }
}

private let hookedInit6: Init6IMP = { selfPtr, sel, task, type, thread, flavor, state, count in
    let result = origInit6?(selfPtr, sel, task, type, thread, flavor, state, count) ?? selfPtr
    let obj = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
    MachReport.sharedInit(obj, task: task, thread: thread, exceptionType: type)
    return result
}

private let hookedInit7: Init7IMP = { selfPtr, sel, task, type, thread, threadId, flavor, state, count in
    let result = origInit7?(selfPtr, sel, task, type, thread, threadId, flavor, state, count) ?? selfPtr
    let obj = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
    MachReport.sharedInit(obj, task: task, thread: thread, exceptionType: type)
    return result
}

@discardableResult
private func hookMessage(_ cls: AnyClass, _ name: String, _ imp: IMP, orig: UnsafeMutablePointer<IMP?>) -> Bool {
    let sel = NSSelectorFromString(name)
    guard class_getInstanceMethod(cls, sel) != nil else { return false }
    CR4HookMessage(cls, sel, imp, orig)
    return orig.pointee != nil
}

private func install(on cls: AnyClass, includeLegacyExtras: Bool) -> Int64 {
    var hookCount: Int64 = 0
    var loadOrig: IMP?
    if hookMessage(cls, "loadBundleInfo", unsafeBitCast(hookedLoadBundleInfo, to: IMP.self), orig: &loadOrig) { hookCount += 1 }
    if let loadOrig { origLoadBundleInfo = unsafeBitCast(loadOrig, to: VoidIMP.self) }

    var genOrig: IMP?
    if hookMessage(cls, "generateLogAtLevel:withBlock:", unsafeBitCast(hookedGenerateLog, to: IMP.self), orig: &genOrig) { hookCount += 1 }
    if let genOrig { origGenerateLog = unsafeBitCast(genOrig, to: GenLogIMP.self) }

    var init7: IMP?
    if hookMessage(cls, "initWithTask:exceptionType:thread:threadId:threadStateFlavor:threadState:threadStateCount:", unsafeBitCast(hookedInit7, to: IMP.self), orig: &init7) { hookCount += 1 }
    if let init7 { origInit7 = unsafeBitCast(init7, to: Init7IMP.self) }

    var init6: IMP?
    if hookMessage(cls, "initWithTask:exceptionType:thread:threadStateFlavor:threadState:threadStateCount:", unsafeBitCast(hookedInit6, to: IMP.self), orig: &init6) { hookCount += 1 }
    if let init6 { origInit6 = unsafeBitCast(init6, to: Init6IMP.self) }

    if includeLegacyExtras {
        var custom: IMP?
        if hookMessage(cls, "generateCustomLogAtLevel:withBlock:", unsafeBitCast(hookedGenerateCustomLog, to: IMP.self), orig: &custom) { hookCount += 1 }
        if let custom { origGenerateCustomLog = unsafeBitCast(custom, to: GenLogIMP.self) }
    }
    return hookCount
}

@_cdecl("cr4shed_mach_init")
public func cr4shed_mach_init() {
    autoreleasepool {
        #if CR4_DEBUG_LOGGING
        NSLog("[Cr4shedMach] Initializing in process: %@", ProcessInfo.processInfo.processName)
        #endif
        // 优先秒级直取 OSACrashReport，无需扫描全运行时几万个类，彻底根除启动 CPU 峰值
        let targetClass: AnyClass? = NSClassFromString("OSACrashReport")
            ?? NSClassFromString("CrashReport")
            ?? NSClassFromString("LegacyCrashReport")
        
        guard let cls = targetClass else {
            #if CR4_DEBUG_LOGGING
            NSLog("[Cr4shedMach] Target CrashReport class not found")
            #endif
            return
        }
        
        let name = NSStringFromClass(cls)
        #if CR4_DEBUG_LOGGING
        NSLog("[Cr4shedMach] Installing hooks on single target class: %@", name)
        #endif
        let isLegacy = (name == "LegacyCrashReport" || name == "CrashReport")
        let hookCount = install(on: cls, includeLegacyExtras: isLegacy)
        guard hookCount > 0 else {
            #if CR4_DEBUG_LOGGING
            NSLog("[Cr4shedMach] No compatible methods were hooked on %@", name)
            #endif
            return
        }
        CR4ReportMachReady(name, hookCount)
        #if CR4_DEBUG_LOGGING
        NSLog("[Cr4shedMach] Ready with %lld hooks on %@", hookCount, name)
        #endif
    }
}
