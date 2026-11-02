//! Owned request buffers cross bounded queues; SQLite connections stay thread-local.
use crate::{App, Auth, Parsed, db, error, frame};
use std::{
    cell::Cell,
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread::{self, JoinHandle, Thread},
    time::{Duration, Instant},
};

// Two 8,192-job queues and one 1,024-job batch permit at most 68 MiB
// of small-buffer capacity. Charging all excess caps outstanding requests
// at 100 MiB while the usual small writes need no counter updates.
const SMALL_REQUEST: usize = 4096;
const REQUEST_BYTES: usize = 32 * 1024 * 1024;
const QUEUE_JOBS: usize = 8192;
const BATCH_JOBS: usize = 1024;
const _: () = assert!((2 * QUEUE_JOBS + BATCH_JOBS) * SMALL_REQUEST + REQUEST_BYTES <= 100 * 1024 * 1024);

#[derive(Default)]
pub(crate) struct WriteJob {
    pub ring: usize,
    pub fd: usize,
    pub generation: u32,
    pub request: Vec<u8>,
    pub body: Vec<u8>,
    pub status: u16,
    pub close: bool,
}

#[derive(Clone)]
pub(crate) struct WriteSender {
    tx: SyncSender<WriteJob>,
    thread: Thread,
    // Only the issuer admits jobs and consumes replies. Sharing this counter
    // across its rings needs no atomics or allocation per request.
    bytes: Rc<Cell<usize>>,
}

impl WriteSender {
    #[inline(always)]
    pub fn available(&self, bytes: usize) -> bool {
        let bytes = bytes.saturating_sub(SMALL_REQUEST);
        bytes == 0 || (bytes <= REQUEST_BYTES && self.bytes.get() <= REQUEST_BYTES - bytes)
    }

    pub fn try_send(&self, job: WriteJob) -> Result<(), TrySendError<WriteJob>> {
        let capacity = job.request.capacity();
        let bytes = capacity.saturating_sub(SMALL_REQUEST);
        if !self.available(capacity) {
            return Err(TrySendError::Full(job));
        }
        self.tx.try_send(job)?;
        if bytes != 0 {
            self.bytes.set(self.bytes.get() + bytes);
        }
        self.thread.unpark();
        Ok(())
    }

    #[inline(always)]
    pub fn completed(&self, job: &WriteJob) {
        // Keep the charge through execution and the reply queue, including
        // replies whose connection has already closed or reused its slot.
        let bytes = job.request.capacity().saturating_sub(SMALL_REQUEST);
        if bytes != 0 {
            self.bytes.set(self.bytes.get().checked_sub(bytes)
                .expect("outstanding write bytes"));
        }
    }
}

pub(crate) struct Writer {
    pub sender: WriteSender,
    pub replies: Option<Receiver<WriteJob>>,
    pub signal: Arc<OwnedFd>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Writer {
    pub fn new(path: String, secret: String, start: Instant, group: bool) -> io::Result<Self> {
        Self::spawn(move || App {
            db: db::Db::open(&path, group),
            auth: Auth::new(&secret),
            start,
        })
    }

    fn spawn(init: impl FnOnce() -> App + Send + 'static) -> io::Result<Self> {
        let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        if efd < 0 {
            return Err(io::Error::last_os_error());
        }
        let signal = Arc::new(unsafe { OwnedFd::from_raw_fd(efd) });
        let wake = Arc::clone(&signal);
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = Arc::clone(&stop);
        let (tx, requests) = mpsc::sync_channel::<WriteJob>(QUEUE_JOBS);
        let (replies, rx) = mpsc::sync_channel::<WriteJob>(QUEUE_JOBS);
        let (ready, started) = mpsc::sync_channel(1);
        let worker = thread::Builder::new()
            .name("sqlite-writer".into())
            .stack_size(512 * 1024)
            .spawn(move || {
                let mut app = init();
                ready.send(()).expect("writer startup receiver");
                let mut batch = Vec::with_capacity(BATCH_JOBS);
                while !stopped.load(Ordering::Acquire) {
                    app.db.checkpoint_async();
                    if app.db.draining() {
                        thread::park_timeout(Duration::from_millis(1));
                        continue;
                    }
                    let first = match requests.try_recv() {
                        Ok(job) => job,
                        Err(mpsc::TryRecvError::Empty) => {
                            thread::park_timeout(Duration::from_millis(100));
                            continue;
                        }
                        Err(mpsc::TryRecvError::Disconnected) => break,
                    };
                    batch.push(first);
                    // Gather before opening the transaction. A fixed job limit
                    // keeps work bounded even if the writer is descheduled;
                    // elapsed wall time must not fragment an already ready batch.
                    if app.db.group {
                        thread::sleep(Duration::from_millis(20));
                        batch.extend(requests.try_iter().take(BATCH_JOBS - 1));
                    }
                    for job in &mut batch {
                        let Parsed::Complete(req) =
                            frame(&job.request).expect("validated write frame")
                        else {
                            unreachable!("incomplete queued write");
                        };
                        job.body.clear();
                        job.close = req.close;
                        job.status = app.serve(&req, &mut job.body);
                    }
                    // Publish only committed responses. A failed COMMIT rolls
                    // back the transaction and replaces every tentative reply.
                    let committed = app.db.commit();
                    for mut job in batch.drain(..) {
                        if !committed {
                            job.status = error(&mut job.body, 500, "internal server error");
                        }
                        if replies.send(job).is_err() {
                            return;
                        }
                    }
                    let one = 1u64;
                    loop {
                        let rc = unsafe {
                            libc::write(wake.as_raw_fd(), (&one as *const u64).cast(), 8)
                        };
                        if rc == 8 {
                            break;
                        }
                        let e = io::Error::last_os_error();
                        if e.raw_os_error() == Some(libc::EINTR) {
                            continue;
                        }
                        // A saturated eventfd is already readable.
                        if e.raw_os_error() == Some(libc::EAGAIN) {
                            break;
                        }
                        panic!("writer eventfd: {e}");
                    }
                }
            })?;
        started.recv().expect("SQLite writer startup");
        Ok(Self {
            sender: WriteSender {
                tx,
                thread: worker.thread().clone(),
                bytes: Rc::new(Cell::new(0)),
            },
            replies: Some(rx),
            signal,
            stop,
            worker: Some(worker),
        })
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        // Wake both possible waits before joining. In particular a full reply
        // queue must not prevent teardown after the issuer returns an error.
        drop(self.replies.take());
        self.sender.thread.unpark();
        self.worker
            .take()
            .unwrap()
            .join()
            .expect("SQLite writer thread");
    }
}

#[cfg(test)]
#[path = "../tests/support/writer.rs"]
mod tests;
