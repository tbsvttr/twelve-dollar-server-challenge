#![allow(dead_code, non_camel_case_types)]

use std::ffi::{c_int, c_long, c_void};

pub type rlim_t = u64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct rlimit {
    pub rlim_cur: rlim_t,
    pub rlim_max: rlim_t,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct timespec {
    pub tv_sec: i64,
    pub tv_nsec: c_long,
}

pub const SIGPIPE: c_int = 13;
pub const SIG_IGN: usize = 1;
pub const CLOCK_REALTIME: c_int = 0;

#[cfg(target_os = "linux")]
pub const RLIMIT_NOFILE: c_int = 7;
#[cfg(not(target_os = "linux"))]
pub const RLIMIT_NOFILE: c_int = 8;

unsafe extern "C" {
    pub fn signal(sig: c_int, handler: usize) -> usize;
    pub fn getrlimit(resource: c_int, rlim: *mut rlimit) -> c_int;
    pub fn setrlimit(resource: c_int, rlim: *const rlimit) -> c_int;
    pub fn clock_gettime(clk_id: c_int, tp: *mut timespec) -> c_int;
    pub fn memchr(s: *const c_void, c: c_int, n: usize) -> *const c_void;
    pub fn mlock(addr: *const c_void, len: usize) -> c_int;
    pub fn mmap(
        addr: *mut c_void,
        len: usize,
        prot: c_int,
        flags: c_int,
        fd: c_int,
        offset: i64,
    ) -> *mut c_void;
    pub fn munmap(addr: *mut c_void, len: usize) -> c_int;
    pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
    pub fn setsockopt(
        socket: c_int,
        level: c_int,
        name: c_int,
        value: *const c_void,
        option_len: u32,
    ) -> c_int;
    pub fn bind(socket: c_int, address: *const c_void, address_len: u32) -> c_int;
    pub fn listen(socket: c_int, backlog: c_int) -> c_int;
    pub fn close(fd: c_int) -> c_int;
    pub fn syscall(num: c_long, ...) -> c_long;
}

#[inline]
pub fn find_byte(needle: u8, haystack: &[u8]) -> Option<usize> {
    if haystack.is_empty() {
        return None;
    }
    let ptr = unsafe {
        memchr(
            haystack.as_ptr().cast(),
            c_int::from(needle),
            haystack.len(),
        )
    };
    if ptr.is_null() {
        None
    } else {
        Some((ptr as usize) - (haystack.as_ptr() as usize))
    }
}

#[inline(always)]
pub fn word_has_json_special(w: u64) -> u64 {
    const ONES: u64 = 0x0101_0101_0101_0101;
    const HIGH: u64 = 0x8080_8080_8080_8080;
    let ctl = w.wrapping_sub(ONES * 0x20) & !w;
    let q = w ^ (ONES * (b'"' as u64));
    let q = q.wrapping_sub(ONES) & !q;
    let b = w ^ (ONES * (b'\\' as u64));
    let b = b.wrapping_sub(ONES) & !b;
    (ctl | q | b) & HIGH
}

#[inline]
pub fn find_json_special(haystack: &[u8]) -> Option<usize> {
    let mut i = 0usize;
    while i + 8 <= haystack.len() {
        let w = u64::from_le_bytes(haystack[i..i + 8].try_into().unwrap());
        if word_has_json_special(w) != 0 {
            break;
        }
        i += 8;
    }
    while i < haystack.len() {
        let b = haystack[i];
        if b == b'"' || b == b'\\' || b < 0x20 {
            return Some(i);
        }
        i += 1;
    }
    None
}
