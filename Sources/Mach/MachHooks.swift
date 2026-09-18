import Foundation
import ObjectiveC

private typealias VoidIMP = @convention(c) (AnyObject, Selector) -> Void
private typealias Init6IMP = @convention(c) (AnyObject, Selector, UInt32, Int32, UInt32, Int32, UnsafeMutablePointer<UInt32>?, UInt32) -> Unmanaged<AnyObject>
private typealias Init7IMP = @convention(c) (AnyObject, Selector, UInt32, Int32, UInt32, UInt64, Int32, UnsafeMutablePointer<UInt32>?, UInt32) -> Unmanaged<AnyObject>
private typealias GenLogIMP = @convention(c) (AnyObject, Selector, Bool, AnyObject?) -> Void

private var origLoadBundleInfo: VoidIMP?
private var origGenerateLog: GenLogIMP?
private var origGenerateCustomLog: GenLogIMP?
private var origInit6: Init6IMP?
private var origInit7: Init7IMP?

private let hookedLoadBundleInfo: VoidIMP = { obj, sel in
    origLoadBundleInfo?(obj, sel)
    MachReport.collect(obj)
    MachReport.generate(obj)
}

private let hookedGenerateLog: GenLogIMP = { obj, sel, flag, block in
    origGenerateLog?(obj, sel, flag, block)
    MachReport.generate(obj)
}

private let hookedGenerateCustomLog: GenLogIMP = { obj, sel, flag, block in
    origGenerateCustomLog?(obj, sel, flag, block)
    MachReport.generate(obj)
}

private let hookedInit6: Init6IMP = { obj, sel, task, type, thread, flavor, state, count in
    let result = origInit6?(obj, sel, task, type, thread, flavor, state, count) ?? Unmanaged.passUnretained(obj)
    MachReport.sharedInit(obj, task: task, thread: thread)
    return result
}

private let hookedInit7: Init7IMP = { obj, sel, task, type, thread, threadId, flavor, state, count in
    let result = origInit7?(obj, sel, task, type, thread, threadId, flavor, state, count) ?? Unmanaged.passUnretained(obj)
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
        var targetClasses: [AnyClass] = []
        if let osa = NSClassFromString("OSACrashReport") { targetClasses.append(osa) }
        if let crash = NSClassFromString("CrashReport") { targetClasses.append(crash) }
        if let legacy = NSClassFromString("LegacyCrashReport") { targetClasses.append(legacy) }
        
        let numClasses = objc_getClassList(nil, 0)
        if numClasses > 0 {
            let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(numClasses))
            defer { classes.deallocate() }
            let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), numClasses)
            for i in 0..<Int(count) {
                guard let cls = classes[i] else { continue }
                let name = NSStringFromClass(cls)
                if (name == "OSACrashReport" || name == "CrashReport" || name == "LegacyCrashReport") && !targetClasses.contains(where: { $0 == cls }) {
                    targetClasses.append(cls)
                }
            }
        }
        
        for cls in targetClasses {
            let name = NSStringFromClass(cls)
            NSLog("[Cr4shedMach] Installing hooks on class: %@", name)
            install(on: cls, includeLegacyExtras: (name == "LegacyCrashReport" || name == "CrashReport"))
        }
    }
}
