mod app;
mod db;
mod http;
mod json;
mod jwt;
mod sys;

use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use crate::app::App;
use crate::db::Db;
use crate::sys::{RLIMIT_NOFILE, SIGPIPE, SIG_IGN, getrlimit, rlimit, setrlimit, signal};

fn main() {
    unsafe {
        signal(SIGPIPE, SIG_IGN);
    }
    let slots = raise_nofile_limit();

    let db_path = env::var("SQLITE_PATH")
        .or_else(|_| env::var("DB_PATH"))
        .unwrap_or_else(|_| "./seed/feed.db".to_string());
    let jwt_secret = env::var("JWT_SECRET").unwrap_or_else(|_| "dev-secret".to_string());
    let host_str = env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(80);

    let ip: IpAddr = host_str.parse().unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let bind_addr = SocketAddr::new(ip, port);

    let db = Db::open(&db_path).expect("failed to open SQLite database");
    let app = App::new(db, jwt_secret.as_bytes());

    #[cfg(target_os = "linux")]
    linux_uring::run_server(bind_addr, slots, app);

    #[cfg(not(target_os = "linux"))]
    {
        let _ = slots;
        portable_loop::run_server(bind_addr, app);
    }
}

fn raise_nofile_limit() -> u32 {
    unsafe {
        let mut rlim = rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if getrlimit(RLIMIT_NOFILE, &mut rlim) == 0 {
            if rlim.rlim_cur < rlim.rlim_max {
                rlim.rlim_cur = rlim.rlim_max;
                let _ = setrlimit(RLIMIT_NOFILE, &rlim);
                let _ = getrlimit(RLIMIT_NOFILE, &mut rlim);
            }
            return (rlim.rlim_cur as u64).min(1 << 20).max(1024) as u32;
        }
        65535
    }
}

/* =========================================================================
 * Raw Linux Multi-Ring io_uring Transport Engine (Zero External Crates)
 * ========================================================================= */
#[cfg(target_os = "linux")]
#[allow(dead_code)]
mod linux_uring {
    use std::collections::VecDeque;
    use std::ffi::{c_int, c_long, c_uint, c_ulong, c_void};
    use std::io;
    use std::net::SocketAddr;
    use std::ptr;
    use std::sync::atomic::{AtomicU16, AtomicU32, Ordering};
    use std::time::{Duration, Instant};

    use crate::app::App;
    use crate::http::{ParseState, parse_http_request, write_static_json_response};
    use crate::sys::{bind, close, listen, mmap, munmap, setsockopt, socket, syscall, timespec};

    const SYS_IO_URING_SETUP: c_long = 425;
    const SYS_IO_URING_ENTER: c_long = 426;
    const SYS_IO_URING_REGISTER: c_long = 427;

    const IORING_OFF_SQ_RING: i64 = 0;
    const IORING_OFF_CQ_RING: i64 = 0x8000000;
    const IORING_OFF_SQES: i64 = 0x10000000;

    const IORING_SETUP_CQSIZE: u32 = 1 << 3;
    const IORING_SETUP_CLAMP: u32 = 1 << 4;
    const IORING_SETUP_SUBMIT_ALL: u32 = 1 << 7;
    const IORING_SETUP_TASKRUN_FLAG: u32 = 1 << 9;
    const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12;
    const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13;

    const IORING_FEAT_SINGLE_MMAP: u32 = 1 << 0;

    const IORING_ENTER_GETEVENTS: u32 = 1 << 0;
    const IORING_ENTER_EXT_ARG: u32 = 1 << 3;

    const IOSQE_FIXED_FILE: u8 = 1 << 0;
    const IOSQE_IO_HARDLINK: u8 = 1 << 3;
    const IOSQE_BUFFER_SELECT: u8 = 1 << 5;

    const IORING_OP_ACCEPT: u8 = 13;
    const IORING_OP_CLOSE: u8 = 19;
    const IORING_OP_SEND: u8 = 26;
    const IORING_OP_RECV: u8 = 27;
    const IORING_OP_SHUTDOWN: u8 = 34;

    const IORING_RECV_MULTISHOT: u16 = 1 << 1;
    const IORING_FILE_INDEX_ALLOC: u32 = u32::MAX;

    const IORING_CQE_F_BUFFER: u32 = 1 << 0;
    const IORING_CQE_F_MORE: u32 = 1 << 1;

    const IORING_REGISTER_FILES2: c_uint = 13;
    const IORING_RSRC_REGISTER_SPARSE: u32 = 1 << 0;
    const IORING_REGISTER_PBUF_RING: c_uint = 22;

    const PROT_READ: c_int = 1;
    const PROT_WRITE: c_int = 2;
    const MAP_SHARED: c_int = 0x01;
    const MAP_PRIVATE: c_int = 0x02;
    const MAP_ANONYMOUS: c_int = 0x20;
    const MAP_POPULATE: c_int = 0x8000;
    const MAP_FAILED: *mut c_void = !0usize as *mut c_void;

    const AF_INET: c_int = 2;
    const AF_INET6: c_int = 10;
    const SOCK_STREAM: c_int = 1;
    const SOCK_NONBLOCK: c_int = 0o4000;
    const SOCK_CLOEXEC: c_int = 0o2000000;
    const IPPROTO_TCP: c_int = 6;
    const SOL_SOCKET: c_int = 1;
    const SO_REUSEADDR: c_int = 2;
    const SO_REUSEPORT: c_int = 15;
    const TCP_NODELAY: c_int = 1;
    const SHUT_RDWR: u32 = 2;
    const MSG_DONTWAIT: u32 = 0x40;
    const MSG_NOSIGNAL: u32 = 0x4000;

    const EAGAIN: i32 = 11;
    const ENOMEM: i32 = 12;
    const EINVAL: i32 = 22;
    const ENFILE: i32 = 23;
    const ENOBUFS: i32 = 105;

    const LISTENERS: usize = 8;
    const ACCEPT_DEPTH: u32 = 512;
    const MAX_RINGS: usize = 16;
    const SQ_ENTRIES: u32 = 4096;
    const CQ_ENTRIES: u32 = 65536;

    const PBUF_GROUP: u16 = 0;
    const PBUF_COUNT: u16 = 1024;
    const PBUF_MASK: u16 = PBUF_COUNT - 1;
    const PBUF_STRIDE: usize = 2048;

    const READS_PER_PASS: usize = 16384;
    const ANSWERS_PER_PASS: u32 = 2048;
    const WAIT_MIN: u32 = 256;
    const WAIT_NS: i64 = 1_000_000;
    const POOL_MAX: usize = 2048;
    const OUT_CAP: usize = 8192;

    const OP_ACCEPT: u64 = 1;
    const OP_RECV: u64 = 2;
    const OP_SEND: u64 = 3;
    const OP_SHUTDOWN: u64 = 4;
    const OP_CLOSE: u64 = 5;
    const OP_READ: u64 = 6;

    #[inline]
    fn pack_ud(op: u64, ring: usize, generation: u16, slot: u32) -> u64 {
        (op << 56) | ((ring as u64) << 48) | ((generation as u64) << 32) | (slot as u64)
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct io_sqring_offsets {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        flags: u32,
        dropped: u32,
        array: u32,
        resv1: u32,
        user_addr: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct io_cqring_offsets {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        overflow: u32,
        cqes: u32,
        flags: u32,
        resv1: u32,
        user_addr: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct io_uring_params {
        sq_entries: u32,
        cq_entries: u32,
        flags: u32,
        sq_thread_cpu: u32,
        sq_thread_idle: u32,
        features: u32,
        wq_fd: u32,
        resv: [u32; 3],
        sq_off: io_sqring_offsets,
        cq_off: io_cqring_offsets,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct io_uring_sqe {
        opcode: u8,
        flags: u8,
        ioprio: u16,
        fd: i32,
        off: u64,
        addr: u64,
        len: u32,
        op_flags: u32,
        user_data: u64,
        buf_group: u16,
        personality: u16,
        file_index: u32,
        addr3: u64,
        pad2: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct io_uring_cqe {
        user_data: u64,
        res: i32,
        flags: u32,
    }

    #[repr(C)]
    struct io_uring_rsrc_register {
        nr: u32,
        flags: u32,
        resv2: u64,
        data: u64,
        tags: u64,
    }

    #[repr(C)]
    struct io_uring_getevents_arg {
        sigmask: u64,
        sigmask_sz: u32,
        min_wait_usec: u32,
        ts: u64,
    }

    #[repr(C)]
    struct BufRingEntry {
        addr: u64,
        len: u32,
        bid: u16,
        resv: u16,
    }

    #[repr(C)]
    struct KernelBufReg {
        ring_addr: u64,
        ring_entries: u32,
        bgid: u16,
        flags: u16,
        resv: [u64; 3],
    }

    struct RawRing {
        ring_fd: c_int,
        sq_khead: *const AtomicU32,
        sq_ktail: *const AtomicU32,
        sq_mask: u32,
        sq_entries: u32,
        sqes: *mut io_uring_sqe,
        sq_tail_local: u32,
        cq_khead: *const AtomicU32,
        cq_ktail: *const AtomicU32,
        cq_mask: u32,
        cqes: *const io_uring_cqe,
    }

    impl RawRing {
        fn create(sq_entries: u32, cq_entries: u32, direct_slots: u32) -> io::Result<Self> {
            let mut params = io_uring_params::default();
            let mut cq = cq_entries;
            let fd = loop {
                params = io_uring_params {
                    sq_entries,
                    cq_entries: cq,
                    flags: IORING_SETUP_CQSIZE
                        | IORING_SETUP_CLAMP
                        | IORING_SETUP_SUBMIT_ALL
                        | IORING_SETUP_SINGLE_ISSUER
                        | IORING_SETUP_DEFER_TASKRUN
                        | IORING_SETUP_TASKRUN_FLAG,
                    ..io_uring_params::default()
                };

                let rc = unsafe {
                    syscall(
                        SYS_IO_URING_SETUP,
                        c_ulong::from(sq_entries),
                        &mut params as *mut io_uring_params,
                    )
                };
                if rc >= 0 {
                    break rc;
                }
                let err = io::Error::last_os_error();
                if err.raw_os_error() == Some(ENOMEM) && cq > 4096 {
                    cq /= 2;
                    continue;
                }
                return Err(err);
            };
            let ring_fd = fd as c_int;

            /* Register sparse direct descriptor table of size `direct_slots` */
            let reg = io_uring_rsrc_register {
                nr: direct_slots,
                flags: IORING_RSRC_REGISTER_SPARSE,
                resv2: 0,
                data: 0,
                tags: 0,
            };
            let reg_rc = unsafe {
                syscall(
                    SYS_IO_URING_REGISTER,
                    ring_fd,
                    IORING_REGISTER_FILES2,
                    &reg as *const io_uring_rsrc_register,
                    std::mem::size_of::<io_uring_rsrc_register>(),
                )
            };
            if reg_rc < 0 {
                let err = io::Error::last_os_error();
                unsafe { close(ring_fd) };
                return Err(err);
            }

            let sq_ring_sz =
                (params.sq_off.array as usize) + (params.sq_entries as usize) * 4;
            let cq_ring_sz = (params.cq_off.cqes as usize)
                + (params.cq_entries as usize) * std::mem::size_of::<io_uring_cqe>();
            let sqes_sz = (params.sq_entries as usize) * std::mem::size_of::<io_uring_sqe>();
            let single_mmap = (params.features & IORING_FEAT_SINGLE_MMAP) != 0;
            let map_sz = if single_mmap {
                sq_ring_sz.max(cq_ring_sz)
            } else {
                sq_ring_sz
            };

            let sq_ptr = unsafe {
                mmap(
                    ptr::null_mut(),
                    map_sz,
                    PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_POPULATE,
                    ring_fd,
                    IORING_OFF_SQ_RING,
                )
            };
            if sq_ptr == MAP_FAILED {
                unsafe { close(ring_fd) };
                return Err(io::Error::last_os_error());
            }

            let cq_ptr = if single_mmap {
                sq_ptr
            } else {
                let ptr = unsafe {
                    mmap(
                        ptr::null_mut(),
                        cq_ring_sz,
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_POPULATE,
                        ring_fd,
                        IORING_OFF_CQ_RING,
                    )
                };
                if ptr == MAP_FAILED {
                    unsafe {
                        munmap(sq_ptr, map_sz);
                        close(ring_fd);
                    }
                    return Err(io::Error::last_os_error());
                }
                ptr
            };

            let sqes_ptr = unsafe {
                mmap(
                    ptr::null_mut(),
                    sqes_sz,
                    PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_POPULATE,
                    ring_fd,
                    IORING_OFF_SQES,
                )
            };
            if sqes_ptr == MAP_FAILED {
                unsafe { close(ring_fd) };
                return Err(io::Error::last_os_error());
            }

            let sq_base = sq_ptr as *mut u8;
            let cq_base = cq_ptr as *mut u8;

            let sq_array = unsafe { sq_base.add(params.sq_off.array as usize) as *mut u32 };
            for i in 0..params.sq_entries {
                unsafe { *sq_array.add(i as usize) = i };
            }

            Ok(Self {
                ring_fd,
                sq_khead: unsafe { sq_base.add(params.sq_off.head as usize) as *const AtomicU32 },
                sq_ktail: unsafe { sq_base.add(params.sq_off.tail as usize) as *const AtomicU32 },
                sq_mask: unsafe { *(sq_base.add(params.sq_off.ring_mask as usize) as *const u32) },
                sq_entries: params.sq_entries,
                sqes: sqes_ptr as *mut io_uring_sqe,
                sq_tail_local: 0,
                cq_khead: unsafe { cq_base.add(params.cq_off.head as usize) as *const AtomicU32 },
                cq_ktail: unsafe { cq_base.add(params.cq_off.tail as usize) as *const AtomicU32 },
                cq_mask: unsafe { *(cq_base.add(params.cq_off.ring_mask as usize) as *const u32) },
                cqes: unsafe { cq_base.add(params.cq_off.cqes as usize) as *const io_uring_cqe },
            })
        }

        #[inline]
        fn sq_room(&self) -> usize {
            let khead = unsafe { (*self.sq_khead).load(Ordering::Acquire) };
            let used = self.sq_tail_local.wrapping_sub(khead);
            self.sq_entries.saturating_sub(used) as usize
        }

        #[inline]
        fn flush_sq(&mut self) -> u32 {
            let ktail = unsafe { (*self.sq_ktail).load(Ordering::Relaxed) };
            let to_submit = self.sq_tail_local.wrapping_sub(ktail);
            if to_submit > 0 {
                unsafe {
                    (*self.sq_ktail).store(self.sq_tail_local, Ordering::Release);
                }
            }
            to_submit
        }

        #[inline]
        fn push_sqe(&mut self, sqe: &io_uring_sqe, room: usize) {
            let mut tries = 0;
            while self.sq_room() < room {
                let to_submit = self.flush_sq();
                unsafe {
                    let _ = syscall(
                        SYS_IO_URING_ENTER,
                        self.ring_fd,
                        to_submit,
                        0u32,
                        IORING_ENTER_GETEVENTS,
                        ptr::null::<c_void>(),
                        0usize,
                    );
                }
                tries += 1;
                if tries >= 1000 {
                    return;
                }
            }
            let idx = (self.sq_tail_local & self.sq_mask) as usize;
            unsafe {
                *self.sqes.add(idx) = *sqe;
            }
            self.sq_tail_local = self.sq_tail_local.wrapping_add(1);
        }

        #[inline]
        fn pop_cqe(&mut self) -> Option<io_uring_cqe> {
            let head = unsafe { (*self.cq_khead).load(Ordering::Relaxed) };
            let tail = unsafe { (*self.cq_ktail).load(Ordering::Acquire) };
            if head == tail {
                return None;
            }
            let idx = (head & self.cq_mask) as usize;
            let cqe = unsafe { *self.cqes.add(idx) };
            unsafe {
                (*self.cq_khead).store(head.wrapping_add(1), Ordering::Release);
            }
            Some(cqe)
        }

        #[inline]
        fn enter_nowait(&mut self) {
            let to_submit = self.flush_sq();
            unsafe {
                let _ = syscall(
                    SYS_IO_URING_ENTER,
                    self.ring_fd,
                    to_submit,
                    0u32,
                    IORING_ENTER_GETEVENTS,
                    ptr::null::<c_void>(),
                    0usize,
                );
            }
        }

        #[inline]
        fn enter_if_pending(&mut self) {
            let to_submit = self.flush_sq();
            if to_submit > 0 {
                unsafe {
                    let _ = syscall(
                        SYS_IO_URING_ENTER,
                        self.ring_fd,
                        to_submit,
                        0u32,
                        IORING_ENTER_GETEVENTS,
                        ptr::null::<c_void>(),
                        0usize,
                    );
                }
            }
        }

        #[inline]
        fn enter_wait_timeout(&mut self, min_complete: u32, wait_ns: i64) {
            let to_submit = self.flush_sq();
            let ts = timespec {
                tv_sec: 0,
                tv_nsec: wait_ns,
            };
            let arg = io_uring_getevents_arg {
                sigmask: 0,
                sigmask_sz: 0,
                min_wait_usec: 0,
                ts: (&ts as *const timespec) as u64,
            };
            unsafe {
                let _ = syscall(
                    SYS_IO_URING_ENTER,
                    self.ring_fd,
                    to_submit,
                    min_complete,
                    IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG,
                    &arg as *const io_uring_getevents_arg,
                    std::mem::size_of::<io_uring_getevents_arg>(),
                );
            }
        }
    }

    struct ProvidedBufPool {
        ring_mem: *mut u8,
        ring_bytes: usize,
        data_mem: *mut u8,
        data_bytes: usize,
        tail: u16,
    }

    impl ProvidedBufPool {
        fn create(ring_fd: c_int) -> io::Result<Self> {
            let ring_bytes = (PBUF_COUNT as usize) * std::mem::size_of::<BufRingEntry>();
            let data_bytes = (PBUF_COUNT as usize) * PBUF_STRIDE;

            let ring_mem = unsafe {
                mmap(
                    ptr::null_mut(),
                    ring_bytes,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE,
                    -1,
                    0,
                )
            };
            if ring_mem == MAP_FAILED {
                return Err(io::Error::last_os_error());
            }

            let data_mem = unsafe {
                mmap(
                    ptr::null_mut(),
                    data_bytes,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE,
                    -1,
                    0,
                )
            };
            if data_mem == MAP_FAILED {
                unsafe {
                    munmap(ring_mem, ring_bytes);
                }
                return Err(io::Error::last_os_error());
            }

            let mut reg = KernelBufReg {
                ring_addr: ring_mem as u64,
                ring_entries: u32::from(PBUF_COUNT),
                bgid: PBUF_GROUP,
                flags: 0,
                resv: [0; 3],
            };

            let mut rc = unsafe {
                syscall(
                    SYS_IO_URING_REGISTER,
                    ring_fd,
                    IORING_REGISTER_PBUF_RING,
                    &reg as *const KernelBufReg,
                    1usize,
                )
            };
            if rc < 0 && io::Error::last_os_error().raw_os_error() == Some(EINVAL) {
                reg.resv[0] = 1;
                rc = unsafe {
                    syscall(
                        SYS_IO_URING_REGISTER,
                        ring_fd,
                        IORING_REGISTER_PBUF_RING,
                        &reg as *const KernelBufReg,
                        1usize,
                    )
                };
            }
            if rc < 0 {
                let err = io::Error::last_os_error();
                unsafe {
                    munmap(data_mem, data_bytes);
                    munmap(ring_mem, ring_bytes);
                }
                return Err(err);
            }

            let mut pool = Self {
                ring_mem: ring_mem.cast(),
                ring_bytes,
                data_mem: data_mem.cast(),
                data_bytes,
                tail: 0,
            };
            for bid in 0..PBUF_COUNT {
                pool.add(bid);
            }
            pool.publish();
            Ok(pool)
        }

        #[inline]
        fn slice(&self, bid: u16, len: usize) -> &[u8] {
            let offset = (bid as usize) * PBUF_STRIDE;
            unsafe { std::slice::from_raw_parts(self.data_mem.add(offset), len) }
        }

        #[inline]
        fn add(&mut self, bid: u16) {
            let idx = (self.tail & PBUF_MASK) as usize;
            let entry = unsafe { &mut *(self.ring_mem as *mut BufRingEntry).add(idx) };
            entry.addr = (self.data_mem as u64) + (bid as u64) * (PBUF_STRIDE as u64);
            entry.len = PBUF_STRIDE as u32;
            entry.bid = bid;
            entry.resv = 0;
            self.tail = self.tail.wrapping_add(1);
        }

        #[inline]
        fn publish(&self) {
            let tail_atomic = unsafe { &*(self.ring_mem.add(14) as *const AtomicU16) };
            tail_atomic.store(self.tail, Ordering::Release);
        }
    }

    impl Drop for ProvidedBufPool {
        fn drop(&mut self) {
            unsafe {
                munmap(self.data_mem.cast(), self.data_bytes);
                munmap(self.ring_mem.cast(), self.ring_bytes);
            }
        }
    }

    #[derive(Default)]
    struct PoolBuf(Option<Box<Vec<u8>>>);

    impl PoolBuf {
        #[inline]
        fn len(&self) -> usize {
            self.0.as_ref().map_or(0, |v| v.len())
        }
        #[inline]
        fn is_empty(&self) -> bool {
            self.len() == 0
        }
        #[inline]
        fn bytes(&self) -> &[u8] {
            self.0.as_deref().map_or(&[][..], |v| &v[..])
        }
        #[inline]
        fn get(&mut self, pool: &mut Vec<Box<Vec<u8>>>) -> &mut Vec<u8> {
            self.0.get_or_insert_with(|| take_buf(pool))
        }
    }

    #[inline]
    fn take_buf(pool: &mut Vec<Box<Vec<u8>>>) -> Box<Vec<u8>> {
        pool.pop()
            .unwrap_or_else(|| Box::new(Vec::with_capacity(OUT_CAP)))
    }

    #[inline]
    fn give_buf(pool: &mut Vec<Box<Vec<u8>>>, b: PoolBuf) {
        if let Some(mut v) = b.0 {
            if pool.len() < POOL_MAX && v.capacity() <= 4 * OUT_CAP {
                v.clear();
                pool.push(v);
            }
        }
    }

    #[derive(Default)]
    struct ConnSlot {
        generation: u16,
        open: bool,
        close_after: bool,
        held: bool,
        eof: bool,
        closing: bool,
        sending: bool,
        queued: bool,
        recving: bool,
        ready: bool,
        in_batch: bool,
        answered: bool,
        batch_mark: u32,
        sent: u32,
        out: PoolBuf,
        wire: PoolBuf,
        partial: PoolBuf,
    }

    const _: () = assert!(std::mem::size_of::<ConnSlot>() == 48);

    struct RingState {
        ring: RawRing,
        bufs: ProvidedBufPool,
        conns: Vec<ConnSlot>,
        accepting: bool,
        accepts: [u32; LISTENERS],
        depth: u32,
        full: bool,
        open: u32,
        margin: u32,
        reads: u32,
    }

    impl RingState {
        fn new(slots: u32) -> io::Result<Self> {
            let ring = RawRing::create(SQ_ENTRIES, CQ_ENTRIES, slots)?;
            let bufs = ProvidedBufPool::create(ring.ring_fd)?;
            let conns = (0..slots).map(|_| ConnSlot::default()).collect();
            let depth = (slots / 16).clamp(LISTENERS as u32, ACCEPT_DEPTH)
                / (LISTENERS as u32)
                * (LISTENERS as u32);
            let margin = (slots / 8)
                .clamp(depth + 1, 2 * ACCEPT_DEPTH)
                .min(slots / 4);
            Ok(Self {
                ring,
                bufs,
                conns,
                accepting: false,
                accepts: [0; LISTENERS],
                depth,
                full: false,
                open: 0,
                margin,
                reads: 0,
            })
        }
    }

    #[inline]
    fn arm_recv(ring: &mut RawRing, ri: usize, slot: u32, generation: u16) {
        let sqe = io_uring_sqe {
            opcode: IORING_OP_RECV,
            flags: IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT,
            ioprio: IORING_RECV_MULTISHOT,
            fd: slot as i32,
            off: 0,
            addr: 0,
            len: 0,
            op_flags: 0,
            user_data: pack_ud(OP_RECV, ri, generation, slot),
            buf_group: PBUF_GROUP,
            personality: 0,
            file_index: 0,
            addr3: 0,
            pad2: 0,
        };
        ring.push_sqe(&sqe, 1);
    }

    #[inline]
    fn arm_read(ring: &mut RawRing, ri: usize, slot: u32, generation: u16) {
        let sqe = io_uring_sqe {
            opcode: IORING_OP_RECV,
            flags: IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT,
            ioprio: 0,
            fd: slot as i32,
            off: 0,
            addr: 0,
            len: 0,
            op_flags: MSG_DONTWAIT,
            user_data: pack_ud(OP_READ, ri, generation, slot),
            buf_group: PBUF_GROUP,
            personality: 0,
            file_index: 0,
            addr3: 0,
            pad2: 0,
        };
        ring.push_sqe(&sqe, 1);
    }

    #[inline]
    fn arm_send(ring: &mut RawRing, ri: usize, slot: u32, c: &ConnSlot) {
        let rest = &c.wire.bytes()[c.sent as usize..];
        let sqe = io_uring_sqe {
            opcode: IORING_OP_SEND,
            flags: IOSQE_FIXED_FILE,
            ioprio: 0,
            fd: slot as i32,
            off: 0,
            addr: rest.as_ptr() as u64,
            len: rest.len() as u32,
            op_flags: MSG_NOSIGNAL,
            user_data: pack_ud(OP_SEND, ri, c.generation, slot),
            buf_group: 0,
            personality: 0,
            file_index: 0,
            addr3: 0,
            pad2: 0,
        };
        ring.push_sqe(&sqe, 1);
    }

    #[inline]
    fn arm_close(ring: &mut RawRing, ri: usize, slot: u32, c: &mut ConnSlot) {
        c.closing = true;
        let s_sqe = io_uring_sqe {
            opcode: IORING_OP_SHUTDOWN,
            flags: IOSQE_FIXED_FILE | IOSQE_IO_HARDLINK,
            ioprio: 0,
            fd: slot as i32,
            off: 0,
            addr: 0,
            len: SHUT_RDWR,
            op_flags: 0,
            user_data: pack_ud(OP_SHUTDOWN, ri, c.generation, slot),
            buf_group: 0,
            personality: 0,
            file_index: 0,
            addr3: 0,
            pad2: 0,
        };
        let cl_sqe = io_uring_sqe {
            opcode: IORING_OP_CLOSE,
            flags: 0,
            ioprio: 0,
            fd: 0,
            off: 0,
            addr: 0,
            len: 0,
            op_flags: 0,
            user_data: pack_ud(OP_CLOSE, ri, c.generation, slot),
            buf_group: 0,
            personality: 0,
            file_index: slot + 1,
            addr3: 0,
            pad2: 0,
        };
        ring.push_sqe(&s_sqe, 2);
        ring.push_sqe(&cl_sqe, 1);
    }

    fn fill_accepts(
        ring: &mut RawRing,
        ri: usize,
        listen_fds: &[c_int; LISTENERS],
        accepts: &mut [u32; LISTENERS],
        depth: u32,
    ) {
        let per_listener = depth / (LISTENERS as u32);
        for (li, &fd) in listen_fds.iter().enumerate() {
            while accepts[li] < per_listener {
                let sqe = io_uring_sqe {
                    opcode: IORING_OP_ACCEPT,
                    flags: 0,
                    ioprio: 0,
                    fd,
                    off: 0,
                    addr: 0,
                    len: 0,
                    op_flags: 0,
                    user_data: pack_ud(OP_ACCEPT, ri, 0, li as u32),
                    buf_group: 0,
                    personality: 0,
                    file_index: IORING_FILE_INDEX_ALLOC,
                    addr3: 0,
                    pad2: 0,
                };
                ring.push_sqe(&sqe, 1);
                accepts[li] += 1;
            }
        }
    }

    fn arm_accept(r: &mut RingState, ri: usize, listen_fds: &[c_int; LISTENERS]) {
        r.accepting = true;
        fill_accepts(&mut r.ring, ri, listen_fds, &mut r.accepts, r.depth);
    }

    #[inline]
    fn mark_touched(touched: &mut Vec<(u8, u32)>, ri: usize, slot: u32, c: &mut ConnSlot) {
        if !c.in_batch {
            c.in_batch = true;
            c.batch_mark = c.out.len() as u32;
            touched.push((ri as u8, slot));
        }
    }

    #[inline]
    fn queue_read(rq: &mut VecDeque<(u8, u32, u16)>, ri: usize, slot: u32, c: &mut ConnSlot) {
        if !c.queued {
            c.queued = true;
            rq.push_back((ri as u8, slot, c.generation));
        }
    }

    #[inline]
    fn finish_conn(touched: &mut Vec<(u8, u32)>, ri: usize, slot: u32, c: &mut ConnSlot) {
        if c.held || c.ready {
            c.eof = true;
        } else {
            c.close_after = true;
            mark_touched(touched, ri, slot, c);
        }
    }

    #[inline]
    fn stash_bytes(c: &mut ConnSlot, data: &[u8]) {
        match &mut c.partial.0 {
            Some(v) => v.extend_from_slice(data),
            None => c.partial = PoolBuf(Some(Box::new(data.to_vec()))),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn serve_conn(
        app: &mut App,
        pool: &mut Vec<Box<Vec<u8>>>,
        touched: &mut Vec<(u8, u32)>,
        held: &mut Vec<(u8, u32, u16)>,
        writes_held: bool,
        ri: usize,
        slot: u32,
        c: &mut ConnSlot,
        data: &[u8],
    ) {
        if c.close_after {
            return;
        }
        let mut partial: Vec<u8> = c.partial.0.take().map_or_else(Vec::new, |b| *b);
        let buf: &[u8] = if partial.is_empty() {
            data
        } else {
            partial.extend_from_slice(data);
            &partial
        };
        let mut off = 0usize;
        while off < buf.len() {
            match parse_http_request(&buf[off..]) {
                ParseState::Complete(req) => {
                    if writes_held && App::is_write_request(&req) {
                        if !c.held {
                            c.held = true;
                            held.push((ri as u8, slot, c.generation));
                        }
                        break;
                    }
                    mark_touched(touched, ri, slot, c);
                    c.answered = true;
                    app.handle_request(&req, c.out.get(pool));
                    off += req.total_consumed;
                    if req.close_conn {
                        c.close_after = true;
                        break;
                    }
                }
                ParseState::Incomplete => break,
                ParseState::Invalid => {
                    mark_touched(touched, ri, slot, c);
                    c.answered = true;
                    write_static_json_response(
                        c.out.get(pool),
                        400,
                        true,
                        b"{\"error\":\"bad request\"}",
                    );
                    c.close_after = true;
                    off = buf.len();
                    break;
                }
            }
        }
        let rest = &buf[off..];
        if rest.is_empty() {
            // Nothing left over
        } else if ptr::eq(buf.as_ptr(), data.as_ptr()) {
            c.partial = PoolBuf(Some(Box::new(rest.to_vec())));
        } else {
            partial.drain(..off);
            c.partial = PoolBuf(Some(Box::new(partial)));
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[inline]
    fn on_received(
        app: &mut App,
        pool: &mut Vec<Box<Vec<u8>>>,
        touched: &mut Vec<(u8, u32)>,
        held: &mut Vec<(u8, u32, u16)>,
        ready: &mut VecDeque<(u8, u32, u16)>,
        answers_left: &mut u32,
        writes_held: bool,
        ri: usize,
        slot: u32,
        c: &mut ConnSlot,
        data: &[u8],
    ) {
        if c.close_after {
            return;
        }
        if c.held || c.ready || *answers_left == 0 {
            stash_bytes(c, data);
            if !c.held && !c.ready {
                c.ready = true;
                ready.push_back((ri as u8, slot, c.generation));
            }
        } else {
            *answers_left -= 1;
            serve_conn(app, pool, touched, held, writes_held, ri, slot, c, data);
        }
    }

    struct Server {
        rings: Vec<RingState>,
        app: App,
        listen_fds: [c_int; LISTENERS],
        slots: u32,
        pool: Vec<Box<Vec<u8>>>,
        touched: Vec<(u8, u32)>,
        held: Vec<(u8, u32, u16)>,
        rq: VecDeque<(u8, u32, u16)>,
        ready: VecDeque<(u8, u32, u16)>,
        answers_left: u32,
        writes_held: bool,
        need_ring: bool,
        spill_after: Instant,
    }

    impl Server {
        fn drain(&mut self, ri: usize) -> usize {
            let Server {
                rings,
                app,
                pool,
                touched,
                held,
                listen_fds,
                need_ring,
                rq,
                ready,
                answers_left,
                writes_held,
                ..
            } = self;
            let r = &mut rings[ri];
            let slots = r.conns.len() as u32;
            let mut n = 0usize;

            while let Some(cqe) = r.ring.pop_cqe() {
                n += 1;
                let u = cqe.user_data;
                let op = u >> 56;
                let generation = (u >> 32) as u16;
                let slot = u as u32;
                let res = cqe.res;
                let flags = cqe.flags;

                match op {
                    OP_ACCEPT => {
                        r.accepts[slot as usize] = r.accepts[slot as usize].saturating_sub(1);
                        if res >= 0 && (res as u32) < slots {
                            let c = &mut r.conns[res as usize];
                            let g = c.generation.wrapping_add(1);
                            give_buf(pool, std::mem::take(&mut c.out));
                            give_buf(pool, std::mem::take(&mut c.wire));
                            give_buf(pool, std::mem::take(&mut c.partial));
                            *c = ConnSlot {
                                generation: g,
                                open: true,
                                ..ConnSlot::default()
                            };
                            arm_recv(&mut r.ring, ri, res as u32, g);
                            r.open += 1;
                            if r.open + r.margin >= slots {
                                r.full = true;
                            }
                        } else if res == -ENFILE {
                            r.full = true;
                        }
                    }
                    OP_RECV => {
                        let bid = if (flags & IORING_CQE_F_BUFFER) != 0 {
                            Some((flags >> 16) as u16)
                        } else {
                            None
                        };
                        let c = &mut r.conns[slot as usize];
                        if c.generation != generation || !c.open || c.closing {
                            if let Some(b) = bid {
                                r.bufs.add(b);
                            }
                            continue;
                        }
                        if res > 0 {
                            if let Some(b) = bid {
                                let raw_slice = r.bufs.slice(b, res as usize);
                                let data = unsafe {
                                    std::slice::from_raw_parts(raw_slice.as_ptr(), raw_slice.len())
                                };
                                on_received(
                                    app,
                                    pool,
                                    touched,
                                    held,
                                    ready,
                                    answers_left,
                                    *writes_held,
                                    ri,
                                    slot,
                                    c,
                                    data,
                                );
                                r.bufs.add(b);
                            }
                            if (flags & IORING_CQE_F_MORE) == 0 {
                                queue_read(rq, ri, slot, c);
                            }
                        } else if res == -ENOBUFS {
                            queue_read(rq, ri, slot, c);
                        } else {
                            if let Some(b) = bid {
                                r.bufs.add(b);
                            }
                            finish_conn(touched, ri, slot, c);
                        }
                    }
                    OP_READ => {
                        r.reads = r.reads.saturating_sub(1);
                        let bid = if (flags & IORING_CQE_F_BUFFER) != 0 {
                            Some((flags >> 16) as u16)
                        } else {
                            None
                        };
                        let c = &mut r.conns[slot as usize];
                        if c.generation != generation || !c.open || c.closing {
                            if let Some(b) = bid {
                                r.bufs.add(b);
                            }
                            continue;
                        }
                        c.recving = false;
                        if res > 0 {
                            let Some(b) = bid else {
                                queue_read(rq, ri, slot, c);
                                continue;
                            };
                            let raw_slice = r.bufs.slice(b, res as usize);
                            let data = unsafe {
                                std::slice::from_raw_parts(raw_slice.as_ptr(), raw_slice.len())
                            };
                            on_received(
                                app,
                                pool,
                                touched,
                                held,
                                ready,
                                answers_left,
                                *writes_held,
                                ri,
                                slot,
                                c,
                                data,
                            );
                            r.bufs.add(b);
                            if res as usize == PBUF_STRIDE {
                                queue_read(rq, ri, slot, c);
                            } else {
                                arm_recv(&mut r.ring, ri, slot, generation);
                            }
                        } else if res == -EAGAIN {
                            arm_recv(&mut r.ring, ri, slot, generation);
                        } else if res == -ENOBUFS {
                            queue_read(rq, ri, slot, c);
                        } else {
                            if let Some(b) = bid {
                                r.bufs.add(b);
                            }
                            finish_conn(touched, ri, slot, c);
                        }
                    }
                    OP_SEND => {
                        let c = &mut r.conns[slot as usize];
                        if c.generation != generation || !c.sending {
                            continue;
                        }
                        if res < 0 {
                            c.sending = false;
                            give_buf(pool, std::mem::take(&mut c.wire));
                            give_buf(pool, std::mem::take(&mut c.out));
                            c.close_after = true;
                            mark_touched(touched, ri, slot, c);
                        } else {
                            c.sent += res as u32;
                            if (c.sent as usize) < c.wire.len() {
                                arm_send(&mut r.ring, ri, slot, c);
                            } else {
                                c.sending = false;
                                give_buf(pool, std::mem::take(&mut c.wire));
                                if !c.out.is_empty() || c.close_after {
                                    mark_touched(touched, ri, slot, c);
                                } else {
                                    give_buf(pool, std::mem::take(&mut c.out));
                                }
                            }
                        }
                    }
                    OP_CLOSE => {
                        let c = &mut r.conns[slot as usize];
                        if c.generation == generation && c.open {
                            let g = c.generation;
                            give_buf(pool, std::mem::take(&mut c.out));
                            give_buf(pool, std::mem::take(&mut c.wire));
                            give_buf(pool, std::mem::take(&mut c.partial));
                            *c = ConnSlot {
                                generation: g,
                                ..ConnSlot::default()
                            };
                            r.open = r.open.saturating_sub(1);
                        }
                        if r.full && r.open + 2 * r.margin < slots {
                            r.full = false;
                            r.accepting = true;
                        }
                    }
                    _ => {}
                }
            }
            r.bufs.publish();
            if r.accepting {
                if r.full {
                    r.accepting = false;
                    *need_ring = true;
                } else {
                    fill_accepts(&mut r.ring, ri, listen_fds, &mut r.accepts, r.depth);
                }
            }
            n
        }

        fn run_ready(&mut self) {
            let Server {
                rings,
                app,
                pool,
                touched,
                held,
                ready,
                answers_left,
                writes_held,
                ..
            } = self;
            while *answers_left > 0 {
                let Some((ri, slot, generation)) = ready.pop_front() else {
                    break;
                };
                let c = &mut rings[ri as usize].conns[slot as usize];
                if c.generation != generation || !c.open || c.closing {
                    continue;
                }
                c.ready = false;
                if c.held {
                    continue;
                }
                *answers_left -= 1;
                serve_conn(
                    app,
                    pool,
                    touched,
                    held,
                    *writes_held,
                    ri as usize,
                    slot,
                    c,
                    &[],
                );
                if c.eof && !c.held {
                    c.close_after = true;
                    mark_touched(touched, ri as usize, slot, c);
                }
            }
        }

        fn issue_reads(&mut self, budget: usize) -> usize {
            let Server { rings, rq, .. } = self;
            let mut issued = 0usize;
            for _ in 0..rq.len() {
                if issued == budget {
                    break;
                }
                let Some(e @ (ri, slot, generation)) = rq.pop_front() else {
                    break;
                };
                let r = &mut rings[ri as usize];
                let c = &mut r.conns[slot as usize];
                if c.generation != generation || !c.open || c.closing {
                    continue;
                }
                if c.recving || r.reads >= u32::from(PBUF_COUNT) {
                    rq.push_back(e);
                    continue;
                }
                c.queued = false;
                c.recving = true;
                r.reads += 1;
                issued += 1;
                arm_read(&mut r.ring, ri as usize, slot, generation);
            }
            issued
        }

        fn read_rounds(&mut self) -> usize {
            let mut n = 0usize;
            let mut budget = READS_PER_PASS;
            while budget > 0 && !self.rq.is_empty() {
                let k = self.issue_reads(budget);
                if k == 0 {
                    break;
                }
                budget -= k;
                for r in &mut self.rings {
                    r.ring.enter_if_pending();
                }
                for ri in 0..self.rings.len() {
                    n += self.drain(ri);
                }
            }
            n
        }

        fn release_held(&mut self) {
            let list = std::mem::take(&mut self.held);
            let Server {
                rings,
                app,
                pool,
                touched,
                held,
                writes_held,
                ..
            } = self;
            for &(ri, slot, generation) in &list {
                let c = &mut rings[ri as usize].conns[slot as usize];
                if c.generation == generation && c.open && !c.closing {
                    c.held = false;
                    serve_conn(
                        app,
                        pool,
                        touched,
                        held,
                        *writes_held,
                        ri as usize,
                        slot,
                        c,
                        &[],
                    );
                    if c.eof && !c.held {
                        c.close_after = true;
                        mark_touched(touched, ri as usize, slot, c);
                    }
                }
            }
        }

        fn spill(&mut self) -> bool {
            if self.rings.iter().any(|r| r.accepting) {
                return true;
            }
            if let Some(ri) = self.rings.iter().position(|r| !r.full) {
                arm_accept(&mut self.rings[ri], ri, &self.listen_fds);
                return true;
            }
            if self.rings.len() >= MAX_RINGS {
                return false;
            }
            match RingState::new(self.slots) {
                Ok(mut r) => {
                    let ri = self.rings.len();
                    arm_accept(&mut r, ri, &self.listen_fds);
                    self.rings.push(r);
                    eprintln!("ring {ri} added ({} slots each)", self.slots);
                    true
                }
                Err(e) => {
                    eprintln!("cannot add ring: {e}");
                    false
                }
            }
        }

        fn end_batch(&mut self) {
            let committed = self.app.db.commit_batch();
            self.writes_held = self.app.db.poll_checkpoint(false);

            let Server {
                rings,
                touched,
                pool,
                ..
            } = self;
            for &(ri, slot) in touched.iter() {
                let r = &mut rings[ri as usize];
                let c = &mut r.conns[slot as usize];
                if !committed && c.answered {
                    let mark = c.batch_mark as usize;
                    let out = c.out.get(pool);
                    out.truncate(mark);
                    write_static_json_response(out, 500, true, b"{\"error\":\"internal error\"}");
                    c.close_after = true;
                }
                c.in_batch = false;
                c.answered = false;
                if !c.open || c.closing || c.sending {
                    continue;
                }
                if !c.out.is_empty() {
                    let next = std::mem::take(&mut c.out);
                    c.wire = next;
                    c.sent = 0;
                    c.sending = true;
                    arm_send(&mut r.ring, ri as usize, slot, c);
                } else if c.close_after {
                    arm_close(&mut r.ring, ri as usize, slot, c);
                }
            }
            touched.clear();
            if self.need_ring && Instant::now() >= self.spill_after {
                self.need_ring = !self.spill();
                if self.need_ring {
                    self.spill_after = Instant::now() + Duration::from_secs(1);
                }
            }
        }

        fn run(&mut self) -> ! {
            loop {
                let busy = !self.rq.is_empty() || !self.ready.is_empty();

                for (ri, r) in self.rings.iter_mut().enumerate().rev() {
                    if ri == 0 && !busy {
                        r.ring.enter_wait_timeout(WAIT_MIN, WAIT_NS);
                    } else {
                        r.ring.enter_nowait();
                    }
                }
                self.answers_left = ANSWERS_PER_PASS;
                for ri in 0..self.rings.len() {
                    self.drain(ri);
                }
                self.run_ready();
                self.read_rounds();
                if !self.held.is_empty() && !self.writes_held {
                    self.release_held();
                }
                self.end_batch();
            }
        }
    }

    pub fn run_server(bind_addr: SocketAddr, slots: u32, app: App) -> ! {
        let mut listen_fds = [-1; LISTENERS];
        for l_idx in 0..LISTENERS {
            match create_reuseport_listener(bind_addr) {
                Ok(fd) => listen_fds[l_idx] = fd,
                Err(_) => {
                    for &opened in &listen_fds[..l_idx] {
                        if opened >= 0 {
                            unsafe { close(opened) };
                        }
                    }
                    crate::portable_loop::run_server(bind_addr, app);
                }
            }
        }

        let mut ring0 = match RingState::new(slots) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("io_uring init failed ({e}); falling back to portable loop");
                for &fd in &listen_fds {
                    if fd >= 0 {
                        unsafe { close(fd) };
                    }
                }
                crate::portable_loop::run_server(bind_addr, app);
            }
        };
        arm_accept(&mut ring0, 0, &listen_fds);
        eprintln!(
            "listening on {bind_addr}; io_uring, {slots} direct descriptors per ring"
        );

        let mut srv = Server {
            rings: vec![ring0],
            app,
            listen_fds,
            slots,
            pool: Vec::with_capacity(POOL_MAX),
            touched: Vec::with_capacity(2048),
            held: Vec::new(),
            rq: VecDeque::with_capacity(4096),
            ready: VecDeque::with_capacity(4096),
            answers_left: 0,
            writes_held: false,
            need_ring: false,
            spill_after: Instant::now(),
        };
        srv.run()
    }

    #[repr(C)]
    struct sockaddr_in {
        sin_family: u16,
        sin_port: u16,
        sin_addr: u32,
        sin_zero: [u8; 8],
    }

    #[repr(C)]
    struct sockaddr_in6 {
        sin6_family: u16,
        sin6_port: u16,
        sin6_flowinfo: u32,
        sin6_addr: [u8; 16],
        sin6_scope_id: u32,
    }

    fn create_reuseport_listener(addr: SocketAddr) -> io::Result<c_int> {
        let domain = if addr.is_ipv4() { AF_INET } else { AF_INET6 };
        let fd = unsafe {
            socket(
                domain,
                SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
                IPPROTO_TCP,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        let one: c_int = 1;
        unsafe {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                (&one as *const c_int).cast(),
                std::mem::size_of::<c_int>() as u32,
            );
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEPORT,
                (&one as *const c_int).cast(),
                std::mem::size_of::<c_int>() as u32,
            );
            setsockopt(
                fd,
                IPPROTO_TCP,
                TCP_NODELAY,
                (&one as *const c_int).cast(),
                std::mem::size_of::<c_int>() as u32,
            );
        }

        let bind_rc = match addr {
            SocketAddr::V4(v4) => {
                let sin = sockaddr_in {
                    sin_family: AF_INET as u16,
                    sin_port: v4.port().to_be(),
                    sin_addr: u32::from_ne_bytes(v4.ip().octets()),
                    sin_zero: [0; 8],
                };
                unsafe {
                    bind(
                        fd,
                        (&sin as *const sockaddr_in).cast(),
                        std::mem::size_of::<sockaddr_in>() as u32,
                    )
                }
            }
            SocketAddr::V6(v6) => {
                let sin6 = sockaddr_in6 {
                    sin6_family: AF_INET6 as u16,
                    sin6_port: v6.port().to_be(),
                    sin6_flowinfo: v6.flowinfo(),
                    sin6_addr: v6.ip().octets(),
                    sin6_scope_id: v6.scope_id(),
                };
                unsafe {
                    bind(
                        fd,
                        (&sin6 as *const sockaddr_in6).cast(),
                        std::mem::size_of::<sockaddr_in6>() as u32,
                    )
                }
            }
        };
        if bind_rc < 0 {
            let err = io::Error::last_os_error();
            unsafe { close(fd) };
            return Err(err);
        }
        if unsafe { listen(fd, 65535) } < 0 {
            let err = io::Error::last_os_error();
            unsafe { close(fd) };
            return Err(err);
        }
        Ok(fd)
    }
}

/* =========================================================================
 * Portable Non-Blocking Event Loop for Local macOS Verification & Fallback
 * ========================================================================= */
mod portable_loop {
    use std::io::{ErrorKind, Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::thread;
    use std::time::Duration;

    use crate::app::App;
    use crate::http::{ParseState, parse_http_request, write_static_json_response};

    struct ClientConn {
        stream: TcpStream,
        rx: Vec<u8>,
        tx: Vec<u8>,
        tx_pos: usize,
        close_after_send: bool,
    }

    pub fn run_server(bind_addr: SocketAddr, mut app: App) -> ! {
        let listener = TcpListener::bind(bind_addr).expect("failed to bind TCP listener");
        listener
            .set_nonblocking(true)
            .expect("failed to set non-blocking listener");

        let mut clients: Vec<ClientConn> = Vec::with_capacity(256);
        let mut scratch = [0u8; 4096];

        loop {
            let mut active_step = false;
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = stream.set_nodelay(true);
                        let _ = stream.set_nonblocking(true);
                        clients.push(ClientConn {
                            stream,
                            rx: Vec::with_capacity(2048),
                            tx: Vec::with_capacity(4096),
                            tx_pos: 0,
                            close_after_send: false,
                        });
                        active_step = true;
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                    Err(_) => break,
                }
            }

            let mut idx = 0usize;
            while idx < clients.len() {
                let mut drop_conn = false;
                let conn = &mut clients[idx];

                if conn.tx_pos >= conn.tx.len() && !conn.close_after_send {
                    match conn.stream.read(&mut scratch) {
                        Ok(0) => drop_conn = true,
                        Ok(n) => {
                            active_step = true;
                            conn.rx.extend_from_slice(&scratch[..n]);
                            let mut consumed = 0usize;
                            while consumed < conn.rx.len() {
                                match parse_http_request(&conn.rx[consumed..]) {
                                    ParseState::Complete(req) => {
                                        app.handle_request(&req, &mut conn.tx);
                                        consumed += req.total_consumed;
                                        if req.close_conn {
                                            conn.close_after_send = true;
                                            break;
                                        }
                                    }
                                    ParseState::Incomplete => break,
                                    ParseState::Invalid => {
                                        write_static_json_response(
                                            &mut conn.tx,
                                            400,
                                            true,
                                            b"{\"error\":\"bad request\"}",
                                        );
                                        conn.close_after_send = true;
                                        consumed = conn.rx.len();
                                        break;
                                    }
                                }
                            }
                            if consumed > 0 {
                                conn.rx.drain(..consumed);
                            }
                        }
                        Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                        Err(_) => drop_conn = true,
                    }
                }

                if !drop_conn && conn.tx_pos < conn.tx.len() {
                    match conn.stream.write(&conn.tx[conn.tx_pos..]) {
                        Ok(0) => drop_conn = true,
                        Ok(n) => {
                            active_step = true;
                            conn.tx_pos += n;
                            if conn.tx_pos >= conn.tx.len() {
                                conn.tx.clear();
                                conn.tx_pos = 0;
                                if conn.close_after_send {
                                    drop_conn = true;
                                }
                            }
                        }
                        Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                        Err(_) => drop_conn = true,
                    }
                }

                if drop_conn {
                    clients.swap_remove(idx);
                } else {
                    idx += 1;
                }
            }

            let _ = app.db.commit_batch();
            let _ = app.db.poll_checkpoint(false);

            if !active_step {
                thread::sleep(Duration::from_micros(200));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::{ParseState, parse_http_request};

    fn run_raw_req(app: &mut App, raw_http: &[u8]) -> (u16, String) {
        let ParseState::Complete(req) = parse_http_request(raw_http) else {
            panic!("failed to parse test HTTP request");
        };
        let mut out = Vec::new();
        app.handle_request(&req, &mut out);
        let resp_str = String::from_utf8(out).expect("utf8 response");
        let (head, body) = resp_str.split_once("\r\n\r\n").expect("http split");
        let status_line = head.lines().next().unwrap();
        let status: u16 = status_line
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        (status, body.to_string())
    }

    #[test]
    fn test_golden_and_mutations() {
        let seed_src = "/Users/tvcc/Code/privat/web_bench/twelve-dollar-server-challenge/seed/feed.db";
        let test_db = "/tmp/test_c1_unit.db";
        let _ = std::fs::remove_file(test_db);
        let _ = std::fs::remove_file("/tmp/test_c1_unit.db-wal");
        let _ = std::fs::remove_file("/tmp/test_c1_unit.db-shm");
        std::fs::copy(seed_src, test_db).expect("copy seed db");

        let db = Db::open(test_db).expect("open db");
        let mut app = App::new(db, b"twelve-dollar-challenge");

        let golden_dir = "/Users/tvcc/Code/privat/web_bench/twelve-dollar-server-challenge/test/golden";
        let golden_feed = std::fs::read_to_string(format!("{golden_dir}/feed.json")).unwrap();
        let (st, body) = run_raw_req(&mut app, b"GET /feed HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert_eq!(st, 200);
        assert_eq!(body, golden_feed.trim_end_matches('\n'));

        for id in [1, 42, 1000, 250000, 500000] {
            let p_path = format!("{golden_dir}/post-{id}.json");
            if let Ok(expected) = std::fs::read_to_string(&p_path) {
                let req = format!("GET /posts/{id} HTTP/1.1\r\nHost: localhost\r\n\r\n");
                let (st, body) = run_raw_req(&mut app, req.as_bytes());
                assert_eq!(st, 200, "post {id} status");
                assert_eq!(body, expected.trim_end_matches('\n'), "post {id} body");
            }
        }

        let (st, body) = run_raw_req(&mut app, b"GET /posts/999999999 HTTP/1.1\r\n\r\n");
        assert_eq!(st, 404);
        assert_eq!(body, "{\"error\":\"post not found\"}");

        let (st, body) = run_raw_req(&mut app, b"POST /posts/abc/like HTTP/1.1\r\n\r\n");
        assert_eq!(st, 401);
        assert_eq!(body, "{\"error\":\"missing bearer token\"}");

        // Validly signed HS256 token without an `exp` claim must be rejected with 401
        // Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
        // Payload: {"sub":"1","username":"golden_ember_1"} -> eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJnb2xkZW5fZW1iZXJfMSJ9
        let no_exp_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJnb2xkZW5fZW1iZXJfMSJ9.rbJfYkSojM-HouBSSfwI0qTO64EkrqCBYCZjqR4vzuI";
        let no_exp_req = format!(
            "POST /posts/1/like HTTP/1.1\r\nAuthorization: Bearer {no_exp_token}\r\n\r\n"
        );
        let (st, body) = run_raw_req(&mut app, no_exp_req.as_bytes());
        assert_eq!(st, 401);
        assert_eq!(body, "{\"error\":\"invalid or expired token\"}");

        let (st, body) = run_raw_req(&mut app, b"GET /health HTTP/1.1\r\n\r\n");
        assert_eq!(st, 200);
        assert!(body.starts_with("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"));

        // Read first token from seed/tokens.json (user 1: golden_ember_1)
        let tokens_raw = std::fs::read_to_string(
            "/Users/tvcc/Code/privat/web_bench/twelve-dollar-server-challenge/seed/tokens.json",
        )
        .unwrap();
        let token = tokens_raw
            .split('"')
            .find(|s| s.starts_with("eyJ"))
            .expect("first jwt token");

        let create_body = "{\"body\":\"  hello world  \"}";
        let create_req = format!(
            "POST /posts HTTP/1.1\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\n\r\n{create_body}",
            create_body.len()
        );
        let (st, body) = run_raw_req(&mut app, create_req.as_bytes());
        assert_eq!(st, 201, "create post: {body}");
        assert!(body.contains("\"body\":\"hello world\""), "trimmed body: {body}");
        assert!(body.contains("\"author\":\"golden_ember_1\""), "author: {body}");
        assert!(body.contains("\"like_count\":0}"), "like_count: {body}");

        let like1_req = format!(
            "POST /posts/500001/like HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n"
        );
        let (st, body) = run_raw_req(&mut app, like1_req.as_bytes());
        assert_eq!(st, 201);
        assert_eq!(body, "{\"liked\":true,\"already_liked\":false,\"post_id\":500001}");

        let (st, body) = run_raw_req(&mut app, like1_req.as_bytes());
        assert_eq!(st, 200);
        assert_eq!(body, "{\"liked\":true,\"already_liked\":true,\"post_id\":500001}");

        let like_missing = format!(
            "POST /posts/999999999/like HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n"
        );
        let (st, body) = run_raw_req(&mut app, like_missing.as_bytes());
        assert_eq!(st, 404);
        assert_eq!(body, "{\"error\":\"post not found\"}");

        let (st, body) = run_raw_req(&mut app, b"GET /posts/500001 HTTP/1.1\r\n\r\n");
        assert_eq!(st, 200);
        assert!(body.contains("\"like_count\":1}"), "updated like_count: {body}");

        let (st, body) = run_raw_req(&mut app, b"GET /feed HTTP/1.1\r\n\r\n");
        assert_eq!(st, 200);
        assert!(body.starts_with("{\"posts\":[{\"id\":500001,"), "new post at top of feed: {body}");

        app.db.end_read_batch();
        drop(app);
        let _ = std::fs::remove_file(test_db);
        let _ = std::fs::remove_file("/tmp/test_c1_unit.db-wal");
        let _ = std::fs::remove_file("/tmp/test_c1_unit.db-shm");
    }
}
