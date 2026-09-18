import Foundation
import Darwin

enum MachStrings {
    static func exceptionName(_ exception: Int32, signal: String) -> String {
        let type: String
        switch exception {
        case EXC_BAD_ACCESS: type = "EXC_BAD_ACCESS"
        case EXC_BAD_INSTRUCTION: type = "EXC_BAD_INSTRUCTION"
        case EXC_ARITHMETIC: type = "EXC_ARITHMETIC"
        case EXC_EMULATION: type = "EXC_EMULATION"
        case EXC_SOFTWARE: type = "EXC_SOFTWARE"
        case EXC_BREAKPOINT: type = "EXC_BREAKPOINT"
        case EXC_SYSCALL: type = "EXC_SYSCALL"
        case EXC_MACH_SYSCALL: type = "EXC_MACH_SYSCALL"
        case EXC_RPC_ALERT: type = "EXC_RPC_ALERT"
        case EXC_CRASH: type = "EXC_CRASH"
        case EXC_RESOURCE: type = "EXC_RESOURCE"
        case EXC_GUARD: type = "EXC_GUARD"
        case EXC_CORPSE_NOTIFY: type = "EXC_CORPSE_NOTIFY"
        default: type = "EXC_UNKNOWN"
        }
        return "\(type) (\(signal))"
    }

    static func codeString(type: Int32, codes: [Int64]) -> String? {
        guard let code = codes.first else { return nil }
        let subcode = codes.count > 1 ? codes[1] : 0
        var name: String?
        var hasSub = false
        if type == EXC_BAD_ACCESS {
            hasSub = true
            if code == Int64(KERN_INVALID_ADDRESS) { name = "KERN_INVALID_ADDRESS" }
            else if code == Int64(KERN_PROTECTION_FAILURE) { name = "KERN_PROTECTION_FAILURE" }
            else { name = String(format: "0x%llx", code) }
        } else if type == EXC_SOFTWARE {
            if code == 0x10000 { name = "EXC_UNIX_BAD_SYSCALL" }
            else if code == 0x10001 { name = "EXC_UNIX_BAD_PIPE" }
            else if code == 0x10002 { name = "EXC_UNIX_ABORT" }
            else if code == 0x10003 { name = "EXC_SOFT_SIGNAL" }
            else { name = String(format: "0x%llx", code) }
        } else {
            name = String(format: "0x%llx", code)
            hasSub = (codes.count > 1 && subcode != 0)
        }
        guard let name else { return nil }
        return hasSub ? String(format: "%@: 0x%llx", name, UInt64(bitPattern: subcode)) : name
    }

    static func codesHex(_ codes: [Int64]) -> String {
        codes.map { String(format: "0x%016llx", $0) }.joined(separator: ", ")
    }

    static func fromSignal(_ sig: Int32) -> (Int32, Int64) {
        switch sig {
        case SIGSEGV: return (EXC_BAD_ACCESS, Int64(KERN_INVALID_ADDRESS))
        case SIGBUS: return (EXC_BAD_ACCESS, Int64(KERN_PROTECTION_FAILURE))
        case SIGILL: return (EXC_BAD_INSTRUCTION, 0)
        case SIGFPE: return (EXC_ARITHMETIC, 0)
        case SIGSYS: return (EXC_SOFTWARE, 0x10000)
        case SIGPIPE: return (EXC_SOFTWARE, 0x10001)
        case SIGABRT: return (EXC_SOFTWARE, 0x10002)
        case SIGKILL: return (EXC_SOFTWARE, 0x10003)
        case SIGTRAP: return (EXC_BREAKPOINT, 0)
        default: return (0, 0)
        }
    }

    static func vmInfo(task: mach_port_t, type: Int32, codes: [Int64]) -> String? {
        guard type == EXC_BAD_ACCESS, codes.count > 1 else { return nil }
        let addr = vm_address_t(bitPattern: Int(truncatingIfNeeded: codes[1]))
        if codes[0] == Int64(KERN_INVALID_ADDRESS) {
            return String(format: "%p is not in any region.", codes[1])
        }
        var address = addr
        var size: vm_size_t = 0
        var info = vm_region_basic_info_data_64_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        var obj: mach_port_t = 0
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: Int(count)) { rebound in
                vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64, rebound, &count, &obj)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var rwx = ["-", "-", "-"]
        if info.protection & VM_PROT_READ != 0 { rwx[0] = "r" }
        if info.protection & VM_PROT_WRITE != 0 { rwx[1] = "w" }
        if info.protection & VM_PROT_EXECUTE != 0 { rwx[2] = "x" }
        return rwx.joined()
    }

    static func registers(from blob: UnsafePointer<UInt32>, count: Int, flavor: Int32) -> [(String, UInt64)] {
        var parsed = CR4ParsedThreadState()
        let size = count * MemoryLayout<UInt32>.size
        guard CR4ParseThreadState(blob, size, flavor, &parsed) else { return [] }
        var regs: [(String, UInt64)] = [
            ("PC", parsed.pc),
            ("LR", parsed.lr),
            ("CPSR", UInt64(parsed.cpsr))
        ]
        withUnsafeBytes(of: parsed.x) { raw in
            let arr = raw.bindMemory(to: UInt64.self)
            for i in 0..<min(29, arr.count) {
                regs.append(("x\(i)", arr[i]))
            }
        }
        return regs
    }
}
