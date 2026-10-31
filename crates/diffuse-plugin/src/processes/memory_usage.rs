//! Resident memory of a plugin process, per platform.
//!
//! Ported from `Engine/Sources/PluginRuntime/Processes/MemoryUsage.swift`.
//! Every platform branch the Swift file had is implemented; the `else` branch
//! (any other OS) keeps returning `None`, exactly as Swift did.

pub enum PluginProcessMemory {}

impl PluginProcessMemory {
    pub fn resident_bytes(process_id: i32) -> Option<u64> {
        #[cfg(target_os = "macos")]
        {
            macos_resident_bytes(process_id)
        }
        #[cfg(target_os = "linux")]
        {
            return linux_resident_bytes(process_id);
        }
        #[cfg(target_os = "windows")]
        {
            return windows_resident_bytes(process_id);
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
        {
            let _ = process_id;
            None
        }
    }
}

/// `proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)` returning
/// `pti_resident_size`.
#[cfg(target_os = "macos")]
fn macos_resident_bytes(process_id: i32) -> Option<u64> {
    // SAFETY: `proc_taskinfo` is a plain C struct of integers and pointers, so
    // an all-zero bit pattern is a valid value for it.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>();
    // SAFETY: `info` is a valid, correctly sized `proc_taskinfo` and `size`
    // matches the buffer the kernel writes.
    let written = unsafe {
        libc::proc_pidinfo(
            process_id,
            libc::PROC_PIDTASKINFO,
            0,
            (&raw mut info).cast(),
            size as i32,
        )
    };
    if written as usize != size {
        return None;
    }
    Some(info.pti_resident_size)
}

/// `/proc/<pid>/statm`, whose second field is resident pages.
#[cfg(target_os = "linux")]
fn linux_resident_bytes(process_id: i32) -> Option<u64> {
    let contents = std::fs::read_to_string(format!("/proc/{process_id}/statm")).ok()?;
    let resident: u64 = contents.split(' ').nth(1)?.parse().ok()?;
    // SAFETY: `sysconf` takes a constant selector and returns a `c_long`.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if page_size > 0 {
        Some(resident * page_size as u64)
    } else {
        None
    }
}

/// `PROCESS_MEMORY_COUNTERS` from `WinSDK`; the layout is fixed by the platform
/// header (`psapi.h`).
#[cfg(target_os = "windows")]
#[repr(C)]
struct ProcessMemoryCounters {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
}

/// `K32GetProcessMemoryInfo` in `kernel32` (Windows 7 and later); the value is
/// `WorkingSetSize`.
#[cfg(target_os = "windows")]
fn windows_resident_bytes(process_id: i32) -> Option<u64> {
    use std::ffi::c_void;

    const PROCESS_QUERY_INFORMATION: u32 = 0x0400;
    const PROCESS_VM_READ: u32 = 0x0010;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenProcess(access: u32, inherit: i32, process_id: u32) -> *mut c_void;
        fn CloseHandle(handle: *mut c_void) -> i32;
        fn K32GetProcessMemoryInfo(
            process: *mut c_void,
            counters: *mut ProcessMemoryCounters,
            size: u32,
        ) -> i32;
    }

    // SAFETY: the handle is closed on every path and the counters structure is
    // zero-initialised with `cb` set to its own size, which is the contract both
    // Win32 calls document.
    unsafe {
        let handle = OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            0,
            process_id as u32,
        );
        if handle.is_null() {
            return None;
        }
        let mut counters: ProcessMemoryCounters = std::mem::zeroed();
        counters.cb = std::mem::size_of::<ProcessMemoryCounters>() as u32;
        let ok = K32GetProcessMemoryInfo(handle, &raw mut counters, counters.cb);
        CloseHandle(handle);
        if ok == 0 {
            return None;
        }
        Some(counters.working_set_size as u64)
    }
}
