;;;; libc, raw syscalls and the SQLite entry points, all through sb-alien. Pointers cross the
;;;; boundary as integers (a returned SAP is heap-allocated; an integer is not), and every routine
;;;; is inline so a call from the hot path is a bare foreign call with unboxed arguments.
;;;; No contribs: sb-alien / sb-sys / sb-kernel only.
(in-package #:feed)

(declaim (optimize (speed 1) (safety 1) (debug 0)))

;;; TD_COUNT=1 at build time (measurement build only): every Lisp->C crossing bumps a counter,
;;; dumped on SIGUSR1/SIGTERM. The shipped build compiles none of this.
#+td-count (sb-ext:defglobal **xc** (make-array 128 :element-type 'fixnum :initial-element 0))
#+td-count (eval-when (:compile-toplevel :load-toplevel :execute)
             (defvar *xc-names* (make-array 128 :initial-element nil))
             (defvar *xc-n* 0)
             (defun xc-index (name)
               (or (position name *xc-names* :test #'equal)
                   (progn (setf (aref *xc-names* *xc-n*) name) (prog1 *xc-n* (incf *xc-n*))))))

(defmacro defalien (lisp-name c-name ret &rest args)
  #-td-count
  `(progn (declaim (inline ,lisp-name))
          (sb-alien:define-alien-routine (,c-name ,lisp-name) ,ret ,@args))
  #+td-count
  (let ((raw (intern (format nil "RAW~A" lisp-name))) (idx (xc-index c-name)) (names (mapcar #'car args)))
    `(progn (declaim (inline ,raw ,lisp-name))
            (sb-alien:define-alien-routine (,c-name ,raw) ,ret ,@args)
            (defun ,lisp-name ,names (incf (aref **xc** ,idx)) (,raw ,@names)))))

;;; ---- libc --------------------------------------------------------------------------------
(defalien %socket "socket" sb-alien:int (domain sb-alien:int) (type sb-alien:int) (protocol sb-alien:int))
(defalien %setsockopt "setsockopt" sb-alien:int
  (fd sb-alien:int) (level sb-alien:int) (name sb-alien:int) (val sb-alien:unsigned-long) (len sb-alien:unsigned-int))
(defalien %bind "bind" sb-alien:int (fd sb-alien:int) (addr sb-alien:unsigned-long) (len sb-alien:unsigned-int))
(defalien %listen "listen" sb-alien:int (fd sb-alien:int) (backlog sb-alien:int))
(defalien %close "close" sb-alien:int (fd sb-alien:int))
(defalien %malloc "malloc" sb-alien:unsigned-long (n sb-alien:unsigned-long))
(defalien %realloc "realloc" sb-alien:unsigned-long (p sb-alien:unsigned-long) (n sb-alien:unsigned-long))
(defalien %free "free" sb-alien:void (p sb-alien:unsigned-long))
(defalien %memmove "memmove" sb-alien:unsigned-long
  (dst sb-alien:unsigned-long) (src sb-alien:unsigned-long) (n sb-alien:unsigned-long))
(defalien %memset "memset" sb-alien:unsigned-long
  (dst sb-alien:unsigned-long) (c sb-alien:int) (n sb-alien:unsigned-long))
(defalien %mmap "mmap" sb-alien:unsigned-long
  (addr sb-alien:unsigned-long) (len sb-alien:unsigned-long) (prot sb-alien:int) (flags sb-alien:int)
  (fd sb-alien:int) (off sb-alien:long))
(defalien %mlock "mlock" sb-alien:int (addr sb-alien:unsigned-long) (len sb-alien:unsigned-long))
(defalien %clock-gettime "clock_gettime" sb-alien:int (clk sb-alien:int) (ts sb-alien:unsigned-long))
(defalien %getrlimit "getrlimit" sb-alien:int (res sb-alien:int) (rl sb-alien:unsigned-long))
(defalien %setrlimit "setrlimit" sb-alien:int (res sb-alien:int) (rl sb-alien:unsigned-long))
(defalien %signal "signal" sb-alien:unsigned-long (sig sb-alien:int) (handler sb-alien:unsigned-long))
(defalien %syscall6 "syscall" sb-alien:long
  (nr sb-alien:long) (a sb-alien:long) (b sb-alien:long) (c sb-alien:long)
  (d sb-alien:long) (e sb-alien:long) (f sb-alien:long))


(defconstant +sys-io-uring-setup+ 425)
(defconstant +sys-io-uring-enter+ 426)
(defconstant +sys-io-uring-register+ 427)

;;; ---- the raw syscall as a VOP (Phase A, M7) ---------------------------------------------------
;;; One x86-64 `syscall` instruction, arguments in rax/rdi/rsi/rdx/r10/r8/r9, result in rax. The
;;; kernel returns -errno in rax on failure, and that is what comes back (no errno global, no libc
;;; wrapper, no foreign-call frame). rcx and r11 are clobbered by the instruction and declared so.
;;; Used for io_uring_enter, the one syscall on the hot path; setup/register stay on libc.
(in-package "SB-VM")
(eval-when (:compile-toplevel :execute)   ; build.lisp compiles and loads in one image, which is then saved
  (sb-c:defknown feed::%raw-syscall6 ((signed-byte 64) (signed-byte 64) (signed-byte 64) (signed-byte 64)
                                      (signed-byte 64) (signed-byte 64) (signed-byte 64))
      (signed-byte 64) (sb-c:always-translatable)))
(eval-when (:compile-toplevel :execute)
(define-vop (feed::%raw-syscall6)
  (:policy :fast-safe)
  (:translate feed::%raw-syscall6)
  (:args (nr :scs (signed-reg) :target rax) (a :scs (signed-reg) :target rdi)
         (b :scs (signed-reg) :target rsi) (c :scs (signed-reg) :target rdx)
         (d :scs (signed-reg) :target r10) (e :scs (signed-reg) :target r8)
         (f :scs (signed-reg) :target r9))
  (:arg-types signed-num signed-num signed-num signed-num signed-num signed-num signed-num)
  (:temporary (:sc signed-reg :offset rax-offset :from (:argument 0) :to :result) rax)
  (:temporary (:sc signed-reg :offset rdi-offset :from (:argument 1)) rdi)
  (:temporary (:sc signed-reg :offset rsi-offset :from (:argument 2)) rsi)
  (:temporary (:sc signed-reg :offset rdx-offset :from (:argument 3)) rdx)
  (:temporary (:sc signed-reg :offset r10-offset :from (:argument 4)) r10)
  (:temporary (:sc signed-reg :offset r8-offset :from (:argument 5)) r8)
  (:temporary (:sc signed-reg :offset r9-offset :from (:argument 6)) r9)
  (:temporary (:sc signed-reg :offset rcx-offset) rcx)
  (:temporary (:sc signed-reg :offset r11-offset) r11)
  (:results (res :scs (signed-reg)))
  (:result-types signed-num)
  (:generator 5
    (move rax nr) (move rdi a) (move rsi b) (move rdx c) (move r10 d) (move r8 e) (move r9 f)
    (inst syscall)
    (move res rax))))
(in-package #:feed)

(declaim (inline %enter-syscall))
(defun %enter-syscall (fd to-submit min-complete flags arg argsz)
  "io_uring_enter. Returns the result, or -errno."
  (declare (type (signed-byte 64) fd to-submit min-complete flags arg argsz))
  #+td-count (incf (aref **xc** #.(xc-index "io_uring_enter (VOP)")))
  (%raw-syscall6 +sys-io-uring-enter+ fd to-submit min-complete flags arg argsz))

(defconstant +af-inet+ 2)
(defconstant +sock-stream+ 1)
(defconstant +sock-cloexec+ #x80000)
(defconstant +sol-socket+ 1)
(defconstant +so-reuseaddr+ 2)
(defconstant +so-reuseport+ 15)
(defconstant +ipproto-tcp+ 6)
(defconstant +tcp-nodelay+ 1)
(defconstant +msg-nosignal+ #x4000)
(defconstant +eintr+ 4)
(defconstant +eagain+ 11)
(defconstant +ebusy+ 16)
(defconstant +einval+ 22)
(defconstant +enfile+ 23)
(defconstant +etime+ 62)
(defconstant +enobufs+ 105)
(defconstant +prot-rw+ 3)
(defconstant +map-private-anon+ #x22)
(defconstant +map-shared-populate+ #x8001)
(defconstant +map-failed+ #.(1- (ash 1 64)))
(defconstant +clock-realtime+ 0)
(defconstant +clock-monotonic+ 1)
(defconstant +rlimit-nofile+ 7)
(defconstant +sigpipe+ 13)

(declaim (inline foreign-alloc))
(defun foreign-alloc (n)
  (declare (type index n))
  (let ((p (%malloc n)))
    (when (zerop p) (error "malloc(~D) failed" n))
    p))

(defun zeroed-alloc (n)
  "Zeroed memory straight from the kernel: pages that are never touched cost nothing."
  (let ((p (%mmap 0 n +prot-rw+ +map-private-anon+ -1 0)))
    (when (= p +map-failed+) (error "mmap(~D) failed" n))
    p))

(defalien %munmap "munmap" sb-alien:int (p sb-alien:unsigned-long) (n sb-alien:unsigned-long))
(defun %mmap-free (p n) (%munmap p n))

(declaim (inline copy-octets-in))
(defun copy-octets-in (src dst dst-offset n)
  "Octet vector SRC[0,N) into foreign memory at DST+DST-OFFSET."
  (declare (type octets src) (type addr dst) (type index dst-offset n))
  (sb-kernel:copy-ub8-to-system-area src 0 (sb-sys:int-sap dst) dst-offset n))

(defun copy-sap-to-octets (src n)
  (let ((v (make-array n :element-type 'u8)))
    (sb-kernel:copy-ub8-from-system-area (sb-sys:int-sap src) 0 v 0 n)
    v))

;;; ---- SQLite (symbols exported by build/shim.so) -------------------------------------------
(defalien %shim-open "shim_open" sb-alien:unsigned-long
  (path sb-alien:c-string) (err sb-alien:unsigned-long) (n sb-alien:int))
(defalien %shim-prepare "shim_prepare" sb-alien:unsigned-long
  (db sb-alien:unsigned-long) (sql sb-alien:c-string) (err sb-alien:unsigned-long) (n sb-alien:int))
(defalien %step "sqlite3_step" sb-alien:int (st sb-alien:unsigned-long))
(defalien %reset "sqlite3_reset" sb-alien:int (st sb-alien:unsigned-long))
(defalien %bind-int64 "sqlite3_bind_int64" sb-alien:int
  (st sb-alien:unsigned-long) (i sb-alien:int) (v (sb-alien:signed 64)))
(defalien %bind-text "sqlite3_bind_text" sb-alien:int
  (st sb-alien:unsigned-long) (i sb-alien:int) (p sb-alien:unsigned-long) (n sb-alien:int)
  (destructor sb-alien:unsigned-long))
(defalien %column-int64 "sqlite3_column_int64" (sb-alien:signed 64) (st sb-alien:unsigned-long) (i sb-alien:int))
(defalien %column-text "sqlite3_column_text" sb-alien:unsigned-long (st sb-alien:unsigned-long) (i sb-alien:int))
(defalien %column-bytes "sqlite3_column_bytes" sb-alien:int (st sb-alien:unsigned-long) (i sb-alien:int))
(defalien %changes "sqlite3_changes" sb-alien:int (db sb-alien:unsigned-long))
(defalien %errmsg "sqlite3_errmsg" sb-alien:unsigned-long (db sb-alien:unsigned-long))

(defconstant +sqlite-row+ 100)
(defconstant +sqlite-done+ 101)

;;; ---- the idle-priority helper thread (csrc/shim.c) ----------------------------------------
;;; Pure C: it never touches the Lisp heap, so a GC never has to stop it.
(defalien %td-start-helper "td_start_helper" sb-alien:int
  (path sb-alien:c-string) (stats-on sb-alien:int))
(defalien %td-stats-addr "td_stats_addr" sb-alien:unsigned-long)
(defalien %td-policy "td_helper_policy" sb-alien:int)

;;; ---- B-tree cursor reads (csrc/shim.c, PR #153) ----------------------------------------------
(defalien %td-bt-init "td_bt_init" sb-alien:int (err sb-alien:unsigned-long) (n sb-alien:int))
(defalien %td-bt-open-cursors "td_bt_open_cursors" sb-alien:int)
(defalien %td-bt-close-cursors "td_bt_close_cursors" sb-alien:void)
(defalien %td-in-txn "td_in_txn" sb-alien:int)
(defalien %td-cursor "td_cursor" sb-alien:unsigned-long (i sb-alien:int))
(defalien %td-seek "td_seek" sb-alien:int (c sb-alien:unsigned-long) (id (sb-alien:signed 64)))
(defalien %td-first "td_first" sb-alien:int (c sb-alien:unsigned-long))
(defalien %td-next "td_next" sb-alien:int (c sb-alien:unsigned-long))
(defalien %td-payload "td_payload" sb-alien:unsigned-long (c sb-alien:unsigned-long) (len sb-alien:unsigned-long))
(defalien %td-count-likes "td_count_likes" sb-alien:int
  (c sb-alien:unsigned-long) (lo (sb-alien:signed 64)) (hi (sb-alien:signed 64)) (n sb-alien:unsigned-long))
