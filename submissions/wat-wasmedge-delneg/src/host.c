// host.c: a thin WasmEdge embedder. It runs the AOT-compiled app (hand-written WAT plus stock SQLite) with
// WASI for SQLite's file I/O, and gives it a few raw Linux calls as the "sys" import module: `listen`, and
// io_uring setup (ring_new: the rings and their sparse fixed-file tables; ring_pbuf: a provided-buffer ring
// in wasm memory) and one submit/reap call (ring_go: copies the SQEs the WAT wrote into the ring, enters,
// copies the CQEs back); WASI's poll_oneoff would re-register every connection on every call. No request
// logic lives here:
// the WAT builds every SQE and reads every CQE. One helper thread fdatasyncs the WAL file every 100 ms
// (see walsync below). A second runs the same app.so in its own VM as the checkpointer (ckthread): the
// shm_*, ck_* and nap imports give the two instances shared memory for the wal-index, atomics and a futex.
#define _GNU_SOURCE
#include <wasmedge/wasmedge.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <libgen.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/io_uring.h>
#include <sys/mman.h>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define P(i) WasmEdge_ValueGetI32(in[i])
#define RET(v) do { out[0] = WasmEdge_ValueGenI32((int32_t)(v)); return WasmEdge_Result_Success; } while (0)
#define FN(name) static WasmEdge_Result name(void *d, const WasmEdge_CallingFrameContext *f, \
                                             const WasmEdge_Value *in, WasmEdge_Value *out)
static inline uint8_t *mem(const WasmEdge_CallingFrameContext *f, uint32_t off, uint32_t len) {
  return WasmEdge_MemoryInstanceGetPointer(WasmEdge_CallingFrameGetMemoryInstance(f, 0), off, len);
}
static inline int32_t rv(long r) { return r < 0 ? -errno : (int32_t)r; }

// listen(ip as s_addr, port, backlog) -> fd | -errno
FN(h_listen) { (void)d; (void)f;
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0); if (fd < 0) RET(-errno);
  int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  const char *nd = getenv("NODELAY"); if (!nd || *nd != '0') setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((uint16_t)P(1)); a.sin_addr.s_addr = (uint32_t)P(0);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, P(2)) < 0) { int e = errno; close(fd); RET(-e); }
  RET(fd);
}
// ---- io_uring, raw syscalls. The WAT builds every submission entry (SQE) itself in its own memory and reads
// the completions (CQEs) back as plain bytes; these calls only move them between wasm memory and the
// kernel's ring buffers. Ring k: up to 16, ring 0 is the one the WAT waits on.
typedef struct {
  int fd; unsigned sq_entries, sq_mask, cq_mask, pending;
  unsigned *sq_head, *sq_tail, *sq_flags, *cq_head, *cq_tail;
  struct io_uring_sqe *sqes; struct io_uring_cqe *cqes; uint16_t *pbuf_tail;
} Ring;
static Ring R[16];
static long enter(Ring *r, unsigned sub, unsigned wait, unsigned flags, int timeout_us) {
  struct __kernel_timespec ts = {timeout_us / 1000000, (long long)(timeout_us % 1000000) * 1000};
  struct io_uring_getevents_arg ga = {0, _NSIG / 8, 0, timeout_us >= 0 ? (uint64_t)(uintptr_t)&ts : 0};
  if (flags & IORING_ENTER_GETEVENTS) flags |= IORING_ENTER_EXT_ARG;
  long n = syscall(__NR_io_uring_enter, r->fd, sub, wait, flags, flags & IORING_ENTER_EXT_ARG ? &ga : NULL, sizeof ga);
  if (n > 0) r->pending -= (unsigned)n > r->pending ? r->pending : (unsigned)n;
  return n < 0 ? -errno : n;
}
// ring_new(k, out) -> 0 | -errno: sets up ring k (4096 SQEs, 16384 CQEs; ring 0 runs its completions
// only when waited on: DEFER_TASKRUN) and a sparse fixed-file table as large as RLIMIT_NOFILE allows
// (up to 65535); writes (ring fd, table size) at out
FN(h_ring_new) { (void)d;
  int k = P(0); int32_t *o = (int32_t *)mem(f, (uint32_t)P(1), 8); if (k < 0 || k >= 16 || !o) RET(-EINVAL);
  Ring *r = &R[k]; struct io_uring_params p; memset(&p, 0, sizeof p);
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SUBMIT_ALL | IORING_SETUP_CQSIZE |
            (k == 0 ? IORING_SETUP_DEFER_TASKRUN : 0);
  p.cq_entries = 16384;
  int fd = (int)syscall(__NR_io_uring_setup, 4096, &p); if (fd < 0) RET(-errno);
  size_t sl = p.sq_off.array + p.sq_entries * 4, cl = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  if (p.features & IORING_FEAT_SINGLE_MMAP) sl = cl = sl > cl ? sl : cl;
  uint8_t *sq = mmap(0, sl, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  uint8_t *cq = p.features & IORING_FEAT_SINGLE_MMAP ? sq : mmap(0, cl, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
  void *sqes = mmap(0, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
  if (sq == MAP_FAILED || cq == MAP_FAILED || sqes == MAP_FAILED) { int e = errno; close(fd); RET(-e); }
  r->fd = fd; r->sq_entries = p.sq_entries; r->sqes = sqes; r->pending = 0;
  r->sq_head = (unsigned *)(sq + p.sq_off.head); r->sq_tail = (unsigned *)(sq + p.sq_off.tail);
  r->sq_mask = *(unsigned *)(sq + p.sq_off.ring_mask); r->sq_flags = (unsigned *)(sq + p.sq_off.flags);
  unsigned *arr = (unsigned *)(sq + p.sq_off.array); for (unsigned i = 0; i < p.sq_entries; i++) arr[i] = i;
  r->cq_head = (unsigned *)(cq + p.cq_off.head); r->cq_tail = (unsigned *)(cq + p.cq_off.tail);
  r->cq_mask = *(unsigned *)(cq + p.cq_off.ring_mask); r->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
  struct rlimit rl; unsigned n = getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < 65535 ? (unsigned)rl.rlim_cur : 65535;
  struct io_uring_rsrc_register rr; memset(&rr, 0, sizeof rr); rr.nr = n; rr.flags = IORING_RSRC_REGISTER_SPARSE;
  if (syscall(__NR_io_uring_register, fd, IORING_REGISTER_FILES2, &rr, sizeof rr) < 0) RET(-errno);
  o[0] = fd; o[1] = (int32_t)n; RET(0);
}
// ring_pbuf(k, off, entries, group) -> 0 | -errno: registers the provided-buffer ring that the WAT keeps at
// [off, off + 16 * entries) (page aligned). Ubuntu's 6.8.0-147 kernel refuses the registration when its
// reserved words are all zero (an inverted check), so a refusal is retried once with resv[0] = 1.
FN(h_ring_pbuf) { (void)d;
  Ring *r = &R[P(0) & 15]; uint8_t *p = mem(f, (uint32_t)P(1), (uint32_t)P(2) * 16); if (!p) RET(-EFAULT);
  struct io_uring_buf_reg g; memset(&g, 0, sizeof g);
  g.ring_addr = (uint64_t)(uintptr_t)p; g.ring_entries = (uint32_t)P(2); g.bgid = (uint16_t)P(3);
  if (syscall(__NR_io_uring_register, r->fd, IORING_REGISTER_PBUF_RING, &g, 1) < 0) {
    int e = errno; g.resv[0] = 1;
    if (syscall(__NR_io_uring_register, r->fd, IORING_REGISTER_PBUF_RING, &g, 1) < 0) RET(-e);
  }
  r->pbuf_tail = (uint16_t *)(p + 14); RET(0);
}
// ring_go(k, desc, cqes, max, wait, timeout_us) -> number of CQEs copied to cqes (16 bytes each, up to max).
// desc = (SQE array offset, SQE count, buffer-ring tail): publishes the tail, copies the SQEs into the ring
// and zeroes the count, then calls io_uring_enter if there is anything to submit or wait >= 0 (waiting for
// that many completions, at most timeout_us; -1: none), and copies out the completions.
FN(h_ring_go) { (void)d;
  Ring *r = &R[P(0) & 15]; int32_t *ds = (int32_t *)mem(f, (uint32_t)P(1), 12); if (!ds) RET(-EFAULT);
  unsigned n = (unsigned)ds[1], max = (unsigned)P(3); int wait = P(4);
  uint8_t *src = mem(f, (uint32_t)ds[0], n ? n * 64 : 1), *cqo = mem(f, (uint32_t)P(2), max ? max * 16 : 1);
  if (!src || !cqo) RET(-EFAULT);
  if (r->pbuf_tail) __atomic_store_n(r->pbuf_tail, (uint16_t)ds[2], __ATOMIC_RELEASE);
  unsigned tail = *r->sq_tail;
  for (unsigned i = 0; i < n;) {
    unsigned room = r->sq_entries - (tail - __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE));
    if (!room) { enter(r, r->pending, 0, 0, -1); continue; }
    for (; room && i < n; room--, i++, tail++, r->pending++) memcpy(&r->sqes[tail & r->sq_mask], src + 64 * i, 64);
    __atomic_store_n(r->sq_tail, tail, __ATOMIC_RELEASE);
  }
  ds[1] = 0;
  if (r->pending || wait >= 0) enter(r, r->pending, wait < 0 ? 0 : (unsigned)wait, wait >= 0 ? IORING_ENTER_GETEVENTS : 0, P(5));
  unsigned got = 0;
  for (int pass = 0; pass < 2; pass++) {
    unsigned h = *r->cq_head, t = __atomic_load_n(r->cq_tail, __ATOMIC_ACQUIRE);
    for (; h != t && got < max; h++, got++) memcpy(cqo + 16 * got, &r->cqes[h & r->cq_mask], 16);
    __atomic_store_n(r->cq_head, h, __ATOMIC_RELEASE);
    // completions the CQ had no room for wait in the kernel until an enter flushes them
    if (got == max || !(__atomic_load_n(r->sq_flags, __ATOMIC_ACQUIRE) & IORING_SQ_CQ_OVERFLOW)) break;
    enter(r, 0, 0, IORING_ENTER_GETEVENTS, -1);
  }
  RET(got);
}
// membase() -> the native address of wasm memory offset 0, which the kernel needs for buffer addresses.
// WasmEdge reserves the whole 4 GiB range up front and grows memory in place, so it never moves.
FN(h_membase) { (void)d; (void)in; out[0] = WasmEdge_ValueGenI64((int64_t)(uintptr_t)mem(f, 0, 1)); return WasmEdge_Result_Success; }

// ---- H1 (TdscWat4 experiment): a second instance of the app runs SQLite's checkpoints on its own thread, sharing
// the wal-index with the loop's instance (src/sqlite_glue.c). shm_map maps one memfd into the calling instance's
// memory at a page-aligned offset; L[] holds the shm lock words and the checkpoint handshake (real atomics).
static int L[16], shmfd = -1;
FN(h_shm_map) { (void)d;
  uint32_t len = (uint32_t)P(1); uint8_t *p = mem(f, (uint32_t)P(0), len); if (!p || ((uintptr_t)p & 4095)) RET(-EINVAL);
  if (shmfd < 0 && ((shmfd = memfd_create("walidx", MFD_CLOEXEC)) < 0 || ftruncate(shmfd, len))) RET(-errno);
  if (mmap(p, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, shmfd, 0) == MAP_FAILED) RET(-errno);
  RET(0);
}
FN(h_shm_cas) { (void)d; (void)f; int o = P(1); __atomic_compare_exchange_n(&L[P(0) & 15], &o, P(2), 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); RET(o); }
FN(h_shm_add) { (void)d; (void)f; RET(__atomic_fetch_add(&L[P(0) & 15], P(1), __ATOMIC_SEQ_CST)); }
// shm_lock(ofst, n, flags, role) -> 0 | SQLITE_BUSY: SQLite's xShmLock on the words L[0..7] (n > 0: shared count,
// -1: exclusive), with each role's held locks kept here, so one call per lock change
static unsigned hs[2], hx[2];
FN(h_shm_lock) { (void)d; (void)f;
  int o = P(0), n = P(1), fl = P(2), r = P(3) & 1; unsigned acq = 0;
  for (int i = o; i < o + n && i < 8; i++) {
    unsigned b = 1u << i; int v = 0;
    if (fl & 1) { if (hs[r] & b) __atomic_fetch_sub(&L[i], 1, __ATOMIC_SEQ_CST); if (hx[r] & b) __atomic_store_n(&L[i], 0, __ATOMIC_SEQ_CST); hs[r] &= ~b; hx[r] &= ~b; continue; }
    if (fl & 4) {
      if (hs[r] & b) continue;
      v = __atomic_load_n(&L[i], __ATOMIC_SEQ_CST);
      do { if (v < 0) RET(5); } while (!__atomic_compare_exchange_n(&L[i], &v, v + 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST));
      hs[r] |= b; continue;
    }
    if (hx[r] & b) continue;
    if (!__atomic_compare_exchange_n(&L[i], &v, -1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
      for (int j = o; j < i; j++) if (acq & (1u << j)) __atomic_store_n(&L[j], 0, __ATOMIC_SEQ_CST);
      hx[r] &= ~acq; RET(5);
    }
    hx[r] |= b; acq |= b;
  }
  RET(0);
}
// ck_wait(): the checkpointer sleeps until L[9] (its state word) is 1; ck_wake(): the loop wakes it
FN(h_ck_wait) { (void)d; (void)f; (void)in;
  for (int v; (v = __atomic_load_n(&L[9], __ATOMIC_SEQ_CST)) != 1;) syscall(SYS_futex, &L[9], FUTEX_WAIT_PRIVATE, v, NULL, NULL, 0);
  RET(0);
}
FN(h_ck_wake) { (void)d; (void)f; (void)in; syscall(SYS_futex, &L[9], FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0); RET(0); }
FN(h_nap) { (void)d; (void)f; usleep((useconds_t)P(0)); RET(0); }
static WasmEdge_VMContext *mkvm(const char *app);
static const char *appso;
static void *ckthread(void *a) {
  (void)a; const char *nv = getenv("CKPT_NICE"); setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), nv ? atoi(nv) : 0);
  WasmEdge_VMContext *vm = mkvm(appso);
  WasmEdge_String fn[2] = {WasmEdge_StringCreateByCString("_initialize"), WasmEdge_StringCreateByCString("ckpt_main")};
  WasmEdge_Result r = WasmEdge_VMLoadWasmFromFile(vm, appso);
  if (WasmEdge_ResultOK(r)) r = WasmEdge_VMValidate(vm);
  if (WasmEdge_ResultOK(r)) r = WasmEdge_VMInstantiate(vm);
  if (WasmEdge_ResultOK(r)) r = WasmEdge_VMExecute(vm, fn[0], NULL, 0, NULL, 0);
  if (WasmEdge_ResultOK(r)) r = WasmEdge_VMExecute(vm, fn[1], NULL, 0, NULL, 0);
  fprintf(stderr, "checkpointer stopped: %s\n", WasmEdge_ResultGetMessage(r));
  return NULL;
}
FN(h_ckpt_spawn) { (void)d; (void)f; (void)in; pthread_t t; RET(-pthread_create(&t, NULL, ckthread, NULL)); }

static void add(WasmEdge_ModuleInstanceContext *m, const char *name, WasmEdge_HostFunc_t fn, int np) {
  WasmEdge_ValType p[6], r[1] = {np < 0 ? WasmEdge_ValTypeGenI64() : WasmEdge_ValTypeGenI32()};
  if (np < 0) np = 0;
  for (int i = 0; i < np; i++) p[i] = WasmEdge_ValTypeGenI32();
  WasmEdge_FunctionTypeContext *t = WasmEdge_FunctionTypeCreate(p, (uint32_t)np, r, 1);
  WasmEdge_String s = WasmEdge_StringCreateByCString(name);
  WasmEdge_ModuleInstanceAddFunction(m, s, WasmEdge_FunctionInstanceCreate(t, fn, NULL, 0));
  WasmEdge_StringDelete(s); WasmEdge_FunctionTypeDelete(t);
}

// WAL flusher: with synchronous=NORMAL, a checkpoint first fsyncs the WAL, which by then holds up to
// 64 MiB written since the last one, and the event loop waits for it. This thread fdatasyncs the WAL
// file (its own fd: the sync covers the file, whoever wrote it) every 100 ms, so that sync finds little
// left to write. It only makes data durable sooner; SQLite still does every sync it would do anyway.
static char *walpath; static int walms, walon = 1;

// Code pinning. On a 2 GB box with ~250k connections the sockets take ~1 GB of kernel memory and the kernel
// evicts file pages, our machine code among them; the one loop thread then waits on disk for every evicted
// page while requests pile up in the sockets. mlock keeps the code in memory: all of app.so's code, then the
// pages of the other libraries' code that are in memory by then (the ones in use), until RLIMIT_MEMLOCK is
// reached (8 MiB by default; the code in use is ~7 MiB). Repeated for the first minute, while the hot
// paths come into use. PIN=0 turns it off (A/B runs).
static int pinfull = 1;
static void pincode(const char *app) {
  FILE *f = fopen("/proc/self/maps", "r"); if (!f) return;
  char line[512]; long ps = sysconf(_SC_PAGESIZE);
  for (int pass = 0; pass < 2 && pinfull; pass++) {   // pass 0: app.so, pass 1: the rest
    rewind(f);
    while (fgets(line, sizeof line, f) && pinfull) {
      unsigned long lo, hi; char perm[8]; int off = 0;
      if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &lo, &hi, perm, &off) < 3 || perm[2] != 'x' || !off) continue;
      char *path = line + off; path[strcspn(path, "\n")] = 0; if (path[0] != '/') continue;
      if ((strstr(path, app) != NULL) != (pass == 0)) continue;
      if (pass == 0) { if (mlock((void *)lo, hi - lo)) pinfull = 0; continue; }
      size_t n = (hi - lo) / ps; unsigned char *v = malloc(n); if (!v) continue;
      if (!mincore((void *)lo, hi - lo, v))
        for (size_t i = 0; i < n && pinfull; i++)
          if ((v[i] & 1) && mlock((void *)(lo + i * ps), ps)) pinfull = 0;
      free(v);
    }
  }
  fclose(f);
}
static void *walsync(void *a) {
  (void)a; int fd = -1; const char *pv = getenv("PIN"); long t = 0;
  const char *wv = getenv("WALSYNC"); if (wv && *wv == '0') walon = 0;   // off: this thread only pins code
  if (pv && *pv == '0') pinfull = 0;
  const char *b = strrchr(appso, '/'); b = b ? b + 1 : appso;
  for (;; t += walms) {
    usleep((useconds_t)walms * 1000);
    if (pinfull && t % 5000 < walms && t <= 60000) pincode(b);
    if (fd < 0) fd = open(walpath, O_RDONLY | O_CLOEXEC);
    if (fd >= 0 && walon) fdatasync(fd);
  }
  return NULL;
}

static WasmEdge_VMContext *mkvm(const char *app) {
  WasmEdge_ConfigureContext *conf = WasmEdge_ConfigureCreate();
  WasmEdge_ConfigureAddHostRegistration(conf, WasmEdge_HostRegistration_Wasi);
  WasmEdge_ConfigureSetRunMode(conf, WasmEdge_RunMode_AOT);   // load the AOT-compiled native code
  WasmEdge_VMContext *vm = WasmEdge_VMCreate(conf, NULL);

  // WASI: the SPEC's env vars, and the database's directory pre-opened at the same path
  static const char *names[] = {"SQLITE_PATH", "JWT_SECRET", "HOST", "PORT", "CKPT_FRAMES", "CKPT_AUTO", "SHMX", "CKPT_TAIL", "CKPT_HOLD", "CKPT_LOG", "SPIN_NS"};
  const char *envs[11]; int ne = 0;
  for (int i = 0; i < 10; i++) {
    const char *v = getenv(names[i]); if (!v) continue;
    char *e = malloc(strlen(names[i]) + strlen(v) + 2); sprintf(e, "%s=%s", names[i], v); envs[ne++] = e;
  }
  const char *sp = getenv("SQLITE_PATH");
  char *dir = dirname(strdup(sp ? sp : "./x")), *pre = malloc(2 * strlen(dir) + 2);
  sprintf(pre, "%s:%s", dir, dir);
  const char *pres[] = {pre}, *args[] = {app};
  WasmEdge_ModuleInstanceInitWASI(WasmEdge_VMGetImportModuleContext(vm, WasmEdge_HostRegistration_Wasi),
                                  args, 1, envs, (uint32_t)ne, pres, 1);

  WasmEdge_String sys = WasmEdge_StringCreateByCString("sys");
  WasmEdge_ModuleInstanceContext *m = WasmEdge_ModuleInstanceCreate(sys);
  add(m, "listen", h_listen, 3); add(m, "ring_new", h_ring_new, 2); add(m, "ring_pbuf", h_ring_pbuf, 4);
  add(m, "ring_go", h_ring_go, 6); add(m, "membase", h_membase, -1);
  add(m, "shm_map", h_shm_map, 2); add(m, "shm_cas", h_shm_cas, 3); add(m, "shm_add", h_shm_add, 2);
  add(m, "nap", h_nap, 1); add(m, "ckpt_spawn", h_ckpt_spawn, 0);
  add(m, "shm_lock", h_shm_lock, 4); add(m, "ck_wait", h_ck_wait, 0); add(m, "ck_wake", h_ck_wake, 0);
  WasmEdge_Result r = WasmEdge_VMRegisterModuleFromImport(vm, m);
  if (!WasmEdge_ResultOK(r)) { fprintf(stderr, "register: %s\n", WasmEdge_ResultGetMessage(r)); return NULL; }

  return vm;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s app.so\n", argv[0]); return 2; }
  signal(SIGPIPE, SIG_IGN);
  struct rlimit rl; if (getrlimit(RLIMIT_NOFILE, &rl) == 0) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }
  appso = argv[1];
  WasmEdge_VMContext *vm = mkvm(argv[1]); if (!vm) return 1;
  const char *sp = getenv("SQLITE_PATH");
  const char *wm = getenv("WALSYNC_MS"); walms = wm ? atoi(wm) : 100;   // 0: off (for A/B runs)
  if (sp && walms > 0) {
    walpath = malloc(strlen(sp) + 5); sprintf(walpath, "%s-wal", sp);
    pthread_t th; pthread_create(&th, NULL, walsync, NULL);
  }
  WasmEdge_String start = WasmEdge_StringCreateByCString("_start");
  WasmEdge_Result r = WasmEdge_VMRunWasmFromFile(vm, argv[1], start, NULL, 0, NULL, 0);
  if (!WasmEdge_ResultOK(r)) { fprintf(stderr, "wasm: %s\n", WasmEdge_ResultGetMessage(r)); return 1; }
  return 0;
}
