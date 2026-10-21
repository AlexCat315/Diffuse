private import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

enum PluginProcessMemory {
    static func residentBytes(processID: Int32) -> UInt64? {
        #if os(macOS)
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(processID, PROC_PIDTASKINFO, 0, &info, Int32(size)) == size else { return nil }
        return info.pti_resident_size
        #elseif os(Linux)
        guard let contents = try? String(contentsOfFile: "/proc/\(processID)/statm", encoding: .utf8),
              let resident = contents.split(separator: " ").dropFirst().first.flatMap({ UInt64($0) }) else { return nil }
        let pageSize = sysconf(Int32(_SC_PAGESIZE))
        return pageSize > 0 ? resident * UInt64(pageSize) : nil
        #elseif os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ), false, DWORD(processID)) else { return nil }
        defer { CloseHandle(handle) }
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        guard K32GetProcessMemoryInfo(handle, &counters, counters.cb) else { return nil }
        return UInt64(counters.WorkingSetSize)
        #else
        return nil
        #endif
    }
}
