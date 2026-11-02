//! Completion-based Linux I/O. Fixed descriptors belong to each ring, rather than
//! the process file table. One issuer owns all rings and the request connection.
use crate::{App, Parsed, error, frame, writer::{WriteJob, WriteSender, Writer}};
use io_uring::{IoUring, cqueue, opcode, squeue, types};
use std::{
    alloc::{Layout, alloc, dealloc, handle_alloc_error, realloc},
    collections::VecDeque,
    io,
    net::TcpListener,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    ptr::{self, NonNull},
    sync::{atomic::{AtomicU16, Ordering}, mpsc::{self, TrySendError}},
    time::{Duration, Instant},
};

const MAX_WORKERS: usize = 8;
const CQ_BATCH: usize = 2048;
const TARGET_SLOTS: usize = MAX_WORKERS * 65535;
const NBUFS: usize = 4096;
const BUFSIZE: usize = 2048;
const INPUT_LIMIT: usize = 1_114_112;
const OUTPUT_HIGH: usize = 65536;
const GROUP: u16 = 0;
const ACCEPT: u64 = 1;
const RECV: u64 = 2;
const SEND: u64 = 3;
const IGNORE: u64 = 4;
const LIVE: u32 = 1;
const RECEIVING: u32 = 2;
const SENDING: u32 = 4;
const CLOSING: u32 = 8;
const SHUT: u32 = 16;
const PAUSED: u32 = 32;
const DIRTY: u32 = 64;
const CONTINUED: u32 = 128;
const READY: u32 = 256;
const HELD: u32 = 512;
const REARM: u32 = 1024;
const EOF: u32 = 2048;
const WRITING: u32 = 4096;
const INDEX_SHIFT: u32 = 13;
const FLAG_MASK: u32 = (1 << INDEX_SHIFT) - 1;

#[derive(Clone, Copy)]
pub struct Tuning {
    pub batch: usize,
    pub wait_us: u32,
}
impl Default for Tuning {
    fn default() -> Self {
        Self {
            batch: 32,
            wait_us: 250,
        }
    }
}

/// A compact owning buffer. Its allocation never moves while a send is in flight.
/// Keeping lengths as u32 makes a complete connection fit one 64-byte cache line.
#[repr(C)]
#[derive(Default)]
struct Buffer {
    ptr: *mut u8,
    len: u32,
    cap: u32,
}
impl Buffer {
    fn bytes(&self) -> &[u8] {
        if self.len == 0 {
            return &[];
        }
        // reserve initializes exactly the written prefix before increasing len.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len as usize) }
    }
    fn reserve(&mut self, needed: usize) {
        if needed <= self.cap as usize {
            return;
        }
        assert!(needed <= 4 * 1024 * 1024);
        let cap = needed.max(4096).next_power_of_two();
        let layout = Layout::from_size_align(cap, 8).unwrap();
        // Both allocation paths use the same alignment and allocator. No caller
        // may grow a Buffer after it has been transferred into Client::flight.
        let p = unsafe {
            if self.cap == 0 {
                alloc(layout)
            } else {
                realloc(
                    self.ptr,
                    Layout::from_size_align(self.cap as usize, 8).unwrap(),
                    cap,
                )
            }
        };
        if p.is_null() {
            handle_alloc_error(layout);
        }
        self.ptr = p;
        self.cap = cap as u32;
    }
    fn extend(&mut self, bytes: &[u8]) {
        let old = self.len as usize;
        self.reserve(old + bytes.len());
        if !bytes.is_empty() {
            // Source and destination are distinct allocations (or stack bytes).
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), self.ptr.add(old), bytes.len());
            }
        }
        self.len = (old + bytes.len()) as u32;
    }
    fn consume(&mut self, n: usize) {
        assert!(n <= self.len as usize);
        let left = self.len as usize - n;
        if left != 0 {
            // Moving a partial/pipelined tail can overlap within the allocation.
            unsafe {
                ptr::copy(self.ptr.add(n), self.ptr, left);
            }
        }
        self.len = left as u32;
    }
}
impl Drop for Buffer {
    fn drop(&mut self) {
        if self.cap != 0 {
            unsafe {
                dealloc(
                    self.ptr,
                    Layout::from_size_align(self.cap as usize, 8).unwrap(),
                );
            }
        }
    }
}
#[repr(C)]
#[derive(Default)]
struct Client {
    input: Buffer,
    output: Buffer,
    flight: Buffer,
    sent: u32,
    generation: u32,
    touched: u32,
    state: u32,
}
const _: () = assert!(std::mem::size_of::<Client>() == 64);

struct Mapping {
    ptr: NonNull<u8>,
    len: usize,
}
impl Mapping {
    fn new(len: usize) -> io::Result<Self> {
        let p = unsafe {
            libc::mmap(
                ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            )
        };
        if p == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            ptr: NonNull::new(p.cast()).unwrap(),
            len,
        })
    }
}
impl Drop for Mapping {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.ptr.as_ptr().cast(), self.len);
        }
    }
}
struct Pending {
    fd: usize,
    generation: u32,
    start: u32,
    count: u32,
    interim: bool,
}

impl Pending {
    #[cold]
    fn rollback(&self, output: &mut Buffer, close: bool, body: &[u8]) {
        // A failed in-flight send can discard queued bytes later in this same
        // CQ batch. That connection is closing and has no replies to rewrite.
        if output.len < self.start
            || (output.len == self.start && (self.count != 0 || self.interim))
        {
            return;
        }
        // Recover interim positions from our own encoded responses only after a
        // failed commit. Successful batches retain their existing metadata and
        // allocation behavior, including multiple Continue responses per batch.
        let mut interims = Vec::new();
        if self.interim {
            let mut bytes = &output.bytes()[self.start as usize..];
            let mut count = 0;
            while !bytes.is_empty() {
                if let Some(rest) = bytes.strip_prefix(b"HTTP/1.1 100 Continue\r\n\r\n") {
                    interims.push(count);
                    bytes = rest;
                    continue;
                }
                let mut headers = [httparse::EMPTY_HEADER; 3];
                let mut reply = httparse::Response::new(&mut headers);
                let httparse::Status::Complete(end) = reply.parse(bytes).expect("encoded response")
                else {
                    unreachable!("incomplete encoded response");
                };
                let length = reply
                    .headers
                    .iter()
                    .find(|h| h.name == "Content-Length")
                    .and_then(|h| std::str::from_utf8(h.value).ok())
                    .and_then(|n| n.parse::<usize>().ok())
                    .expect("encoded response length");
                bytes = &bytes[end + length..];
                count += 1;
            }
            assert_eq!(count, self.count);
        }
        output.len = self.start;
        let mut interims = interims.into_iter().peekable();
        for i in 0..=self.count {
            while interims.peek() == Some(&i) {
                output.extend(b"HTTP/1.1 100 Continue\r\n\r\n");
                interims.next();
            }
            if i < self.count {
                response(500, body, close && i + 1 == self.count, output);
            }
        }
    }
}
struct Worker {
    // Destroy the ring before any of the allocations referenced by its entries.
    ring: IoUring,
    recv_memory: Mapping,
    buf_ring: Mapping,
    tail: u16,
    rearm: VecDeque<(usize, u32)>,
    clients: Vec<Client>,
    slots: usize,
    reserve: usize,
    listener: i32,
    accepting: bool,
    accept_generation: u32,
    open: usize,
    ready: VecDeque<(usize, u32)>,
    held: VecDeque<(usize, u32)>,
    writer: Option<WriteSender>,
    writer_full: bool,
    write_pool: Vec<WriteJob>,
    index: usize,
    completions: Vec<(u64, i32, u32)>,
    backlog: VecDeque<(u64, i32, u32)>,
    pending: Vec<Pending>,
    pool: Vec<Buffer>,
    body: Vec<u8>,
    start: Instant,
    now: u32,
    sweep: u32,
}
fn tag(op: u64, fd: usize, generation: u32) -> u64 {
    op | ((fd as u64) << 8) | ((generation as u64) << 32)
}
impl Worker {
    fn new(listener: i32, slots: usize) -> io::Result<Self> {
        let ring = IoUring::builder()
            .setup_cqsize(16384)
            .setup_coop_taskrun()
            .setup_taskrun_flag()
            .setup_single_issuer()
            .setup_defer_taskrun()
            .build(4096)?;
        ring.submitter().register_files_sparse(slots as u32)?;
        let recv_memory = Mapping::new(NBUFS * BUFSIZE)?;
        let descriptors = Mapping::new(NBUFS * std::mem::size_of::<types::BufRingEntry>())?;
        // mmap supplies page alignment. Both mappings outlive every receive and
        // are private to this issuer; the kernel owns each published buffer until
        // its completion transfers it back to us.
        unsafe {
            ring.submitter().register_buf_ring_with_flags(
                descriptors.ptr.as_ptr() as u64,
                NBUFS as u16,
                GROUP,
                0,
            )
        }?;
        let mut w = Self {
            ring,
            recv_memory,
            buf_ring: descriptors,
            tail: 0,
            rearm: VecDeque::new(),
            clients: Vec::new(),
            slots,
            reserve: 1024.min(slots / 8),
            listener,
            accepting: false,
            accept_generation: 0,
            open: 0,
            ready: VecDeque::new(),
            held: VecDeque::new(),
            writer: None,
            writer_full: false,
            write_pool: Vec::new(),
            index: 0,
            completions: Vec::with_capacity(CQ_BATCH),
            backlog: VecDeque::new(),
            pending: Vec::with_capacity(1024),
            pool: Vec::with_capacity(256),
            body: Vec::with_capacity(16384),
            start: Instant::now(),
            now: 0,
            sweep: 0,
        };
        for bid in 0..NBUFS {
            w.recycle(bid as u16);
        }
        w.publish_buffers();
        Ok(w)
    }
    fn submit(&mut self) -> io::Result<bool> {
        match self.ring.submit() {
            Ok(_) => Ok(true),
            Err(e) if matches!(e.raw_os_error(), Some(libc::EINTR | libc::EAGAIN | libc::EBUSY)) => Ok(false),
            Err(e) => Err(e),
        }
    }
    fn queue(&mut self, entry: squeue::Entry) {
        loop {
            // Every pointer in an SQE refers to a mapping or a flight Buffer
            // retained until its final CQE. The SQE itself is copied into the SQ.
            if unsafe { self.ring.submission().push(&entry) }.is_ok() {
                break;
            }
            // Return completed buffers before submitting any rearmed receives.
            self.publish_buffers();
            match self.submit() {
                Ok(true) => {}
                Ok(false) => {
                    // CQ pressure can prevent SQ progress. Retain every CQE
                    // for the next bounded pass before retrying this SQE.
                    self.backlog.extend(self.ring.completion()
                        .map(|c| (c.user_data(), c.result(), c.flags())));
                }
                Err(e) => panic!("submit full I/O queue: {e}"),
            }
        }
    }
    fn accept(&mut self) {
        self.accept_generation = self.accept_generation.wrapping_add(1);
        let e = opcode::AcceptMulti::new(types::Fd(self.listener))
            .allocate_file_index(true)
            .build()
            .user_data(tag(ACCEPT, 0, self.accept_generation));
        self.queue(e);
        self.accepting = true;
    }
    fn stop_accept(&mut self) {
        self.queue(
            opcode::AsyncCancel::new(tag(ACCEPT, 0, self.accept_generation))
                .build()
                .user_data(IGNORE)
                .flags(squeue::Flags::SKIP_SUCCESS),
        );
        self.accepting = false;
    }
    fn recv(&mut self, fd: usize) {
        let e = opcode::RecvMulti::new(types::Fixed(fd as u32), GROUP)
            .build()
            .user_data(tag(RECV, fd, self.clients[fd].generation));
        self.queue(e);
        self.clients[fd].state = (self.clients[fd].state | RECEIVING) & !REARM;
    }
    fn send(&mut self, fd: usize) {
        let c = &mut self.clients[fd];
        assert!(c.sent < c.flight.len);
        let e = opcode::Send::new(
            types::Fixed(fd as u32),
            unsafe { c.flight.ptr.add(c.sent as usize) },
            c.flight.len - c.sent,
        )
        .flags(libc::MSG_NOSIGNAL)
        .build()
        .user_data(tag(SEND, fd, c.generation));
        c.state |= SENDING;
        self.queue(e);
    }
    fn recycle(&mut self, bid: u16) {
        assert!((bid as usize) < NBUFS);
        let index = self.tail as usize & (NBUFS - 1);
        // The completed receive transfers this buffer back to userspace. This
        // descriptor slot is outside the kernel's unconsumed interval.
        let entry = unsafe {
            &mut *self
                .buf_ring
                .ptr
                .as_ptr()
                .cast::<types::BufRingEntry>()
                .add(index)
        };
        entry.set_addr(unsafe { self.recv_memory.ptr.as_ptr().add(bid as usize * BUFSIZE) } as u64);
        entry.set_len(BUFSIZE as u32);
        entry.set_bid(bid);
        self.tail = self.tail.wrapping_add(1);
    }
    fn publish_buffers(&mut self) {
        // Release publishes initialized descriptors after reads of old contents.
        let tail = unsafe { types::BufRingEntry::tail(self.buf_ring.ptr.as_ptr().cast()) };
        unsafe {
            (&*tail.cast::<AtomicU16>()).store(self.tail, Ordering::Release);
        }
    }
    fn dirty(&mut self, fd: usize) -> usize {
        let c = &mut self.clients[fd];
        if c.state & DIRTY != 0 {
            return (c.state >> INDEX_SHIFT) as usize;
        }
        let index = self.pending.len();
        assert!(index < 1 << (32 - INDEX_SHIFT));
        self.pending.push(Pending {
            fd,
            generation: c.generation,
            start: c.output.len,
            count: 0,
            interim: false,
        });
        c.state |= DIRTY | ((index as u32) << INDEX_SHIFT);
        index
    }
    fn output(&mut self, fd: usize) {
        if self.clients[fd].output.cap == 0 {
            self.clients[fd].output = self.pool.pop().unwrap_or_default();
        }
    }
    fn retire(&mut self, mut b: Buffer) {
        b.len = 0;
        if b.cap <= 16384 && self.pool.len() < 256 {
            self.pool.push(b);
        }
    }
    fn schedule(&mut self, fd: usize) {
        let c = &mut self.clients[fd];
        if c.state & (READY | HELD | WRITING) == 0 {
            c.state |= READY;
            self.ready.push_back((fd, c.generation));
        }
    }
    fn hold(&mut self, fd: usize) {
        let c = &mut self.clients[fd];
        if c.state & HELD == 0 {
            c.state |= HELD;
            self.held.push_back((fd, c.generation));
        }
    }
    fn pause(&mut self, fd: usize) {
        let c = &mut self.clients[fd];
        if c.state & PAUSED != 0 {
            return;
        }
        c.state |= PAUSED;
        if c.state & RECEIVING != 0 {
            let e = opcode::AsyncCancel::new(tag(RECV, fd, c.generation))
                .build()
                .user_data(IGNORE)
                .flags(squeue::Flags::SKIP_SUCCESS);
            self.queue(e);
        }
    }
    fn close(&mut self, fd: usize) {
        let c = &mut self.clients[fd];
        if c.state & LIVE == 0 || c.state & SENDING != 0 || c.output.len != 0 {
            return;
        }
        if c.state & RECEIVING != 0 {
            if c.state & SHUT == 0 {
                c.state |= SHUT;
                self.queue(
                    opcode::Shutdown::new(types::Fixed(fd as u32), libc::SHUT_RDWR)
                        .build()
                        .user_data(IGNORE)
                        .flags(squeue::Flags::SKIP_SUCCESS),
                );
            }
            return;
        }
        self.queue(
            opcode::Close::new(types::Fixed(fd as u32))
                .build()
                .user_data(IGNORE)
                .flags(squeue::Flags::SKIP_SUCCESS),
        );
        let c = &mut self.clients[fd];
        let generation = c.generation.wrapping_add(1);
        *c = Client {
            generation,
            ..Default::default()
        };
        self.open -= 1;
    }
    fn process(&mut self, fd: usize, bytes: &[u8], app: &mut App) {
        let mut saved = std::mem::take(&mut self.clients[fd].input);
        if self.clients[fd].state & (PAUSED | WRITING) != 0 {
            if saved.len as usize + bytes.len() <= INPUT_LIMIT {
                saved.extend(bytes);
            } else {
                self.clients[fd].state |= CLOSING;
            }
            self.clients[fd].input = saved;
            return;
        }
        let input = if saved.len == 0 {
            bytes
        } else {
            if saved.len as usize + bytes.len() <= INPUT_LIMIT {
                saved.extend(bytes);
            } else {
                self.clients[fd].state |= CLOSING;
                self.close(fd);
                return;
            }
            saved.bytes()
        };
        let mut offset = 0;
        let mut count = 0;
        let initial = self.clients[fd].output.len;
        let mut closing = false;
        let mut deferred = false;
        let mut held = false;
        while offset < input.len() {
            match frame(&input[offset..]) {
                Ok(Parsed::Complete(req)) => {
                    if req.method == "POST" && self.writer.is_some() {
                        if self.writer_full || !self.writer.as_ref().unwrap().available(req.consumed) {
                            self.writer_full = true;
                            held = true;
                            deferred = true;
                            break;
                        }
                        let mut job = self.write_pool.pop().unwrap_or_default();
                        job.ring = self.index;
                        job.fd = fd;
                        job.generation = self.clients[fd].generation;
                        job.status = 0;
                        job.request.clear();
                        job.request.extend_from_slice(&input[offset..offset + req.consumed]);
                        let writer = self.writer.as_ref().unwrap();
                        match writer.try_send(job) {
                            Ok(()) => {
                                self.clients[fd].state = (self.clients[fd].state | WRITING) & !CONTINUED;
                                offset += req.consumed;
                                deferred = true;
                            }
                            Err(TrySendError::Full(job)) => {
                                self.write_pool.push(job);
                                self.writer_full = true;
                                held = true;
                                deferred = true;
                            }
                            Err(TrySendError::Disconnected(_)) => panic!("SQLite writer stopped"),
                        }
                        break;
                    }
                    // Keep reads and I/O progressing while the checkpoint
                    // finishes. Preserve the complete write in input and retry
                    // after the bounded drain; no response is acknowledged yet.
                    if req.method == "POST" && app.db.draining() {
                        held = true;
                        deferred = true;
                        break;
                    }
                    self.clients[fd].state &= !CONTINUED;
                    self.body.clear();
                    let status = app.serve(&req, &mut self.body);
                    let index = self.dirty(fd);
                    self.output(fd);
                    response(status, &self.body, req.close, &mut self.clients[fd].output);
                    self.pending[index].count += 1;
                    count += 1;
                    offset += req.consumed;
                    if req.close {
                        closing = true;
                        break;
                    }
                    if count >= 64 || self.clients[fd].output.len - initial >= 262144 {
                        deferred = offset < input.len();
                        break;
                    }
                }
                Ok(Parsed::Incomplete { expect_continue }) => {
                    if self.clients[fd].state & EOF != 0 {
                        self.body.clear();
                        error(&mut self.body, 400, "malformed request");
                        let index = self.dirty(fd);
                        self.output(fd);
                        response(400, &self.body, true, &mut self.clients[fd].output);
                        self.pending[index].count += 1;
                        closing = true;
                        break;
                    }
                    if expect_continue && self.clients[fd].state & CONTINUED == 0 {
                        let index = self.dirty(fd);
                        self.output(fd);
                        self.clients[fd]
                            .output
                            .extend(b"HTTP/1.1 100 Continue\r\n\r\n");
                        self.pending[index].interim = true;
                        self.clients[fd].state |= CONTINUED;
                    }
                    break;
                }
                Err(()) => {
                    self.body.clear();
                    error(&mut self.body, 400, "malformed request");
                    let index = self.dirty(fd);
                    self.output(fd);
                    response(400, &self.body, true, &mut self.clients[fd].output);
                    self.pending[index].count += 1;
                    closing = true;
                    break;
                }
            }
        }
        if !closing && offset < input.len() {
            if saved.len == 0 {
                saved.extend(&bytes[offset..]);
            } else {
                saved.consume(offset);
            }
            self.clients[fd].input = saved;
        } else if saved.cap != 0 {
            self.retire(saved);
        }
        if closing || (!deferred && self.clients[fd].state & EOF != 0) {
            self.clients[fd].state |= CLOSING;
            self.dirty(fd);
        }
        if self.clients[fd].output.len as usize >= OUTPUT_HIGH {
            self.pause(fd);
        }
        if held {
            self.hold(fd);
        } else if deferred {
            self.schedule(fd);
        }
    }
    fn on_accept(&mut self, generation: u32, result: i32, flags: u32) {
        if !cqueue::more(flags) && generation == self.accept_generation {
            self.accepting = false;
        }
        if result < 0 {
            return;
        }
        let fd = result as usize;
        assert!(fd < self.slots);
        if self.clients.len() <= fd {
            self.clients.resize_with(
                (fd + 1).next_multiple_of(1024).min(self.slots),
                Client::default,
            );
        }
        let generation = self.clients[fd].generation;
        assert!(self.clients[fd].state & LIVE == 0);
        self.clients[fd] = Client {
            generation,
            touched: self.now,
            state: LIVE,
            ..Default::default()
        };
        self.open += 1;
        self.recv(fd);
        if self.accepting && self.slots - self.open < self.reserve {
            self.stop_accept();
        }
    }
    fn on_recv(&mut self, fd: usize, generation: u32, result: i32, flags: u32, app: &mut App) {
        let selected = cqueue::buffer_select(flags);
        let valid = fd < self.clients.len()
            && self.clients[fd].generation == generation
            && self.clients[fd].state & LIVE != 0;
        if valid {
            if !cqueue::more(flags) {
                self.clients[fd].state &= !RECEIVING;
            }
            if result > 0 {
                let bid = selected.expect("receive buffer id");
                assert!((bid as usize) < NBUFS && result as usize <= BUFSIZE);
                self.clients[fd].touched = self.now;
                if self.clients[fd].state & CLOSING == 0 {
                    // CQE transfers this buffer to the issuer. It is not returned
                    // to the kernel until process finishes borrowing its bytes.
                    let bytes = unsafe {
                        std::slice::from_raw_parts(
                            self.recv_memory.ptr.as_ptr().add(bid as usize * BUFSIZE),
                            result as usize,
                        )
                    };
                    self.process(fd, bytes, app);
                }
            } else if result == 0 && self.clients[fd].state & CLOSING == 0
                && (self.clients[fd].input.len != 0 || self.clients[fd].state & WRITING != 0) {
                self.clients[fd].state |= EOF;
                self.schedule(fd);
            } else if (result != -libc::ENOBUFS && result != -libc::ECANCELED)
                || self.clients[fd].state & CLOSING != 0
            {
                self.clients[fd].state |= CLOSING;
                self.close(fd);
            }
            let c = &self.clients[fd];
            if c.state & (RECEIVING | CLOSING | PAUSED | REARM | EOF) == 0 && c.state & LIVE != 0 {
                if result == -libc::ENOBUFS {
                    // A depleted receive joins a bounded retry pass after buffers
                    // and responses have been returned. Retrying every failure
                    // during CQ processing can generate another failure storm.
                    self.clients[fd].state |= REARM;
                    self.rearm.push_back((fd, generation));
                } else {
                    self.recv(fd);
                }
            }
        }
        if let Some(bid) = selected {
            self.recycle(bid);
        }
    }
    fn on_send(&mut self, fd: usize, generation: u32, result: i32) {
        if fd >= self.clients.len()
            || self.clients[fd].generation != generation
            || self.clients[fd].state & LIVE == 0
        {
            return;
        }
        let c = &mut self.clients[fd];
        c.state &= !SENDING;
        if result == -libc::EAGAIN || result == -libc::EINTR {
            self.send(fd);
            return;
        }
        c.touched = self.now;
        if result > 0 {
            c.sent += result as u32;
            assert!(c.sent <= c.flight.len);
        } else {
            c.state |= CLOSING;
            c.output.len = 0;
            c.sent = c.flight.len;
        }
        if c.sent < c.flight.len {
            self.send(fd);
            return;
        }
        c.sent = 0;
        let done = std::mem::take(&mut c.flight);
        self.retire(done);
        self.dirty(fd);
        if self.clients[fd].state & PAUSED != 0
            && (self.clients[fd].output.len as usize) < OUTPUT_HIGH / 2
        {
            self.clients[fd].state &= !PAUSED;
            if self.clients[fd].input.len != 0 {
                self.schedule(fd);
            }
            if self.clients[fd].state & (RECEIVING | CLOSING | EOF) == 0 {
                self.recv(fd);
            }
        }
    }
    fn flush(&mut self, committed: bool) {
        if !committed {
            self.body.clear();
            error(&mut self.body, 500, "internal server error");
            for p in &self.pending {
                let c = &mut self.clients[p.fd];
                if c.generation != p.generation || c.state & LIVE == 0 {
                    continue;
                }
                p.rollback(&mut c.output, c.state & CLOSING != 0, &self.body);
            }
        }
        for i in 0..self.pending.len() {
            let fd = self.pending[i].fd;
            let c = &mut self.clients[fd];
            if c.generation != self.pending[i].generation {
                continue;
            }
            c.state &= FLAG_MASK & !DIRTY;
            if c.state & LIVE == 0 || c.state & SENDING != 0 {
                continue;
            }
            if c.output.len != 0 {
                c.flight = std::mem::take(&mut c.output);
                c.sent = 0;
                self.send(fd);
            } else if c.state & CLOSING != 0 {
                self.close(fd);
            }
        }
        self.pending.clear();
    }
    fn tick(&mut self, app: &mut App) -> usize {
        self.now = self.start.elapsed().as_secs() as u32;
        self.completions.clear();
        self.completions.extend(self.backlog.drain(..self.backlog.len().min(CQ_BATCH)));
        let budget = CQ_BATCH - self.completions.len();
        self.completions.extend(
            self.ring
                .completion()
                .take(budget)
                .map(|c| (c.user_data(), c.result(), c.flags())),
        );
        let count = self.completions.len();
        if !app.db.draining() && !self.writer_full {
            for _ in 0..self.held.len().min(128) {
                let (fd, generation) = self.held.pop_front().unwrap();
                let c = &mut self.clients[fd];
                if c.generation == generation && c.state & HELD != 0 {
                    c.state &= !HELD;
                    self.schedule(fd);
                }
            }
        }
        let ready = self.ready.len().min(128);
        for _ in 0..ready {
            let (fd, generation) = self.ready.pop_front().unwrap();
            if self.clients[fd].generation != generation {
                continue;
            }
            self.clients[fd].state &= !READY;
            if self.clients[fd].state & (LIVE | CLOSING | PAUSED | WRITING) == LIVE {
                self.process(fd, &[], app);
            }
        }
        for i in 0..self.completions.len() {
            let (tag, result, flags) = self.completions[i];
            let fd = ((tag >> 8) & 0xffffff) as usize;
            let generation = (tag >> 32) as u32;
            match tag & 255 {
                ACCEPT => self.on_accept(generation, result, flags),
                RECV => self.on_recv(fd, generation, result, flags, app),
                SEND => self.on_send(fd, generation, result),
                _ => {}
            }
        }
        self.publish_buffers();
        if !self.rearm.is_empty() {
            let returned = self
                .completions
                .iter()
                .filter(|(_, _, flags)| cqueue::buffer_select(*flags).is_some())
                .count();
            // Bound retries by progress, with a small allowance to restart
            // an otherwise idle ring. Unvisited clients remain queued once.
            let budget = returned.max(32).min(NBUFS / 2);
            for _ in 0..budget {
                let Some((fd, generation)) = self.rearm.pop_front() else {
                    break;
                };
                let c = &mut self.clients[fd];
                if c.generation != generation || c.state & REARM == 0 {
                    continue;
                }
                c.state &= !REARM;
                if c.state & (LIVE | RECEIVING | CLOSING | PAUSED | EOF) == LIVE {
                    self.recv(fd);
                }
            }
        }
        if !self.accepting && self.slots - self.open >= self.reserve * 2 {
            self.accept();
        }
        if self.now >= self.sweep + 10 {
            self.sweep = self.now;
            for fd in 0..self.clients.len() {
                let c = &mut self.clients[fd];
                // Idle keep-alives are retained; only stalled partial input
                // or blocked output is closed after 120 seconds.
                if c.state & LIVE != 0
                    && (c.input.len != 0 || c.flight.len != 0 || c.output.len != 0)
                    && self.now.saturating_sub(c.touched) >= 120
                {
                    c.state |= CLOSING;
                    c.output.len = 0;
                    if c.state & SHUT == 0 {
                        c.state |= SHUT;
                        self.queue(
                            opcode::Shutdown::new(types::Fixed(fd as u32), libc::SHUT_RDWR)
                                .build()
                                .user_data(IGNORE)
                                .flags(squeue::Flags::SKIP_SUCCESS),
                        );
                    }
                    self.close(fd);
                }
            }
        }
        count
    }

    fn written(&mut self, mut job: WriteJob) {
        if let Some(writer) = &self.writer {
            writer.completed(&job);
        }
        self.writer_full = false;
        let fd = job.fd;
        if fd < self.clients.len() && self.clients[fd].generation == job.generation
            && self.clients[fd].state & (LIVE | WRITING) == LIVE | WRITING {
            self.clients[fd].state &= !WRITING;
            let index = self.dirty(fd);
            self.output(fd);
            response(job.status, &job.body, job.close, &mut self.clients[fd].output);
            self.pending[index].count += 1;
            if job.close || (self.clients[fd].state & EOF != 0 && self.clients[fd].input.len == 0) {
                self.clients[fd].state |= CLOSING;
            } else if self.clients[fd].input.len != 0 {
                self.schedule(fd);
            }
            if self.clients[fd].output.len as usize >= OUTPUT_HIGH { self.pause(fd); }
        }
        job.request.clear();
        job.body.clear();
        if self.write_pool.len() < 256 && job.request.capacity() <= 16384 && job.body.capacity() <= 16384 {
            self.write_pool.push(job);
        }
    }
}
fn response(status: u16, body: &[u8], close: bool, out: &mut Buffer) {
    out.extend(match status {
        200 => b"HTTP/1.1 200 OK\r\n",
        201 => b"HTTP/1.1 201 Created\r\n",
        400 => b"HTTP/1.1 400 Bad Request\r\n",
        401 => b"HTTP/1.1 401 Unauthorized\r\n",
        404 => b"HTTP/1.1 404 Not Found\r\n",
        503 => b"HTTP/1.1 503 Service Unavailable\r\n",
        _ => b"HTTP/1.1 500 Internal Server Error\r\n",
    });
    out.extend(b"Content-Type: application/json\r\nContent-Length: ");
    out.extend(itoa::Buffer::new().format(body.len()).as_bytes());
    out.extend(if close {
        b"\r\nConnection: close\r\n\r\n"
    } else {
        b"\r\n\r\n"
    });
    out.extend(body);
}
pub fn run(address: &str, app: App, tuning: Tuning) -> io::Result<()> {
    let mut limits = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limits) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let slots = limits.rlim_max.min(TARGET_SLOTS as libc::rlim_t) as usize;
    if slots < 4096 {
        return Err(io::Error::other(
            "descriptor hard limit must be at least 4096",
        ));
    }
    let workers = TARGET_SLOTS.div_ceil(slots).min(MAX_WORKERS);
    if limits.rlim_cur < slots as libc::rlim_t {
        limits.rlim_cur = slots as libc::rlim_t;
        if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limits) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    // Ring teardown after SIGKILL is asynchronous and may briefly retain an
    // accept's listener reference. Retry only address-in-use, well within the
    // challenge's 60-second startup allowance.
    let mut attempt = 0;
    let listener = loop {
        match TcpListener::bind(address) {
            Ok(listener) => break listener,
            Err(e) if e.raw_os_error() == Some(libc::EADDRINUSE) && attempt < 200 => {
                attempt += 1;
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(e),
        }
    };
    let fd = listener.as_raw_fd();
    let enabled = 1i32;
    unsafe {
        if libc::listen(fd, 4096) != 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_NODELAY,
            (&enabled as *const i32).cast(),
            4,
        ) != 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    // All rings are created and driven by this thread (SINGLE_ISSUER).
    // Eventfds wake poll when a quiet ring receives work. No per-ring threads,
    // locks, shared App or scheduler handoffs are needed on a one-CPU server.
    let mut app = app;
    let writer = Writer::new(std::env::var("SQLITE_PATH").expect("SQLITE_PATH"),
        std::env::var("JWT_SECRET").expect("JWT_SECRET"), app.start, app.db.group)?;
    let mut rings = Vec::with_capacity(workers);
    let mut signals = Vec::with_capacity(workers);
    let mut events = Vec::with_capacity(workers);
    for index in 0..workers {
        let mut w = Worker::new(fd, slots)?;
        w.index = index;
        w.writer = Some(writer.sender.clone());
        let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        if efd < 0 {
            return Err(io::Error::last_os_error());
        }
        let signal = unsafe { OwnedFd::from_raw_fd(efd) };
        w.ring.submitter().register_eventfd(signal.as_raw_fd())?;
        events.push(libc::pollfd {
            fd: signal.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        signals.push(signal);
        w.accept();
        rings.push(w);
    }
    events.push(libc::pollfd { fd: writer.signal.as_raw_fd(), events: libc::POLLIN, revents: 0 });
    eprintln!(
        "listening {address}; one issuer, {workers} rings x {slots} direct descriptors; SQLite WAL/NORMAL"
    );
    loop {
        let mut count = 0;
        let mut ready = false;
        for _ in 0..8192 {
            match writer.replies.as_ref().unwrap().try_recv() {
                Ok(job) => { let index = job.ring; rings[index].written(job); count += 1; }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => panic!("SQLite writer stopped"),
            }
        }
        // A committed writer batch guarantees queue space. Until then, a full
        // queue parks held connections instead of repeatedly parsing them.
        if count != 0 { for w in &mut rings { w.writer_full = false; } }
        for w in &mut rings {
            let pending = {
                let sq = w.ring.submission();
                !sq.is_empty() || sq.taskrun() || sq.cq_overflow()
            };
            if pending || !w.ring.completion().is_empty() {
                ready |= !w.submit()?;
            }
            count += w.tick(&mut app);
            ready |= !w.ready.is_empty() || !w.rearm.is_empty() || !w.backlog.is_empty();
        }
        let committed = app.db.commit();
        for w in &mut rings {
            w.flush(committed);
        }
        app.db.checkpoint_async();
        ready |= !app.db.draining() && rings.iter().any(|w| !w.writer_full && !w.held.is_empty());
        if count != 0 || ready {
            if count < tuning.batch && tuning.wait_us != 0 {
                std::thread::sleep(Duration::from_micros(u64::from(tuning.wait_us)));
            }
            continue;
        }
        // A flush can queue sends without producing a completion yet. Publish
        // those before sleeping so their completions can actually wake us.
        for w in &mut rings {
            if !w.ring.submission().is_empty() {
                ready |= !w.submit()?;
            }
        }
        if ready {
            continue;
        }
        let timeout = if app.db.draining() { 1 } else { 1000 };
        let n = unsafe { libc::poll(events.as_mut_ptr(), events.len() as _, timeout) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(e);
        }
        for event in &mut events {
            if event.revents & libc::POLLIN != 0 {
                let mut n = 0u64;
                let rc = unsafe { libc::read(event.fd, (&mut n as *mut u64).cast(), 8) };
                if rc != 8 {
                    let e = io::Error::last_os_error();
                    if !matches!(e.raw_os_error(), Some(libc::EINTR | libc::EAGAIN)) {
                        return Err(e);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "../tests/support/uring_responses.rs"]
mod response_tests;
