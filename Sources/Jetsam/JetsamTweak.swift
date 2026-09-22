import Foundation
import Darwin
import ObjectiveC

private typealias FactoryIMP = @convention(c) (AnyClass, Selector, UInt32, UnsafeMutablePointer<Unmanaged<AnyObject>?>?) -> Unmanaged<AnyObject>?
private typealias PrettyBacktraceIMP = @convention(c) (AnyObject, Selector, Bool) -> Unmanaged<AnyObject>?
private var origFactory: FactoryIMP?

private let hookedFactory: FactoryIMP = { cls, sel, task, error in
    // 该工厂返回后 task port 可能已经失效，先保存可用的内存快照。
    let earlyMemoryInfo: String? = CR4ShouldLogJetsam()
        ? autoreleasepool { usableMemorySnapshot(task: task, timing: "resource exception factory entry") }
        : nil
    let result = origFactory?(cls, sel, task, error)
    if let obj = result?.takeUnretainedValue() {
        autoreleasepool { JetsamReport.write(from: obj, earlyMemoryInfo: earlyMemoryInfo) }
    }
    return result
}

private func usableMemorySnapshot(task: mach_port_t, timing: String) -> String? {
    guard let snapshot = CR4TaskMemoryDescription(task),
          !snapshot.hasPrefix("Memory snapshot: unavailable") else { return nil }
    return "Memory snapshot timing: \(timing)\n\(snapshot)"
}

enum JetsamReport {
    static func write(from object: AnyObject, earlyMemoryInfo: String?) {
        if !CR4ShouldLogJetsam() { return }
        let execName = (object.value(forKey: "execName") as? String) ?? ""
        guard !execName.isEmpty else {
            #if CR4_DEBUG_LOGGING
            NSLog("[Cr4shedJetsam] Ignoring a memory report without an executable name")
            #endif
            return
        }
        if CR4IsProcessBlacklisted(execName) { return }

        let bundleID = (object.value(forKey: "bundleID") as? String) ?? ""
        let eventTime = objectDate(object, selector: "currentTime") ?? Date()
        let startTime = objectDate(object, selector: "startTime")
        let upTime = (object.value(forKey: "upTime") as? NSNumber)?.int64Value ?? 0
        let task = (object.value(forKey: "task") as? NSNumber)?.uint32Value ?? 0
        let pid = (object.value(forKey: "pid") as? NSNumber)?.intValue ?? 0
        let exceptionCode = (object.value(forKey: "exceptionCode0") as? NSNumber)?.uint64Value ?? 0
        let resource = resourceDescription(code: exceptionCode)

        let reportTime = time_t(eventTime.timeIntervalSince1970)
        let dateString = CR4StringFromTime(reportTime, .pretty) ?? ""
        let device = "\(CR4DeviceName() ?? "Unknown"), iOS \(CR4DeviceVersion() ?? "Unknown")"
        let reason = resource.reason
        var log = "Date: \(dateString)\nProcess: \(execName)\nProcess id: \(pid)\nBundle id: \(bundleID)\nDevice: \(device)\n"
        if let startTime {
            let processStart = CR4StringFromDate(startTime, .pretty) ?? ""
            if !processStart.isEmpty { log += "Process start: \(processStart)\n" }
        }
        log += "\nException type: EXC_RESOURCE\n"
        log += "Exception subtype: \(resource.subtype)\n"
        log += String(format: "Exception codes: 0x%016llx\n", exceptionCode)
        log += "Reason: \(reason)\nUptime: \(upTime)s\n"
        if let earlyMemoryInfo {
            log += earlyMemoryInfo
        } else if let footprint = CR4TaskMemoryDescription(task) {
            log += "Memory snapshot timing: report assembly\n\(footprint)"
        }
        log += memoryInfo(task: task)
        if let backtrace = prettyBacktrace(object), !backtrace.isEmpty {
            if !log.hasSuffix("\n") { log += "\n" }
            log += "\nBacktrace at memory exception:\n\(backtrace)\n"
        }
        let imagesSelector = NSSelectorFromString("prettyPrintBinaryImages")
        if object.responds(to: imagesSelector),
           let images = object.perform(imagesSelector)?.takeUnretainedValue() as? String {
            if !log.hasSuffix("\n") { log += "\n" }
            log += "\n\(images)"
        }
        let extra: [String: String] = [
            "NSExceptionReason": reason,
            "CrashReason": reason,
            "ExceptionType": "EXC_RESOURCE",
            "ExceptionCodes": String(format: "0x%016llx", exceptionCode),
            "ResourceSubtype": resource.subtype,
            "ProcessID": String(pid),
            "ProcessName": execName,
            "ProcessBundleID": bundleID
        ]
        if let updated = CR4AddInfoToLog(log, extra) {
            log = updated
        }
        let filenameDate = CR4StringFromTime(reportTime, .filename) ?? "unknown"
        let notification = "\(execName) reported a memory resource event at \(dateString)"
        let path = CR4WriteLogViaDaemon(log, "\(execName)@\(filenameDate)", notification)
        if path == nil {
            #if CR4_DEBUG_LOGGING
            NSLog("[Cr4shedJetsam] Failed to save memory resource report for %@ (pid %d)", execName, pid)
            #endif
        }
    }

    private static func objectDate(_ object: AnyObject, selector name: String) -> Date? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? Date
    }

    private static func prettyBacktrace(_ object: AnyObject) -> String? {
        let selector = NSSelectorFromString("prettyPrintBacktrace:")
        guard object.responds(to: selector), let instance = object as? NSObject else { return nil }
        let implementation = instance.method(for: selector)
        let function = unsafeBitCast(implementation, to: PrettyBacktraceIMP.self)
        // 系统对象已经持有回溯数据；这里仅请求带符号的文本，不在目标进程安装观察点。
        return function(instance, selector, true)?.takeUnretainedValue() as? String
    }

    private static func resourceDescription(code: UInt64) -> (subtype: String, reason: String) {
        let type = (code >> 61) & 0x7
        let flavor = (code >> 58) & 0x7
        if type == 3 {
            let limitMB = code & 0x1fff
            switch flavor {
            case 1:
                return (
                    "RESOURCE_TYPE_MEMORY / FLAVOR_HIGH_WATERMARK",
                    "The process reached its memory high-water mark (limit: \(limitMB) MB)"
                )
            case 2:
                return (
                    "RESOURCE_TYPE_MEMORY / FLAVOR_DIAG_MEMLIMIT",
                    "The process crossed its diagnostic memory limit (limit: \(limitMB) MB)"
                )
            case 3:
                return (
                    "RESOURCE_TYPE_MEMORY / FLAVOR_CONCLAVE_LIMIT",
                    "The process reached its conclave memory limit (limit: \(limitMB) MB)"
                )
            default:
                return ("RESOURCE_TYPE_MEMORY / flavor \(flavor)", "The process triggered a memory resource exception")
            }
        }
        return ("resource type \(type) / flavor \(flavor)", "The process triggered a resource exception")
    }

    private static func memoryInfo(task: mach_port_t) -> String {
        guard task != 0 else { return "" }
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task, task_flavor_t(TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "" }
        var text = String(format: "Virtual memory size: 0x%zx bytes\nResident memory size: 0x%zx bytes\n", Int(info.virtual_size), Int(info.resident_size))
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(task, &threads, &threadCount) == KERN_SUCCESS, let threads {
            var cpu: Int64 = 0
            for i in 0..<Int(threadCount) {
                var threadInfo = thread_basic_info()
                var tcount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let tkr = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) { rebound in
                        thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), rebound, &tcount)
                    }
                }
                if tkr == KERN_SUCCESS { cpu += Int64(threadInfo.cpu_usage) }
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(MemoryLayout<thread_act_t>.size) * vm_size_t(threadCount))
            // cpu_usage 使用 TH_USAGE_SCALE 定点刻度，多核总和可以超过 100%。
            text += String(format: "CPU usage: %.1f%%\nThread count: %u\n", Double(cpu) * 100 / Double(TH_USAGE_SCALE), threadCount)
        }
        return text
    }
}

@_cdecl("cr4shed_jetsam_init")
public func cr4shed_jetsam_init() {
    autoreleasepool {
        let sandboxResult = CR4ApplySandboxProfile("Cr4shedTweak")
        if sandboxResult != 0 {
            #if CR4_DEBUG_LOGGING
            NSLog("[Cr4shedJetsam] Failed to apply Cr4shedTweak sandbox profile: %d", sandboxResult)
            #endif
        }
        guard let cls = NSClassFromString("MemoryResourceException") else { return }
        let sel = NSSelectorFromString("resourceExceptionFromTask:error:")
        guard class_getClassMethod(cls, sel) != nil else { return }
        var orig: IMP?
        CR4HookMessage(object_getClass(cls), sel, unsafeBitCast(hookedFactory, to: IMP.self), &orig)
        if let orig { origFactory = unsafeBitCast(orig, to: FactoryIMP.self) }
    }
}
