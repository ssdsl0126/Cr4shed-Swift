import Foundation
import Darwin
import ObjectiveC

private typealias FactoryIMP = @convention(c) (AnyClass, Selector, UInt32, UnsafeMutablePointer<Unmanaged<AnyObject>?>?) -> Unmanaged<AnyObject>?
private var origFactory: FactoryIMP?

private let hookedFactory: FactoryIMP = { cls, sel, task, error in
    let result = origFactory?(cls, sel, task, error)
    if let obj = result?.takeUnretainedValue() {
        JetsamReport.write(from: obj)
    }
    return result
}

enum JetsamReport {
    static func write(from object: AnyObject) {
        if !CR4ShouldLogJetsam() { return }
        let execName = (object.value(forKey: "execName") as? String) ?? ""
        if CR4IsProcessBlacklisted(execName) { return }

        let bundleID = (object.value(forKey: "bundleID") as? String) ?? ""
        let startTime = object.value(forKey: "startTime") as? Date ?? Date()
        let upTime = (object.value(forKey: "upTime") as? NSNumber)?.int64Value ?? 0
        let task = (object.value(forKey: "task") as? NSNumber)?.uint32Value ?? 0

        let crashTime = time_t(startTime.timeIntervalSince1970)
        let dateString = CR4StringFromTime(crashTime, .pretty) ?? ""
        let device = "\(CR4DeviceName() ?? "Unknown"), iOS \(CR4DeviceVersion() ?? "Unknown")"
        let reason = "The process was terminated for exceeding jetsam memory limits"
        var log = "Date: \(dateString)\nProcess: \(execName)\nBundle id: \(bundleID)\nDevice: \(device)\n\nReason: \(reason)\nUptime: \(upTime)s\n"
        log += memoryInfo(task: task)
        if let images = object.perform(NSSelectorFromString("prettyPrintBinaryImages"))?.takeUnretainedValue() as? String {
            if !log.hasSuffix("\n") { log += "\n" }
            log += "\n\(images)"
        }
        let extra: [String: String] = [
            "NSExceptionReason": reason,
            "ProcessName": execName,
            "ProcessBundleID": bundleID
        ]
        if let updated = CR4AddInfoToLog(log, extra) {
            log = updated
        }
        let filenameDate = CR4StringFromTime(crashTime, .filename) ?? "unknown"
        _ = CR4WriteLog(log, "\(execName)@\(filenameDate)")
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
            var cpu: UInt32 = 0
            for i in 0..<Int(threadCount) {
                var threadInfo = thread_basic_info()
                var tcount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let tkr = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) { rebound in
                        thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), rebound, &tcount)
                    }
                }
                if tkr == KERN_SUCCESS { cpu += UInt32(threadInfo.cpu_usage) }
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(MemoryLayout<thread_act_t>.size) * vm_size_t(threadCount))
            text += "CPU usage: \(cpu)%\nThread count: \(threadCount)\n"
        }
        return text
    }
}

@_cdecl("cr4shed_jetsam_init")
public func cr4shed_jetsam_init() {
    autoreleasepool {
        guard let cls = NSClassFromString("MemoryResourceException") else { return }
        let sel = NSSelectorFromString("resourceExceptionFromTask:error:")
        guard class_getClassMethod(cls, sel) != nil else { return }
        var orig: IMP?
        CR4HookMessage(object_getClass(cls), sel, unsafeBitCast(hookedFactory, to: IMP.self), &orig)
        if let orig { origFactory = unsafeBitCast(orig, to: FactoryIMP.self) }
    }
}
