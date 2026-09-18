import Foundation
import Darwin

enum MachReport {
    static func sharedInit(_ report: AnyObject, task: mach_port_t, thread: mach_port_t) {
        let session = CrashSessionStore.session(for: report)
        session.crashTime = time(nil)
        var realThread: mach_port_t = 0
        var far: UInt64 = 0
        if task != 0 {
            var threads: thread_act_array_t?
            var threadCount: mach_msg_type_number_t = 0
            if task_threads(task, &threads, &threadCount) == KERN_SUCCESS, let threads {
                for i in 0..<Int(threadCount) {
                    var state = arm_exception_state64_t()
                    var count = mach_msg_type_number_t(MemoryLayout<arm_exception_state64_t>.size / MemoryLayout<UInt32>.size)
                    let kr = withUnsafeMutablePointer(to: &state) { ptr in
                        ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                            thread_get_state(threads[i], ARM_EXCEPTION_STATE64, rebound, &count)
                        }
                    }
                    if kr == KERN_SUCCESS, (state.__esr & 0xFC000000) != 0x54000000, state.__esr != 0 {
                        realThread = threads[i]
                        far = state.__far
                        break
                    }
                }
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(MemoryLayout<thread_act_t>.size) * vm_size_t(threadCount))
            }
        }
        session.hasBeenHandled = task != 0 && CR4ProcessHasBeenHandled(task)
        if IvarAccess.exists(report, "_crashingAddress"), let addr = IvarAccess.uint64(report, "_crashingAddress") {
            session.far = addr
        } else {
            session.far = far
        }
        if realThread == 0 { realThread = thread }
        session.realCrashedNumber = (task != 0 && realThread != 0) ? Int(threadNumber(task: task, thread: realThread)) : -1
    }

    static func collect(_ report: AnyObject) {
        let session = CrashSessionStore.session(for: report)
        if session.hasBeenHandled || session.collected { return }

        let sig = IvarAccess.int32(report, "_signal") ?? 0
        session.processName = IvarAccess.string(report, "_procName") ?? ""
        if sig == 0 || sig == SIGKILL || CR4IsProcessBlacklisted(session.processName) { return }

        var codes: [Int64] = []
        if let count = IvarAccess.uint32(report, "_exceptionCodeCount"),
           let ptr = IvarAccess.value(report, "_exceptionCode", as: UnsafePointer<Int64>?.self),
           let ptr, count > 0 {
            for i in 0..<Int(count) { codes.append(ptr[i]) }
        }
        let mapped = MachStrings.fromSignal(sig)
        var exception = mapped.0
        if codes.isEmpty { codes = [mapped.1, 0] }
        else { codes[0] = mapped.1 }
        if exception == EXC_CORPSE_NOTIFY, session.realCrashedNumber != -1 {
            if codes.count < 2 { codes.append(Int64(bitPattern: session.far)) }
            else { codes[1] = Int64(bitPattern: session.far) }
        }

        if isNonFatal(report) { return }

        session.bundleID = IvarAccess.string(report, "_bundle_id") ?? ""
        let signalName = decodeSignal(report) ?? "SIGNUNKN"
        session.exceptionType = MachStrings.exceptionName(exception, signal: signalName)
        session.exceptionSubtype = MachStrings.codeString(type: exception, codes: codes) ?? ""
        session.exceptionCodes = MachStrings.codesHex(codes)
        if let task = IvarAccess.uint32(report, "_task") {
            session.vmInfo = MachStrings.vmInfo(task: task, type: exception, codes: codes)
        }
        var threadNum = Int(IvarAccess.int32(report, "_crashedThreadNumber") ?? 0)
        if exception == EXC_BAD_ACCESS, session.realCrashedNumber != -1 {
            threadNum = session.realCrashedNumber
        }
        session.threadNum = UInt64(threadNum)

        if let names = IvarAccess.array(report, "_threadNames") as? [String], names.indices.contains(threadNum) {
            session.threadName = names[threadNum]
        } else if let infos = IvarAccess.array(report, "_threadInfos") as? [[String: Any]], infos.indices.contains(threadNum) {
            let info = infos[threadNum]
            session.threadName = (info["name"] as? String) ?? (info["queue"] as? String)
        }

        if IvarAccess.exists(report, "_threadState"),
           let flavor = IvarAccess.int32(report, "_threadStateFlavor"),
           let count = IvarAccess.uint32(report, "_threadStateCount") {
            let offsetIvar = class_getInstanceVariable(object_getClass(report), "_threadState")
            if let offsetIvar {
                let base = Unmanaged.passUnretained(report).toOpaque().advanced(by: ivar_getOffset(offsetIvar))
                session.registers = MachStrings.registers(from: base.assumingMemoryBound(to: UInt32.self), count: Int(count), flavor: flavor)
            }
        }

        session.swiftError = readSwiftError(report)
        session.stackSymbols = readStack(report, threadNum: threadNum)
        session.images = readImages(report)
        session.version = IvarAccess.string(report, "_short_vers")
            ?? IvarAccess.string(report, "_bundle_vers")
            ?? ((IvarAccess.dictionary(report, "_bundle_info")?["CFBundleVersion"] as? String) ?? "")
        session.terminationReason = IvarAccess.string(report, "_terminator_reason") ?? ""
        session.collected = true
    }

    static func generate(_ report: AnyObject) {
        let session = CrashSessionStore.session(for: report)
        if session.hasBeenHandled || session.didGenerate { return }
        if !session.collected { collect(report) }
        guard session.collected else { return }
        session.didGenerate = true

        let dateString = CR4StringFromTime(session.crashTime, .pretty) ?? ""
        let device = "\(CR4DeviceName() ?? "Unknown"), iOS \(CR4DeviceVersion() ?? "Unknown")"
        var log = "Date: \(dateString)\nProcess: \(session.processName)\nBundle id: \(session.bundleID)\nDevice: \(device)\n"
        if !session.version.isEmpty { log += "Bundle version: \(session.version)\n" }
        let culprit = CR4DetermineCulprit(session.stackSymbols) ?? "Unknown"
        var crashReason = ""
        if let swift = session.swiftError, !swift.isEmpty {
            crashReason = swift
        } else if !session.terminationReason.isEmpty {
            crashReason = session.terminationReason
        } else if !session.exceptionSubtype.isEmpty {
            crashReason = "\(session.exceptionType): \(session.exceptionSubtype)"
            if let vm = session.vmInfo, !vm.isEmpty {
                crashReason += " (\(vm))"
            }
        } else if !session.exceptionType.isEmpty {
            crashReason = session.exceptionType
        }

        log += "\nException type: \(session.exceptionType)\n"
        if !session.exceptionSubtype.isEmpty {
            log += "Exception subtype: \(session.exceptionSubtype)\n"
        }
        log += "Exception codes: \(session.exceptionCodes)\nCulprit: \(culprit)\n"
        if !crashReason.isEmpty {
            log += "Reason: \(crashReason)\n"
        }
        if let swift = session.swiftError { log += "Swift Error Message: \(swift)\n" }
        if let vm = session.vmInfo { log += "VM Protection: \(vm)\n" }
        if !session.terminationReason.isEmpty { log += "Termination Reason: \(session.terminationReason)\n" }
        log += "\nTriggered by thread: \(session.threadNum)\nThread name: \(session.threadName ?? "")\nCall stack:\n\(session.stackSymbols.joined(separator: "\n"))\n\nRegister values:\n"

        let regs = session.registers
        var i = 0
        while i < regs.count {
            var row = String(format: "%@: %p", regs[i].0, regs[i].1)
            if i + 1 < regs.count {
                row = row.padding(toLength: 24, withPad: " ", startingAt: 0)
                row += String(format: "%@: %p", regs[i + 1].0, regs[i + 1].1)
            }
            if i + 2 < regs.count {
                row = row.padding(toLength: 48, withPad: " ", startingAt: 0)
                row += String(format: "%@: %p", regs[i + 2].0, regs[i + 2].1)
            }
            log += row + "\n"
            i += 3
        }

        if !session.images.isEmpty {
            log += "\nLoaded images:\n"
            for (idx, img) in session.images.enumerated() {
                log += "\(idx): \(img)\n"
            }
        }

        var extra: [String: String] = [
            "ProcessName": session.processName,
            "ProcessBundleID": session.bundleID,
            "Culprit": culprit,
            "ExceptionType": session.exceptionType
        ]
        if !crashReason.isEmpty {
            extra["NSExceptionReason"] = crashReason
            extra["CrashReason"] = crashReason
        }
        if let updated = CR4AddInfoToLog(log, extra) {
            log = updated
        }

        let filenameDate = CR4StringFromTime(session.crashTime, .filename) ?? "unknown"
        let filename = "\(session.processName)@\(filenameDate)"
        _ = CR4WriteLog(log, filename)
        session.stackSymbols = []
        session.registers = []
        session.images = []
    }

    private static func isNonFatal(_ report: AnyObject) -> Bool {
        let sel = NSSelectorFromString("isExceptionNonFatal")
        if report.responds(to: sel) {
            return CR4BoolMessage(report, sel)
        }
        return false
    }

    private static func decodeSignal(_ report: AnyObject) -> String? {
        for name in ["decode_signal", "signalName"] {
            let sel = NSSelectorFromString(name)
            if report.responds(to: sel), let value = report.perform(sel)?.takeUnretainedValue() as? String {
                return value
            }
        }
        return nil
    }

    private static func readImages(_ report: AnyObject) -> [String] {
        let arrays = [IvarAccess.array(report, "_taskImages"), IvarAccess.array(report, "_binaryImages"), IvarAccess.array(report, "_usedImages")]
        for images in arrays {
            guard let images else { continue }
            var names: [String] = []
            for img in images {
                if let dict = img as? [String: Any] {
                    names.append((dict["ExecutablePath"] as? String) ?? (dict["name"] as? String) ?? (dict["path"] as? String) ?? "")
                } else if let obj = img as? NSObject {
                    let sel = NSSelectorFromString("symbolInfo")
                    if obj.responds(to: sel), let info = obj.perform(sel)?.takeUnretainedValue() {
                        names.append((info.value(forKey: "path") as? String) ?? "")
                    }
                }
            }
            if !names.isEmpty { return names }
        }
        return []
    }

    private static func readStack(_ report: AnyObject, threadNum: Int) -> [String] {
        guard IvarAccess.exists(report, "_threadInfos"), IvarAccess.exists(report, "_usedImages"),
              let threadInfos = IvarAccess.array(report, "_threadInfos") as? [[String: Any]],
              let taskImages = IvarAccess.array(report, "_usedImages") as? [[String: Any]] else {
            return []
        }
        let idx = threadNum < threadInfos.count ? threadNum : 0
        guard threadInfos.indices.contains(idx), let frames = threadInfos[idx]["frames"] as? [[String: Any]] else { return [] }
        var symbols: [String] = []
        for (i, frame) in frames.enumerated() {
            let imageIndex = frame["imageIndex"] as? Int ?? 0
            guard taskImages.indices.contains(imageIndex) else { continue }
            let image = taskImages[imageIndex]
            let imgBase = (image["base"] as? UInt) ?? 0
            let imgOffset = (frame["imageOffset"] as? UInt) ?? 0
            let symName = (frame["symbol"] as? String) ?? ""
            let name = (image["name"] as? String) ?? ""
            var line = "\(i) ".padding(toLength: 4, withPad: " ", startingAt: 0)
            line += name.padding(toLength: 36, withPad: " ", startingAt: 0)
            line += String(format: "0x%016llx ", UInt64(imgBase + imgOffset))
            line += String(format: "0x%llx + 0x%llx", UInt64(imgBase), UInt64(imgOffset))
            line = line.padding(toLength: 90, withPad: " ", startingAt: 0)
            line += "// \(symName)"
            symbols.append(line)
        }
        return symbols
    }

    private static func readSwiftError(_ report: AnyObject) -> String? {
        guard let task = IvarAccess.uint32(report, "_task") else { return nil }
        var libPath: NSString?
        let staticAddr = CR4FindSymbolInTask(task, "_gCRAnnotations", "libswiftCore.dylib", &libPath)
        guard staticAddr != 0, let libPath = libPath as String? else { return nil }
        let images = IvarAccess.array(report, "_binaryImages") ?? IvarAccess.array(report, "_taskImages") ?? IvarAccess.array(report, "_usedImages")
        var annotationAddr: UInt64 = 0
        if let images {
            for img in images {
                var path: String?
                var start: UInt64 = 0
                if let dict = img as? [String: Any] {
                    path = (dict["ExecutablePath"] as? String) ?? (dict["path"] as? String)
                    start = (dict["StartAddress"] as? UInt64) ?? (dict["base"] as? UInt64) ?? 0
                }
                if path == libPath {
                    annotationAddr = UInt64(staticAddr) + start
                    break
                }
            }
        }
        guard annotationAddr != 0 else { return nil }
        var msgAddr: UInt64 = 0
        // crashreporter_annotations_t.message 在 version 之后
        CR4RRead(task, annotationAddr + 8, &msgAddr, 8)
        guard msgAddr != 0 else { return nil }
        return CR4ReadStringAtTaskAddress(report, msgAddr) as String?
    }

    private static func threadNumber(task: mach_port_t, thread: mach_port_t) -> UInt64 {
        let desired = threadID(thread)
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(MemoryLayout<thread_act_t>.size) * vm_size_t(count))
        }
        for i in 0..<Int(count) {
            if threadID(threads[i]) == desired { return UInt64(i) }
        }
        return 0
    }

    private static func threadID(_ thread: mach_port_t) -> UInt64 {
        var info = thread_identifier_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), rebound, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.thread_id : 0
    }
}
