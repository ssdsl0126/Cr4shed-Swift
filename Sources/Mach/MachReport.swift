import Foundation
import Darwin

enum MachReport {
    static func sharedInit(_ report: AnyObject,
                           task: mach_port_t,
                           thread: mach_port_t,
                           exceptionType: Int32) {
        let session = CrashSessionStore.session(for: report)
        session.crashTime = time(nil)
        var candidateID: UInt64 = 0
        var candidateCount = 0
        var scanComplete = false
        var far: UInt64 = 0
        session.hasBeenHandled = task != 0 && CR4ProcessHasBeenHandled(task)
        // 目标进程已经由专用异常处理器保存，避免为随后到达的重复系统报告再次扫描。
        if session.hasBeenHandled { return }
        if task != 0 {
            var pid: Int32 = 0
            if pid_for_task(task, &pid) == KERN_SUCCESS {
                session.processID = pid
            }
            // 系统稍后会回收资源异常的 task port；必须在报告初始化阶段保存内存快照。
            // 已有编码时仅处理内存类；初始化阶段缺少编码时保守抓取，稍后确认类型再取舍。
            let earlyCodes = readExceptionCodes(report)
            if exceptionType == EXC_RESOURCE,
               CR4ShouldLogJetsam(),
               (earlyCodes.isEmpty || isMemoryResource(type: exceptionType, codes: earlyCodes)),
               let snapshot = usableMemorySnapshot(task: task, timing: "exception initialization") {
                session.memoryInfo = snapshot
            }
            // task 端口稍后可能失效，线程上下文必须在初始化阶段立即读取。
            var threads: thread_act_array_t?
            var threadCount: mach_msg_type_number_t = 0
            if task_threads(task, &threads, &threadCount) == KERN_SUCCESS, let threads {
                scanComplete = true
                defer {
                    for i in 0..<Int(threadCount) {
                        mach_port_deallocate(mach_task_self_, threads[i])
                    }
                    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads),
                                  vm_size_t(MemoryLayout<thread_act_t>.size) * vm_size_t(threadCount))
                }
                for i in 0..<Int(threadCount) {
                    var state = arm_exception_state64_t()
                    let expectedCount = mach_msg_type_number_t(MemoryLayout<arm_exception_state64_t>.size / MemoryLayout<UInt32>.size)
                    var count = expectedCount
                    let kr = withUnsafeMutablePointer(to: &state) { ptr in
                        ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                            thread_get_state(threads[i], ARM_EXCEPTION_STATE64, rebound, &count)
                        }
                    }
                    guard kr == KERN_SUCCESS, count == expectedCount else {
                        scanComplete = false
                        continue
                    }
                    if isMemoryAbort(UInt64(state.__esr)) {
                        candidateCount += 1
                        if candidateCount == 1 {
                            candidateID = threadID(threads[i])
                            far = state.__far
                        }
                    }
                }
            }
        }
        if !scanComplete || candidateCount != 1 {
            candidateID = 0
            far = 0
        }
        if IvarAccess.exists(report, "_crashingAddress"), let addr = IvarAccess.uint64(report, "_crashingAddress") {
            session.far = addr
        } else {
            session.far = far
        }
        // 只保存稳定的线程 ID；task_threads 的枚举下标不等于报告内的线程下标。
        session.realCrashedThreadID = candidateID != 0 ? candidateID : (thread != 0 ? threadID(thread) : 0)
    }

    static func collect(_ report: AnyObject) {
        let session = CrashSessionStore.session(for: report)
        if session.hasBeenHandled || session.collected || session.ignored { return }

        var procName = IvarAccess.string(report, "_procName") ?? ""
        if procName.isEmpty {
            let sel = NSSelectorFromString("procName")
            if report.responds(to: sel), let name = report.perform(sel)?.takeUnretainedValue() as? String {
                procName = name
            }
        }
        if procName.isEmpty, let path = IvarAccess.string(report, "_procPath") {
            procName = (path as NSString).lastPathComponent
        }
        session.processName = procName.isEmpty ? "Unknown" : procName

        var sig = IvarAccess.int32(report, "_signal") ?? 0
        let excType = IvarAccess.int32(report, "_exceptionType") ?? 0
        var codes = readExceptionCodes(report)
        let decodedSignal = decodeSignal(report)
        if sig == 0, let decodedSignal, let decoded = signalFromName(decodedSignal) {
            sig = decoded
        }
        if sig == 0, let code = codes.first {
            if excType == EXC_CRASH {
                // XNU 的 EXC_CRASH 包装把信号放在 bit 24...31，低 20 位属于原始 code。
                let raw = UInt64(bitPattern: code)
                let packedSignal = Int32((raw >> 24) & 0xff)
                if raw >> 32 == 0, packedSignal > 0, packedSignal < NSIG {
                    sig = packedSignal
                }
            } else if excType == EXC_SOFTWARE, code == 0x10003, codes.count > 1 {
                // EXC_SOFT_SIGNAL 的第二个 code 才是信号；不猜测 corpse 通知的编码。
                let rawSignal = codes[1]
                if rawSignal > 0, rawSignal < Int64(NSIG) { sig = Int32(rawSignal) }
            } else if excType == EXC_SOFTWARE, code == 0x10002 {
                sig = SIGABRT
            }
        }

        if sig == 0 && excType == 0 { return }
        session.terminationReason = IvarAccess.string(report, "_terminator_reason") ?? ""
        if shouldIgnoreExtensionCheckInTimeout(sig: sig,
                                               excType: excType,
                                               terminationReason: session.terminationReason) {
            session.ignored = true
            return
        }
        // 到达这里的是系统报告对象，SIGKILL 本身不足以判断该报告应被丢弃。
        if CR4IsProcessBlacklisted(session.processName) { return }
        let mapped = MachStrings.fromSignal(sig)
        let exception = excType != 0 ? excType : mapped.0
        session.isResourceEvent = exception == EXC_RESOURCE
        let isMemoryResourceEvent = isMemoryResource(type: exception, codes: codes)
        // 初始化阶段若尚无异常编码，会保守抓取；确认不是内存资源事件后立即丢弃该快照。
        if session.isResourceEvent, !isMemoryResourceEvent { session.memoryInfo = nil }
        // Mach 路径也可能收到内存资源事件，与专用 Jetsam 路径共用记录开关。
        if isMemoryResourceEvent, !CR4ShouldLogJetsam() {
            session.ignored = true
            return
        }
        // 优先保留系统类型及完整 codes，仅在两者都缺失时使用信号映射补充。
        if excType == 0, codes.isEmpty, mapped.0 != 0 {
            codes = [mapped.1, mapped.1 == 0x10003 ? Int64(sig) : 0]
        }

        if isNonFatal(report, sig: sig, excType: excType) { return }

        if isMemoryResourceEvent, session.memoryInfo == nil,
           let task = IvarAccess.uint32(report, "_task"),
           let snapshot = CR4TaskMemoryDescription(task) {
            session.memoryInfo = "Memory snapshot timing: report assembly\n\(snapshot)"
        }
        session.bundleID = IvarAccess.string(report, "_bundle_id") ?? ""
        let signalName = sig == 0 ? "" : (MachStrings.signalName(sig) ?? decodedSignal ?? "SIGNUNKN")
        session.exceptionType = MachStrings.exceptionName(exception, signal: signalName)
        session.exceptionSubtype = MachStrings.codeString(type: exception, codes: codes) ?? ""
        // 由系统判定是否可能是 PAC 失败，保留其原始地址、转换后的地址和提示，避免自行猜测位掩码。
        var usesSystemDecodedFaultAddress = false
        if excType == EXC_BAD_ACCESS, codes.count >= 2,
           let details = CR4DecodeExceptionDetails(report),
           details["type"] as? String == "EXC_BAD_ACCESS",
           let subtype = details["subtype"] as? String,
           !subtype.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.exceptionSubtype = subtype
            // 系统用箭头表示原始地址已经去除 PAC 或标签；此时不能再用原始 code 推断 VM 区域。
            usesSystemDecodedFaultAddress = subtype.contains("->")
        }
        session.exceptionCodes = MachStrings.codesHex(codes)
        if !usesSystemDecodedFaultAddress, let task = IvarAccess.uint32(report, "_task") {
            session.vmInfo = MachStrings.vmInfo(task: task, type: exception, codes: codes)
        }
        let threadInfos = IvarAccess.array(report, "_threadInfos") as? [[String: Any]] ?? []
        let images = IvarAccess.array(report, "_usedImages") as? [[String: Any]] ?? []
        let systemThreadNum = Int(IvarAccess.int32(report, "_crashedThreadNumber") ?? 0)
        var threadNum = systemThreadNum
        var recoveredRegisters: [(String, UInt64)]?
        let matchingIndices = threadInfos.indices.filter {
            session.realCrashedThreadID != 0 && (threadInfos[$0]["id"] as? UInt64) == session.realCrashedThreadID
        }
        session.realCrashedNumber = matchingIndices.count == 1 ? matchingIndices[0] : -1
        if exception == EXC_BAD_ACCESS, session.realCrashedNumber != systemThreadNum,
           threadInfos.indices.contains(session.realCrashedNumber), codes.count > 1,
           let state = threadInfos[session.realCrashedNumber]["threadState"] as? [String: Any],
           let esr = stateValue("esr", in: state), isMemoryAbort(esr), esr & 0x400 == 0,
           stateValue("far", in: state) == UInt64(bitPattern: codes[1]),
           let registers = matchingThreadRegisters(threadInfos[session.realCrashedNumber], images: images) {
            threadNum = session.realCrashedNumber
            recoveredRegisters = registers
            session.threadRecoveryNote = "System reported thread: \(systemThreadNum)\nThread selection: matched thread ID \(session.realCrashedThreadID) and exception fault address"
        } else if exception == EXC_CRASH, sig == SIGSEGV || sig == SIGBUS,
                  let recovered = recoverSignalFaultThread(threadInfos, images: images, systemThread: systemThreadNum) {
            threadNum = recovered.index
            recoveredRegisters = recovered.registers
            session.threadRecoveryNote = "System reported thread: \(systemThreadNum)\nThread selection: inferred original fault context; "
                + String(format: "thread ID %llu, ESR 0x%llx, FAR 0x%llx", recovered.id, recovered.esr, recovered.far)
        }
        session.threadNum = threadNum >= 0 ? UInt64(threadNum) : 0

        if let names = IvarAccess.array(report, "_threadNames") as? [String], names.indices.contains(threadNum) {
            session.threadName = names[threadNum]
        } else if threadInfos.indices.contains(threadNum) {
            let info = threadInfos[threadNum]
            session.threadName = (info["name"] as? String) ?? (info["queue"] as? String)
        }

        if let recoveredRegisters {
            // 恢复后的栈和寄存器必须来自同一个报告线程，不能继续使用系统默认线程的 _threadState。
            session.registers = recoveredRegisters
        } else if IvarAccess.exists(report, "_threadState"),
           let flavor = IvarAccess.int32(report, "_threadStateFlavor"),
           let count = IvarAccess.uint32(report, "_threadStateCount") {
            let offsetIvar = class_getInstanceVariable(object_getClass(report), "_threadState")
            if let offsetIvar {
                let base = Unmanaged.passUnretained(report).toOpaque().advanced(by: ivar_getOffset(offsetIvar))
                session.registers = MachStrings.registers(from: base.assumingMemoryBound(to: UInt32.self), count: Int(count), flavor: flavor)
            }
        }

        // 资源事件不是 Swift fatalError，不为它构建远程进程符号化器。
        if !session.isResourceEvent { session.swiftError = readSwiftError(report) }
        session.stackSymbols = readStack(report, threadNum: threadNum)
        session.lastExceptionStackSymbols = readLastExceptionStack(report)
        session.images = readImages(report)
        session.version = IvarAccess.string(report, "_short_vers")
            ?? IvarAccess.string(report, "_bundle_vers")
            ?? ((IvarAccess.dictionary(report, "_bundle_info")?["CFBundleVersion"] as? String) ?? "")
        session.collected = true
    }

    static func generate(_ report: AnyObject) {
        let session = CrashSessionStore.session(for: report)
        if session.hasBeenHandled || session.didGenerate || session.ignored { return }
        if !session.collected { collect(report) }
        guard session.collected, !session.ignored else { return }
        session.didGenerate = true

        let dateString = CR4StringFromTime(session.crashTime, .pretty) ?? ""
        let device = "\(CR4DeviceName() ?? "Unknown"), iOS \(CR4DeviceVersion() ?? "Unknown")"
        var log = "Date: \(dateString)\nProcess: \(session.processName)\n"
        if session.processID > 0 { log += "Process id: \(session.processID)\n" }
        log += "Bundle id: \(session.bundleID)\nDevice: \(device)\n"
        if !session.version.isEmpty { log += "Bundle version: \(session.version)\n" }
        // 超限时的线程快照无法证明分配来源，避免扫描插件列表并误判责任模块。
        var culprit = session.isResourceEvent ? "Unknown" : (CR4DetermineCulprit(session.stackSymbols) ?? "Unknown")
        if !session.isResourceEvent, culprit == "Unknown", !session.lastExceptionStackSymbols.isEmpty {
            // NSException 最终通常终止在 abort；主栈无法定位时，改用原始抛出栈识别插件。
            culprit = CR4DetermineCulprit(session.lastExceptionStackSymbols) ?? "Unknown"
        }
        var crashReason = ""
        if let swift = session.swiftError, !swift.isEmpty {
            crashReason = swift
        } else if !session.terminationReason.isEmpty {
            crashReason = session.terminationReason
        } else if session.exceptionType.contains("SIGABRT") {
            crashReason = "\(session.exceptionType): Process called abort() or assertion failed"
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
        if let memoryInfo = session.memoryInfo { log += memoryInfo }
        if let swift = session.swiftError { log += "Swift Error Message: \(swift)\n" }
        if let vm = session.vmInfo { log += "VM Protection: \(vm)\n" }
        if !session.terminationReason.isEmpty { log += "Termination Reason: \(session.terminationReason)\n" }
        if let note = session.threadRecoveryNote { log += "\n\(note)\n" }
        log += "\nTriggered by thread: \(session.threadNum)\nThread name: \(session.threadName ?? "")\nCall stack:\n\(session.stackSymbols.joined(separator: "\n"))\n"
        if !session.lastExceptionStackSymbols.isEmpty {
            // 抛出异常的栈独立展示，不替换最终终止线程的栈及寄存器。
            log += "\nLast Exception Backtrace:\n\(session.lastExceptionStackSymbols.joined(separator: "\n"))\n"
        }
        log += "\nRegister values:\n"

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
        if session.processID > 0 { extra["ProcessID"] = String(session.processID) }
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
        session.lastExceptionStackSymbols = []
        session.registers = []
        session.images = []
    }

    private static func isNonFatal(_ report: AnyObject, sig: Int32, excType: Int32) -> Bool {
        let sel = NSSelectorFromString("isExceptionNonFatal")
        // 资源、守卫和 corpse 报告以系统的非致命判定为准，不能被附带信号覆盖。
        if excType == EXC_RESOURCE || excType == EXC_GUARD || excType == EXC_CORPSE_NOTIFY {
            return report.responds(to: sel) ? CR4BoolMessage(report, sel) : false
        }
        if sig == SIGABRT || sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGTRAP || sig == SIGFPE {
            return false
        }
        if excType == EXC_CRASH || excType == EXC_BAD_ACCESS || excType == EXC_BAD_INSTRUCTION || excType == EXC_ARITHMETIC || excType == EXC_BREAKPOINT || excType == EXC_SOFTWARE {
            return false
        }
        if report.responds(to: sel) {
            return CR4BoolMessage(report, sel)
        }
        return false
    }

    private static func shouldIgnoreExtensionCheckInTimeout(sig: Int32,
                                                            excType: Int32,
                                                            terminationReason: String) -> Bool {
        guard !CR4PrefsRecordExtensionCheckInTimeouts(),
              sig == SIGKILL,
              excType == EXC_CRASH else { return false }
        let normalized = terminationReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.caseInsensitiveCompare("extension check-in timeout") == .orderedSame
    }

    private static func readExceptionCodes(_ report: AnyObject) -> [Int64] {
        guard let count = IvarAccess.uint32(report, "_exceptionCodeCount"),
              count > 0, count <= 16,
              let pointerValue = IvarAccess.value(report, "_exceptionCode", as: UnsafePointer<Int64>?.self),
              let pointer = pointerValue else { return [] }
        return (0..<Int(count)).map { pointer[$0] }
    }

    private static func isMemoryResource(type: Int32, codes: [Int64]) -> Bool {
        guard type == EXC_RESOURCE, let code = codes.first else { return false }
        return (UInt64(bitPattern: code) >> 61) & 0x7 == 3
    }

    private static func usableMemorySnapshot(task: mach_port_t, timing: String) -> String? {
        guard let snapshot = CR4TaskMemoryDescription(task),
              !snapshot.hasPrefix("Memory snapshot: unavailable") else { return nil }
        return "Memory snapshot timing: \(timing)\n\(snapshot)"
    }

    private static func signalFromName(_ name: String) -> Int32? {
        switch name {
        case "SIGSEGV": return SIGSEGV
        case "SIGBUS": return SIGBUS
        case "SIGABRT": return SIGABRT
        case "SIGTRAP": return SIGTRAP
        case "SIGILL": return SIGILL
        case "SIGFPE": return SIGFPE
        case "SIGSYS": return SIGSYS
        case "SIGPIPE": return SIGPIPE
        case "SIGKILL": return SIGKILL
        default: return nil
        }
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
        guard threadInfos.indices.contains(threadNum), let frames = threadInfos[threadNum]["frames"] as? [Any] else { return [] }
        return formatStack(frames, images: taskImages)
    }

    private struct RecoveredThread {
        let index: Int
        let id: UInt64
        let esr: UInt64
        let far: UInt64
        let registers: [(String, UInt64)]
    }

    private static func isMemoryAbort(_ esr: UInt64) -> Bool {
        // AArch64 用户态的指令访问异常或数据访问异常，不把任意非零 ESR 当作崩溃。
        let exceptionClass = (esr >> 26) & 0x3f
        return exceptionClass == 0x20 || exceptionClass == 0x24
    }

    private static func stateValue(_ name: String, in state: [String: Any]) -> UInt64? {
        (state[name] as? [String: Any])?["value"] as? UInt64
    }

    private static func matchingThreadRegisters(_ info: [String: Any], images: [[String: Any]]) -> [(String, UInt64)]? {
        guard let state = info["threadState"] as? [String: Any],
              state["flavor"] as? String == "ARM_THREAD_STATE64",
              let pc = stateValue("pc", in: state), pc != 0,
              let lr = stateValue("lr", in: state),
              let cpsr = stateValue("cpsr", in: state),
              let x = state["x"] as? [[String: Any]], x.count == 29,
              let frames = info["frames"] as? [[String: Any]], let first = frames.first,
              let imageIndex = first["imageIndex"] as? Int, images.indices.contains(imageIndex),
              let base = images[imageIndex]["base"] as? UInt64,
              let offset = first["imageOffset"] as? UInt64 else { return nil }
        let (framePC, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, framePC == pc else { return nil }
        var registers: [(String, UInt64)] = [("PC", pc), ("LR", lr), ("CPSR", cpsr)]
        for (index, value) in x.enumerated() {
            guard let raw = value["value"] as? UInt64 else { return nil }
            registers.append(("x\(index)", raw))
        }
        return registers
    }

    private static func recoverSignalFaultThread(_ infos: [[String: Any]], images: [[String: Any]], systemThread: Int) -> RecoveredThread? {
        // 仅覆盖已观察到的模式：系统选中停在 Mach 消息等待中的线程，另一线程仍保留原始故障现场。
        guard infos.indices.contains(systemThread),
              let systemState = infos[systemThread]["threadState"] as? [String: Any],
              let systemESR = stateValue("esr", in: systemState), (systemESR >> 26) & 0x3f == 0x15,
              let frames = infos[systemThread]["frames"] as? [[String: Any]], let first = frames.first,
              let symbol = first["symbol"] as? String, symbol == "mach_msg2_trap" || symbol == "mach_msg_trap",
              let imageIndex = first["imageIndex"] as? Int, images.indices.contains(imageIndex),
              images[imageIndex]["name"] as? String == "libsystem_kernel.dylib" else { return nil }

        var candidate: Int?
        for (index, info) in infos.enumerated() {
            // 状态缺失时无法排除另一个候选；多个候选也不按顺序或插件名猜测。
            guard let state = info["threadState"] as? [String: Any],
                  state["flavor"] as? String == "ARM_THREAD_STATE64",
                  let esr = stateValue("esr", in: state) else { return nil }
            if isMemoryAbort(esr) {
                guard candidate == nil else { return nil }
                candidate = index
            }
        }
        guard let index = candidate, index != systemThread,
              let id = infos[index]["id"] as? UInt64, id != 0,
              infos.filter({ ($0["id"] as? UInt64) == id }).count == 1,
              let state = infos[index]["threadState"] as? [String: Any],
              let esr = stateValue("esr", in: state), esr & 0x400 == 0,
              let far = stateValue("far", in: state),
              let registers = matchingThreadRegisters(infos[index], images: images) else { return nil }
        // ESR 可能保留历史异常，因此结果明确标为推断，同时保留系统线程号及原始异常类型/codes。
        return RecoveredThread(index: index, id: id, esr: esr, far: far, registers: registers)
    }

    private static func readLastExceptionStack(_ report: AnyObject) -> [String] {
        // 读取系统已提取和符号化的抛出栈，覆盖专用 NSException handler 被过滤或覆盖的情况。
        guard let frames = IvarAccess.array(report, "_lastExceptionBacktrace"), !frames.isEmpty else { return [] }
        let images = IvarAccess.array(report, "_usedImages") as? [[String: Any]] ?? []
        return formatStack(frames, images: images)
    }

    private static func formatStack(_ frames: [Any], images: [[String: Any]]) -> [String] {
        var symbols: [String] = []
        for (i, value) in frames.enumerated() {
            guard let frame = value as? [String: Any] else { continue }
            let image: [String: Any]?
            if let imageIndex = frame["imageIndex"] as? Int, images.indices.contains(imageIndex) {
                image = images[imageIndex]
            } else {
                image = nil
            }
            let symName = (frame["symbol"] as? String) ?? ""
            let name = (image?["name"] as? String) ?? "Unknown"
            var line = "\(i) ".padding(toLength: 4, withPad: " ", startingAt: 0)
            line += name.padding(toLength: 36, withPad: " ", startingAt: 0)
            if let imgBase = image?["base"] as? UInt64, let imgOffset = frame["imageOffset"] as? UInt64 {
                let (address, overflow) = imgBase.addingReportingOverflow(imgOffset)
                if !overflow { line += String(format: "0x%016llx ", address) }
                line += String(format: "0x%llx + 0x%llx", imgBase, imgOffset)
            } else if let imgOffset = frame["imageOffset"] as? UInt64 {
                // 未能匹配镜像时只保留相对偏移，不能当作绝对地址或误归到第一个镜像。
                line += String(format: "image offset 0x%llx", imgOffset)
            }
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

    private static func threadID(_ thread: mach_port_t) -> UInt64 {
        var info = thread_identifier_info_data_t()
        let expectedCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
        var count = expectedCount
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), rebound, &count)
            }
        }
        return kr == KERN_SUCCESS && count == expectedCount ? info.thread_id : 0
    }
}
