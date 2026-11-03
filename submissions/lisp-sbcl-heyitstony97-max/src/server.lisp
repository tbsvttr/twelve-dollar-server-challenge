;;;; The event loop (M2): io_uring through raw syscalls, one thread, no liburing.
;;;;
;;;; Rings: DEFER_TASKRUN | SINGLE_ISSUER, direct descriptors (a registered sparse file table per
;;;; ring, so an accepted socket never takes a process fd), multishot accept on 8 SO_REUSEPORT
;;;; listeners, multishot receive into a provided-buffer ring. A ring holds 65,535 connections;
;;;; when its table is full another ring is added and accepts move there.
;;;;
;;;; One pass of the loop:
;;;;   1. enter every ring (ring 0 last, and it waits), so sends queued by the last pass go out;
;;;;   2. DRAIN FIRST: take up to +read-cap+ completions from the kernel, copy each received chunk
;;;;      into a per-connection pending buffer and hand the receive buffer back at once, so the
;;;;      kernel's socket memory is freed even when answers lag;
;;;;   3. ANSWER OLDEST FIRST: connections with unanswered bytes wait in a FIFO stamped with the time
;;;;      they were read; pop in that order, at most the adaptive cap per pass, and stop early when
;;;;      the pass has run past the turn target;
;;;;   4. GROUP COMMIT: all writes of the pass share one transaction; the sends are queued only
;;;;      after COMMIT returns (a failed commit rolls back and every write gets a 500).
;;;; The queue policies read only server state and timings (tune.lisp), never route or client.
(in-package #:feed)

(declaim (optimize (speed 1) (safety 1) (debug 0)))

(defun log-line (fmt &rest args)
  (apply #'format *error-output* fmt args)
  (terpri *error-output*)
  (finish-output *error-output*))

;;; ---- constants -----------------------------------------------------------------------------
(defconstant +iou-accept+ 13)
(defconstant +iou-close+ 19)
(defconstant +iou-send+ 26)
(defconstant +iou-recv+ 27)
(defconstant +iou-shutdown+ 34)

(defconstant +op-accept+ 1)
(defconstant +op-recv+ 2)
(defconstant +op-send+ 3)
(defconstant +op-shutdown+ 4)
(defconstant +op-close+ 5)

(defconstant +sqe-fixed-file+ 1)
(defconstant +sqe-hardlink+ 8)
(defconstant +sqe-buffer-select+ 32)
(defconstant +cqe-buffer+ 1)
(defconstant +cqe-more+ 2)

(defconstant +setup-flags+ (logior (ash 1 3) (ash 1 7) (ash 1 12) (ash 1 13))) ; CQSIZE SUBMIT_ALL SINGLE_ISSUER DEFER_TASKRUN

;;; ring record: 32 words of 8 bytes
(defconstant +f-fd+ 0)
(defconstant +f-sq-head+ 1)        ; address of the kernel's SQ head
(defconstant +f-sq-tailp+ 2)       ; address of the shared SQ tail
(defconstant +f-sq-mask+ 3)
(defconstant +f-sqes+ 4)
(defconstant +f-sq-entries+ 5)
(defconstant +f-cq-head+ 6)
(defconstant +f-cq-tail+ 7)
(defconstant +f-cq-mask+ 8)
(defconstant +f-cqes+ 9)
(defconstant +f-conns+ 10)
(defconstant +f-bufring+ 11)
(defconstant +f-bufs+ 12)
(defconstant +f-btail+ 13)
(defconstant +f-ltail+ 14)         ; local SQ tail
(defconstant +f-open+ 15)          ; connections open on this ring
(defconstant +f-alive+ 16)         ; multishot accepts still running here
(defconstant +f-full+ 17)          ; the descriptor table is full

;;; connection flags
(defconstant +cf-busy+ 1)          ; a send is in flight
(defconstant +cf-close+ 2)         ; close after the current send / answer
(defconstant +cf-cont+ 4)          ; 100-continue already sent for the current request
(defconstant +cf-fifo+ 8)          ; has an entry in the FIFO

;;; response-list entry flags
(defconstant +ef-write+ 1)

;;; ---- state (all in foreign memory; initialised at boot) ------------------------------------
(sb-ext:defglobal **rings** 0)
(sb-ext:defglobal **nrings** 0)
(sb-ext:defglobal **lfds** 0)
(sb-ext:defglobal **ts** 0)
(sb-ext:defglobal **earg** 0)
(sb-ext:defglobal **stats** 0)
(sb-ext:defglobal **fifo** 0)
(sb-ext:defglobal **fifo-head** 0)
(sb-ext:defglobal **fifo-tail** 0)
(sb-ext:defglobal **rlist** 0)
(sb-ext:defglobal **rcount** 0)
(sb-ext:defglobal **arenas** 0)
(sb-ext:defglobal **arena-out** 0)
(sb-ext:defglobal **arena-cur** 0)
(sb-ext:defglobal **arena-pos** 0)
(sb-ext:defglobal **cap** +answer-cap-init+)
(sb-ext:defglobal **reads-left** 0)
(sb-ext:defglobal **mono-s** 0)
(sb-ext:defglobal **now-ns** 0)
(sb-ext:defglobal **nreq** 0)
(sb-ext:defglobal **gcs** 0)
(sb-ext:defglobal **accept-errs** 0)
(sb-ext:defglobal **sweep-ri** 0)
(sb-ext:defglobal **sweep-slot** 0)
(sb-ext:defglobal **sweep-left** 0)
(sb-ext:defglobal **sweep-sec** -1)
(sb-ext:defglobal **turn-max-all** 0)
(sb-ext:defglobal **wait-max-all** 0)
(sb-ext:defglobal **wait-max-pass** 0)
(sb-ext:defglobal **consed-log** nil)
(sb-ext:defglobal **variants** (make-array +npoints+ :initial-element nil))   ; compiled loops by point
(sb-ext:defglobal **variant-want** +base-point+)
(sb-ext:defglobal **variant-cur** +base-point+)
(sb-ext:defglobal **last-cqes** 0)
(sb-ext:defglobal **npass** 0)
(sb-ext:defglobal **sig-enters** 0)      ; controller signals, summed since the window began
(sb-ext:defglobal **sig-cqes** 0)
(sb-ext:defglobal **sig-wait-max** 0)    ; ns, longest queued-answer wait in the window
(sb-ext:defglobal **sig-turn-max** 0)    ; us, longest pass in the window
(sb-ext:defglobal **ctl-next-s** most-positive-fixnum)
(sb-ext:defglobal **ctl** (make-array 48 :element-type 'fixnum :initial-element 0))
(sb-ext:defglobal **ctl-bad** (make-array +npoints+ :element-type 'fixnum :initial-element 0))
(sb-ext:defglobal **ctl-ru** 0)
(sb-ext:defglobal **started-mono** 0)
(sb-ext:defglobal **gc-last** 0)
(declaim (type simple-vector **variants**)
         (type (simple-array fixnum (48)) **ctl**)
         (type (simple-array fixnum (125)) **ctl-bad**)
         (type fixnum **variant-want** **variant-cur** **last-cqes** **npass** **sig-enters** **sig-cqes**
               **sig-wait-max** **sig-turn-max** **ctl-next-s** **started-mono** **gc-last**)
         (type addr **ctl-ru**))
(declaim (type addr **rings** **lfds** **ts** **earg** **stats** **fifo** **rlist** **arenas** **arena-out**)
         (type (integer 0 8192) **rcount**)
         (type fixnum **nrings** **fifo-head** **fifo-tail** **arena-cur** **arena-pos** **cap**
               **reads-left** **mono-s** **now-ns** **nreq** **gcs** **accept-errs** **sweep-ri** **sweep-slot** **sweep-left** **sweep-sec**
               **turn-max-all** **wait-max-all** **wait-max-pass**))

;;; ---- accessors ------------------------------------------------------------------------------
(defmacro rf (r f) `(the (unsigned-byte 62) (a-ref-64 ,r (* 8 ,f))))

(defmacro c-state (c) `(a-ref-8 ,c 0))
(defmacro c-flags (c) `(a-ref-8 ,c 1))
(defmacro c-gen (c) `(a-ref-16 ,c 2))
(defmacro c-plen (c) `(a-ref-32 ,c 4))
(defmacro c-pptr (c) `(the addr (a-ref-64 ,c 8)))
(defmacro c-pcap (c) `(a-ref-32 ,c 16))
(defmacro c-last (c) `(a-ref-32 ,c 20))
(defmacro c-rts (c) `(the (unsigned-byte 62) (a-ref-64 ,c 24)))
(defmacro c-saddr (c) `(the addr (a-ref-64 ,c 32)))
(defmacro c-sleft (c) `(a-ref-32 ,c 40))

(defmacro flag-p (c f) `(logtest (c-flags ,c) ,f))
(defmacro flag-on (c f) `(setf (c-flags ,c) (logior (c-flags ,c) ,f)))
(defmacro flag-off (c f) `(setf (c-flags ,c) (logandc2 (c-flags ,c) ,f)))

(defmacro mk-ud (op ri gen aux slot)
  `(the (unsigned-byte 62)
        (logior (ash (the (unsigned-byte 8) ,op) 56) (ash (the (unsigned-byte 8) ,ri) 48)
                (ash (the (unsigned-byte 16) ,gen) 32) (ash (the (unsigned-byte 8) ,aux) 16)
                (the (unsigned-byte 16) ,slot))))

(defmacro arena-out (i) `(a-ref-32 **arena-out** (* 4 (the (unsigned-byte 8) ,i))))
(defmacro arena-base (i) `(the addr (+ **arenas** (* (the (unsigned-byte 8) ,i) +arena-bytes+))))
(defmacro fixed-addr (i) `(the addr (aref **fixed-addr** ,i)))
(defmacro fixed-len (i) `(the (unsigned-byte 32) (aref **fixed-len** ,i)))

;;; ---- setup (not hot) ------------------------------------------------------------------------

(defun parse-ipv4 (host)
  "Dotted quad -> list of four octets (\"localhost\" is 127.0.0.1)."
  (when (string= host "localhost") (return-from parse-ipv4 (list 127 0 0 1)))
  (let ((parts '()) (cur nil))
    (loop for ch across (concatenate 'string host ".")
          do (cond ((digit-char-p ch) (setf cur (+ (* (or cur 0) 10) (digit-char-p ch))))
                   ((and (char= ch #\.) cur (< cur 256)) (push cur parts) (setf cur nil))
                   (t (error "unsupported HOST ~S (IPv4 dotted quad expected)" host))))
    (unless (= (length parts) 4) (error "unsupported HOST ~S" host))
    (nreverse parts)))

(defun make-listeners (host port)
  "+listeners+ sockets on HOST:PORT, each with SO_REUSEPORT so the kernel spreads connections."
  (let ((one (foreign-alloc 8)) (sa (foreign-alloc 16)))
    (setf (a-ref-32 one 0) 1)
    (dotimes (i 16) (setf (a-ref-8 sa i) 0))
    (setf (a-ref-16 sa 0) +af-inet+
          (a-ref-8 sa 2) (ldb (byte 8 8) port)
          (a-ref-8 sa 3) (ldb (byte 8 0) port))
    (loop for o in (parse-ipv4 host) for i from 4 do (setf (a-ref-8 sa i) o))
    (dotimes (li +listeners+)
      (let ((fd (%socket +af-inet+ (logior +sock-stream+ +sock-cloexec+) 0)))
        (when (< fd 0) (error "socket() failed, errno ~D" (sb-alien:get-errno)))
        (%setsockopt fd +sol-socket+ +so-reuseaddr+ one 4)
        (%setsockopt fd +sol-socket+ +so-reuseport+ one 4)
        ;; accepted sockets inherit TCP_NODELAY (direct descriptors cannot be set afterwards)
        (%setsockopt fd +ipproto-tcp+ +tcp-nodelay+ one 4)
        (when (< (%bind fd sa 16) 0) (error "bind ~A:~D failed, errno ~D" host port (sb-alien:get-errno)))
        (when (< (%listen fd 4096) 0) (error "listen failed, errno ~D" (sb-alien:get-errno)))
        (setf (a-ref-32 **lfds** (* 4 li)) fd)))
    (%free sa)
    (%free one)))

(defun register-buf-ring (fd ring-mem)
  "Provided-buffer group 0. Ubuntu 6.8.0-136+ inverts the check on the reserved words (it refuses
all zeroes and accepts a nonzero resv[0]); a refused registration is tried once more that way."
  (let ((reg (foreign-alloc 40)))
    (dotimes (i 5) (setf (a-ref-64 reg (* 8 i)) 0))
    (setf (a-ref-64 reg 0) ring-mem
          (a-ref-32 reg 8) +buf-count+)
    (let ((rc 0))
      (dotimes (attempt 2)
        (setf rc (%syscall6 +sys-io-uring-register+ fd 22 reg 1 0 0))
        (when (or (>= rc 0) (/= (sb-alien:get-errno) +einval+)) (return))
        (setf (a-ref-64 reg 16) 1))
      (%free reg)
      (>= rc 0))))

(defun ring-setup (ri)
  "Creates ring RI (record, rings, descriptor table, buffer ring, connection table). NIL on failure."
  (let* ((r (+ **rings** (* ri 256)))
         (p (zeroed-alloc 128)))
    (dotimes (i 32) (setf (a-ref-64 r (* 8 i)) 0))
    (setf (a-ref-32 p 4) +cq-entries+
          (a-ref-32 p 8) +setup-flags+)
    (let ((fd (%syscall6 +sys-io-uring-setup+ +sq-entries+ p 0 0 0 0)))
      (when (< fd 0)
        (log-line "io_uring_setup failed, errno ~D" (sb-alien:get-errno))
        (return-from ring-setup nil))
      (let* ((sq-n (a-ref-32 p 0)) (cq-n (a-ref-32 p 4)) (features (a-ref-32 p 20))
             (sq-array (a-ref-32 p 64)) (cq-cqes (a-ref-32 p 100))
             (sq-size (+ sq-array (* 4 sq-n))) (cq-size (+ cq-cqes (* 16 cq-n)))
             (single (logtest features 1))
             (sqm (%mmap 0 (if single (max sq-size cq-size) sq-size) +prot-rw+ +map-shared-populate+ fd 0))
             (cqm (if single sqm (%mmap 0 cq-size +prot-rw+ +map-shared-populate+ fd #x8000000)))
             (sqes (%mmap 0 (* 64 sq-n) +prot-rw+ +map-shared-populate+ fd #x10000000)))
        (when (or (= sqm +map-failed+) (= cqm +map-failed+) (= sqes +map-failed+))
          (log-line "mmap of the rings failed, errno ~D" (sb-alien:get-errno))
          (return-from ring-setup nil))
        (setf (rf r +f-fd+) fd
              (rf r +f-sq-head+) (+ sqm (a-ref-32 p 40))
              (rf r +f-sq-tailp+) (+ sqm (a-ref-32 p 44))
              (rf r +f-sq-mask+) (a-ref-32 (+ sqm (a-ref-32 p 48)) 0)
              (rf r +f-sqes+) sqes
              (rf r +f-sq-entries+) sq-n
              (rf r +f-cq-head+) (+ cqm (a-ref-32 p 80))
              (rf r +f-cq-tail+) (+ cqm (a-ref-32 p 84))
              (rf r +f-cq-mask+) (a-ref-32 (+ cqm (a-ref-32 p 88)) 0)
              (rf r +f-cqes+) (+ cqm cq-cqes))
        ;; the SQ array is the identity: slot i always names SQE i
        (dotimes (i sq-n) (setf (a-ref-32 (+ sqm sq-array) (* 4 i)) i))
        ;; sparse direct-descriptor table
        (let ((tab (zeroed-alloc (* 4 +max-slots+))))
          (dotimes (i +max-slots+) (setf (a-ref-32 tab (* 4 i)) #xffffffff))
          (let ((rc (%syscall6 +sys-io-uring-register+ fd 2 tab +max-slots+ 0 0)))
            (%mmap-free tab (* 4 +max-slots+))
            (when (< rc 0)
              (log-line "registering the descriptor table failed, errno ~D" (sb-alien:get-errno))
              (return-from ring-setup nil))))
        ;; provided buffers
        (let ((bring (zeroed-alloc (* 16 +buf-count+)))
              (bufs (zeroed-alloc (* +buf-size+ +buf-count+))))
          (unless (register-buf-ring fd bring)
            (log-line "registering the buffer ring failed, errno ~D" (sb-alien:get-errno))
            (return-from ring-setup nil))
          (dotimes (i +buf-count+)
            (let ((e (+ bring (* 16 i))))
              (setf (a-ref-64 e 0) (+ bufs (* i +buf-size+))
                    (a-ref-32 e 8) +buf-size+
                    (a-ref-16 e 12) i)))
          (setf (a-ref-16 bring 14) (logand +buf-count+ #xffff)
                (rf r +f-bufring+) bring
                (rf r +f-bufs+) bufs
                (rf r +f-btail+) +buf-count+))
        (setf (rf r +f-conns+) (zeroed-alloc (* 64 65536)))
        (%mmap-free p 128)
        t))))

;;; ---- hot path -------------------------------------------------------------------------------
(declaim (optimize (speed 3) (safety 0) (debug 0)))

(declaim (inline ring-at conn-at now-ns))
(defun ring-at (ri)
  (declare (type (unsigned-byte 8) ri))
  (the addr (+ **rings** (* ri 256))))

(defun conn-at (r slot)
  (declare (type addr r) (type (unsigned-byte 16) slot))
  (the addr (+ (rf r +f-conns+) (* slot 64))))

(defun now-ns ()
  (%clock-gettime +clock-monotonic+ **ts**)
  (the (unsigned-byte 62)
       (+ (* (the (unsigned-byte 32) (a-ref-64 **ts** 0)) 1000000000)
          (the (unsigned-byte 32) (a-ref-64 **ts** 8)))))

(defun update-clocks ()
  (let ((t0 (now-ns)))
    (declare (type (unsigned-byte 62) t0))
    (setf **now-ns** t0
          **mono-s** (the fixnum (floor t0 1000000000)))
    (%clock-gettime +clock-realtime+ **ts**)
    (setf **now** (the fixnum (a-ref-64 **ts** 0)))
    t0))

(defun note-enter-error (e)
  (declare (type fixnum e))
  (log-line "io_uring_enter failed, errno ~D" e))

(defun ring-enter (r min timeout-ns)
  "Submit what is queued on ring R, run its deferred completions, and when TIMEOUT-NS is non-zero
wait for MIN completions or that long. The syscall is the raw-syscall VOP: rc is -errno on failure."
  (declare (type addr r) (type (unsigned-byte 32) min timeout-ns))
  (incf **sig-enters**)
  (let* ((n (logand (- (rf r +f-ltail+) (a-ref-32 (rf r +f-sq-head+) 0)) #xffffffff))
         (fd (rf r +f-fd+))
         (rc (if (zerop timeout-ns)
                 (%enter-syscall fd n 0 1 0 0)
                 (let ((ea **earg**))
                   (setf (a-ref-64 ea 0) 0 (a-ref-64 ea 8) 0 (a-ref-64 ea 16) (+ ea 32)
                         (a-ref-64 ea 32) 0 (a-ref-64 ea 40) timeout-ns)
                   (%enter-syscall fd n min 9 ea 24)))))
    (declare (type (unsigned-byte 32) n) (type fixnum fd) (type (signed-byte 64) rc))
    (when (< rc 0)
      (let ((e (- rc)))
        (declare (type fixnum e))
        (unless (or (= e +etime+) (= e +eintr+) (= e +ebusy+) (= e +eagain+))
          (note-enter-error e))))
    rc))

(defun get-sqe (r)
  "The next free SQE of ring R, zeroed, already counted in the shared tail."
  (declare (type addr r))
  (let ((tail (rf r +f-ltail+)))
    (declare (type (unsigned-byte 32) tail))
    (when (>= (logand (- tail (a-ref-32 (rf r +f-sq-head+) 0)) #xffffffff) (rf r +f-sq-entries+))
      (ring-enter r 0 0))
    (let ((s (+ (rf r +f-sqes+) (* 64 (logand tail (rf r +f-sq-mask+)))))
          (nt (logand (1+ tail) #xffffffff)))
      (declare (type addr s))
      (setf (a-ref-64 s 0) 0 (a-ref-64 s 8) 0 (a-ref-64 s 16) 0 (a-ref-64 s 24) 0
            (a-ref-64 s 32) 0 (a-ref-64 s 40) 0 (a-ref-64 s 48) 0 (a-ref-64 s 56) 0)
      (setf (rf r +f-ltail+) nt
            (a-ref-32 (rf r +f-sq-tailp+) 0) nt)
      s)))

(defun arm-accept (ri r li)
  (declare (type (unsigned-byte 8) ri li) (type addr r))
  (let ((s (get-sqe r)))
    (declare (type addr s))
    (setf (a-ref-8 s 0) +iou-accept+
          (a-ref-16 s 2) 1                                  ; IORING_ACCEPT_MULTISHOT
          (a-ref-32 s 4) (a-ref-32 **lfds** (* 4 li))
          (a-ref-32 s 44) #xffffffff                        ; IORING_FILE_INDEX_ALLOC
          (a-ref-64 s 32) (mk-ud +op-accept+ ri 0 0 li))
    (incf (rf r +f-alive+))
    nil))

(defun arm-all (ri)
  (declare (type (unsigned-byte 8) ri))
  (let ((r (ring-at ri)))
    (dotimes (li +listeners+) (arm-accept ri r li))
    nil))

(defun arm-recv (ri r slot gen)
  (declare (type (unsigned-byte 8) ri) (type addr r) (type (unsigned-byte 16) slot gen))
  (let ((s (get-sqe r)))
    (declare (type addr s))
    (setf (a-ref-8 s 0) +iou-recv+
          (a-ref-8 s 1) (logior +sqe-fixed-file+ +sqe-buffer-select+)
          (a-ref-16 s 2) 2                                  ; IORING_RECV_MULTISHOT
          (a-ref-32 s 4) slot
          (a-ref-64 s 32) (mk-ud +op-recv+ ri gen 0 slot))
    nil))

(defun submit-send (ri r slot gen aux addr len)
  (declare (type (unsigned-byte 8) ri aux) (type addr r addr) (type (unsigned-byte 16) slot gen)
           (type (unsigned-byte 32) len))
  (let ((s (get-sqe r)))
    (declare (type addr s))
    (setf (a-ref-8 s 0) +iou-send+
          (a-ref-8 s 1) +sqe-fixed-file+
          (a-ref-32 s 4) slot
          (a-ref-64 s 16) addr
          (a-ref-32 s 24) len
          (a-ref-32 s 28) +msg-nosignal+
          (a-ref-64 s 32) (mk-ud +op-send+ ri gen aux slot))
    nil))

(defun buf-return (r bid)
  (declare (type addr r) (type (unsigned-byte 16) bid))
  (let* ((tail (rf r +f-btail+))
         (ring (rf r +f-bufring+))
         (e (+ ring (* 16 (logand tail (1- +buf-count+))))))
    (declare (type (unsigned-byte 32) tail) (type addr ring e))
    (setf (a-ref-64 e 0) (+ (rf r +f-bufs+) (* bid +buf-size+))
          (a-ref-32 e 8) +buf-size+
          (a-ref-16 e 12) bid)
    (setf tail (logand (1+ tail) #xffff))
    (setf (rf r +f-btail+) tail
          (a-ref-16 ring 14) tail)
    nil))

;;; ---- FIFO of connections with unanswered bytes ----------------------------------------------
(declaim (inline maybe-enqueue))
(defun maybe-enqueue (ri slot c)
  (declare (type (unsigned-byte 8) ri) (type (unsigned-byte 16) slot) (type addr c))
  (unless (flag-p c (logior +cf-busy+ +cf-fifo+))
    (flag-on c +cf-fifo+)
    (setf (c-rts c) **now-ns**)
    (setf (a-ref-32 **fifo** (* 4 (logand **fifo-tail** (1- (ash 1 +fifo-log2+)))))
          (logior (ash ri 16) slot))
    (incf **fifo-tail**))
  nil)

;;; ---- connections ----------------------------------------------------------------------------
(defun conn-close (ri r slot c)
  (declare (type (unsigned-byte 8) ri) (type addr r c) (type (unsigned-byte 16) slot))
  (when (= (c-state c) 1)
    (setf (c-state c) 2)
    (decf (rf r +f-open+))
    (when (plusp (c-pcap c))
      (%free (c-pptr c))
      (setf (c-pcap c) 0 (c-plen c) 0 (c-pptr c) 0))
    (let ((gen (c-gen c)))
      ;; the shutdown ends the multishot receive; the (hard-linked) close frees the slot
      (let ((s (get-sqe r)))
        (declare (type addr s))
        (setf (a-ref-8 s 0) +iou-shutdown+
              (a-ref-8 s 1) (logior +sqe-fixed-file+ +sqe-hardlink+)
              (a-ref-32 s 4) slot
              (a-ref-32 s 24) 2                             ; SHUT_RDWR
              (a-ref-64 s 32) (mk-ud +op-shutdown+ ri gen 0 slot)))
      (let ((s (get-sqe r)))
        (declare (type addr s))
        (setf (a-ref-8 s 0) +iou-close+
              (a-ref-32 s 44) (1+ slot)                     ; the direct descriptor, 1-based
              (a-ref-64 s 32) (mk-ud +op-close+ ri gen 0 slot)))))
  nil)

(defun append-pending (c src n)
  "Copy N received bytes at SRC onto the connection's pending buffer. NIL when out of memory."
  (declare (type addr c src) (type (unsigned-byte 32) n))
  (let* ((plen (c-plen c)) (need (+ plen n)))
    (declare (type (unsigned-byte 32) plen need))
    (cond ((> need +pend-max+) t)           ; drop: the parser already knows this request is too big
          (t (when (> need (c-pcap c))
               (let ((cap (logand (+ need 1023) (lognot 1023))))
                 (declare (type (unsigned-byte 32) cap))
                 (let ((p (if (zerop (c-pcap c)) (%malloc cap) (%realloc (c-pptr c) cap))))
                   (declare (type addr p))
                   (when (zerop p) (return-from append-pending nil))
                   (setf (c-pptr c) p (c-pcap c) cap))))
             (%memmove (+ (c-pptr c) plen) src n)
             (setf (c-plen c) need)
             t))))

(defun spill ()
  "Make sure some ring is accepting; add a ring when every table is full."
  (dotimes (ri **nrings**)
    (let ((r (ring-at ri)))
      (when (and (plusp (rf r +f-alive+)) (zerop (rf r +f-full+)))
        (return-from spill t))))
  (dotimes (ri **nrings**)
    (let ((r (ring-at ri)))
      (when (zerop (rf r +f-full+))
        (arm-all ri)
        (return-from spill t))))
  (when (< **nrings** +max-rings+)
    (when (ring-setup **nrings**)
      (incf **nrings**)
      (arm-all (1- **nrings**))
      (return-from spill t)))
  nil)

(defun on-accept (ri r ud res fl)
  (declare (type (unsigned-byte 8) ri) (type addr r) (type (unsigned-byte 62) ud) (type fixnum res)
           (type (unsigned-byte 32) fl))
  (let ((li (ldb (byte 8 0) ud)))
    (declare (type (unsigned-byte 8) li))
    (cond
      ((>= res 0)
       (let* ((slot res) (c (conn-at r slot)) (gen (logand (1+ (c-gen c)) #xffff)))
         (declare (type (unsigned-byte 16) slot gen))
         (setf (c-gen c) gen
               (c-state c) 1
               (c-flags c) (logand (c-flags c) +cf-fifo+)   ; a stale FIFO entry may still exist
               (c-plen c) 0 (c-pptr c) 0 (c-pcap c) 0
               (c-last c) **mono-s**)
         (incf (rf r +f-open+))
         (arm-recv ri r slot gen))
       (when (zerop (logand fl +cqe-more+))
         (decf (rf r +f-alive+))
         (arm-accept ri r li)))
      (t
       (decf (rf r +f-alive+))
       (cond ((or (= res (- +enfile+)) (= res -24))         ; table full: accept on another ring
              (setf (rf r +f-full+) 1)
              (spill))
             ((< (incf **accept-errs**) 100000) (arm-accept ri r li))))))
  nil)

(defun on-recv (ri r ud res fl)
  (declare (type (unsigned-byte 8) ri) (type addr r) (type (unsigned-byte 62) ud) (type fixnum res)
           (type (unsigned-byte 32) fl))
  (let* ((slot (ldb (byte 16 0) ud)) (gen (ldb (byte 16 32) ud)) (c (conn-at r slot))
         (live (and (= (c-state c) 1) (= (c-gen c) gen))))
    (declare (type (unsigned-byte 16) slot gen))
    (cond
      ((and (> res 0) (logtest fl +cqe-buffer+))
       (let ((bid (ash fl -16)))
         (declare (type (unsigned-byte 16) bid))
         (when live
           (if (append-pending c (+ (rf r +f-bufs+) (* bid +buf-size+)) res)
               (setf (c-last c) **mono-s**)
               (conn-close ri r slot c)))
         (buf-return r bid)
         (when (and live (= (c-state c) 1))
           (maybe-enqueue ri slot c)
           (when (zerop (logand fl +cqe-more+)) (arm-recv ri r slot gen)))))
      (live
       (cond ((= res 0)                                    ; EOF: answer what is pending, then close
              (flag-on c +cf-close+)
              (unless (flag-p c (logior +cf-busy+ +cf-fifo+))
                (if (plusp (c-plen c))
                    (maybe-enqueue ri slot c)
                    (conn-close ri r slot c))))
             ((= res (- +enobufs+)) (arm-recv ri r slot gen))
             (t (conn-close ri r slot c))))))
  nil)

(defun on-send (ri r ud res)
  (declare (type (unsigned-byte 8) ri) (type addr r) (type (unsigned-byte 62) ud) (type fixnum res))
  (let* ((slot (ldb (byte 16 0) ud)) (gen (ldb (byte 16 32) ud)) (aux (ldb (byte 8 16) ud))
         (c (conn-at r slot))
         (live (and (= (c-state c) 1) (= (c-gen c) gen))))
    (declare (type (unsigned-byte 16) slot gen) (type (unsigned-byte 8) aux))
    (cond
      ((and live (>= res 0) (< res (c-sleft c)))           ; short send: the rest, from the same arena
       (setf (c-saddr c) (+ (c-saddr c) res)
             (c-sleft c) (- (c-sleft c) res))
       (submit-send ri r slot gen aux (c-saddr c) (c-sleft c)))
      (t
       (when (/= aux 255) (decf (arena-out aux)))
       (when live
         (cond ((< res 0) (conn-close ri r slot c))
               (t (flag-off c +cf-busy+)
                  (cond ((flag-p c +cf-close+) (conn-close ri r slot c))
                        ((plusp (c-plen c)) (maybe-enqueue ri slot c)))))))))
  nil)

(defun on-close (ri r ud)
  (declare (type (unsigned-byte 8) ri) (type addr r) (type (unsigned-byte 62) ud) (ignorable ri))
  (let* ((slot (ldb (byte 16 0) ud)) (gen (ldb (byte 16 32) ud)) (c (conn-at r slot)))
    (declare (type (unsigned-byte 16) slot gen))
    (when (and (= (c-state c) 2) (= (c-gen c) gen))
      (setf (c-state c) 0)))
  nil)

(defun reap-ring (ri)
  "Process the completions that ring RI has posted. Returns how many."
  (declare (type (unsigned-byte 8) ri))
  (let* ((r (ring-at ri))
         (headp (rf r +f-cq-head+))
         (head (a-ref-32 headp 0))
         (tail (a-ref-32 (rf r +f-cq-tail+) 0))
         (mask (rf r +f-cq-mask+))
         (cqes (rf r +f-cqes+))
         (n 0))
    (declare (type addr r headp cqes) (type (unsigned-byte 32) head tail) (type fixnum mask n))
    (loop
      (when (or (= head tail) (<= **reads-left** 0)) (return))
      (let* ((cqe (+ cqes (* 16 (logand head mask))))
             (ud (a-ref-64 cqe 0))
             (res (a-sref-32 cqe 8))
             (fl (a-ref-32 cqe 12)))
        (declare (type addr cqe) (type (unsigned-byte 62) ud) (type (signed-byte 32) res) (type (unsigned-byte 32) fl))
        (setf head (logand (1+ head) #xffffffff))
        (incf n)
        (case (ldb (byte 8 56) ud)
          (#.+op-recv+ (decf **reads-left**) (on-recv ri r ud res fl))
          (#.+op-send+ (on-send ri r ud res))
          (#.+op-accept+ (on-accept ri r ud res fl))
          (#.+op-close+ (on-close ri r ud)))))
    (setf (a-ref-32 headp 0) head)
    n))

;;; ---- answering --------------------------------------------------------------------------------
(declaim (inline push-entry))
(defun push-entry (id addr len eflags aux rts)
  (declare (type (unsigned-byte 32) id len) (type addr addr) (type (unsigned-byte 8) eflags aux)
           (type (unsigned-byte 62) rts))
  (let ((e (+ **rlist** (* 32 **rcount**))))
    (declare (type addr e))
    (setf (a-ref-32 e 0) id (a-ref-32 e 4) len (a-ref-64 e 8) addr
          (a-ref-8 e 16) eflags (a-ref-8 e 17) aux (a-ref-64 e 24) rts)
    (incf **rcount**))
  nil)

(defun roll-arena ()
  "Move to the next arena nothing is still sending from. NIL when every arena is pinned."
  (loop for k of-type fixnum from 1 below +arenas+
        do (let ((i (mod (+ **arena-cur** k) +arenas+)))
             (declare (type fixnum i))
             (when (zerop (arena-out i))
               (setf **arena-cur** i **arena-pos** 0)
               (return-from roll-arena t))))
  nil)

(declaim (inline arena-room))
(defun arena-room ()
  (or (>= (- +arena-bytes+ **arena-pos**) +arena-need+)
      (roll-arena)))

(defun consume (c n)
  (declare (type addr c) (type (unsigned-byte 32) n))
  (let ((left (- (c-plen c) n)))
    (declare (type fixnum left))
    (cond ((<= left 0)
           (%free (c-pptr c))
           (setf (c-pcap c) 0 (c-plen c) 0 (c-pptr c) 0))
          (t (%memmove (c-pptr c) (+ (c-pptr c) n) left)
             (setf (c-plen c) left)))
    nil))

(defun answer-conn (ri slot c)
  "Parse and answer one request of connection C. Returns 1 when a response was queued."
  (declare (type (unsigned-byte 8) ri) (type (unsigned-byte 16) slot) (type addr c))
  (let* ((buf (c-pptr c)) (len (c-plen c))
         (w (+ (arena-base **arena-cur**) **arena-pos**))
         (id (logior (ash ri 16) slot))
         (rts (c-rts c)))
    (declare (type addr buf w) (type (unsigned-byte 32) len id))
    (setf **w** w)
    (let ((total (parse-request buf len)))
      (declare (type fixnum total))
      (cond
        ((> total 0)
         (let ((closep **req-close**))
           (incf **nreq**)
           (flag-off c +cf-cont+)
           (setf **wrote** nil **wp** +hdr-room+)
           (handle-request buf)
           (consume c total)
           (let ((oa **out-addr**) (ol **out-len**))
             (declare (type addr oa) (type (unsigned-byte 32) ol))
             (cond ((and (>= oa w) (< oa (+ w +arena-bytes+)))
                    (setf **arena-pos** (logand (+ (- (+ oa ol) (arena-base **arena-cur**)) 15) (lognot 15)))
                    (incf (arena-out **arena-cur**))
                    (push-entry id oa ol (if **wrote** +ef-write+ 0) **arena-cur** rts))
                   (t (push-entry id oa ol (if **wrote** +ef-write+ 0) 255 rts))))
           (flag-on c (if closep (logior +cf-busy+ +cf-close+) +cf-busy+))
           1))
        ((= total +parse-incomplete+)
         (cond ((and **req-expect** (> **req-head** 0) (not (flag-p c +cf-cont+)))
                (flag-on c (logior +cf-cont+ +cf-busy+))
                (push-entry id (fixed-addr +r-continue+) (fixed-len +r-continue+) 0 255 rts)
                1)
               (t 0)))
        (t
         (let ((idx (if (= total +parse-too-big+) +r-too-large+ +r-bad-request+)))
           (flag-on c (logior +cf-busy+ +cf-close+))
           (push-entry id (fixed-addr idx) (fixed-len idx) 0 255 rts)
           1))))))

(defun answer-phase (t0)
  "Oldest first. Returns the number of requests answered."
  (declare (type (unsigned-byte 62) t0))
  (let ((n 0) (cap **cap**) (limit (* +turn-hi-us+ 1000)))
    (declare (type fixnum n cap limit))
    ;; every send from the current arena is done: start over at its front, where the cache is warm
    (when (zerop (arena-out **arena-cur**)) (setf **arena-pos** 0))
    (loop
      (when (or (>= n cap) (= **fifo-head** **fifo-tail**)) (return))
      (when (and (zerop (logand n (1- +clock-every+))) (plusp n)
                 (> (- (now-ns) t0) limit))
        (return))
      (unless (arena-room) (return))
      (let* ((id (a-ref-32 **fifo** (* 4 (logand **fifo-head** (1- (ash 1 +fifo-log2+))))))
             (ri (ash id -16)) (slot (logand id #xffff))
             (r (ring-at ri)) (c (conn-at r slot)))
        (declare (type (unsigned-byte 32) id) (type (unsigned-byte 8) ri) (type (unsigned-byte 16) slot)
                 (type addr r c))
        (incf **fifo-head**)
        (flag-off c +cf-fifo+)
        (when (and (= (c-state c) 1) (not (flag-p c +cf-busy+)) (plusp (c-plen c)))
          (incf n (the fixnum (answer-conn ri slot c))))))
    n))

(defun finish-phase ()
  "Group commit, then queue the sends. Returns the number of sends."
  (let ((count **rcount**))
    (declare (type fixnum count))
    (when **in-txn**
      (unless (db-commit)
        (db-rollback)
        (dotimes (i count)
          (let ((e (+ **rlist** (* 32 i))))
            (declare (type addr e))
            (when (logtest (a-ref-8 e 16) +ef-write+)
              (setf (a-ref-64 e 8) (fixed-addr +r-internal+)
                    (a-ref-32 e 4) (fixed-len +r-internal+)))))))
    (let ((now (now-ns)) (wmax **wait-max-pass**))
      (declare (type (unsigned-byte 62) now) (type fixnum wmax))
      (dotimes (i count)
        (let* ((e (+ **rlist** (* 32 i)))
               (id (a-ref-32 e 0)) (ri (ash id -16)) (slot (logand id #xffff))
               (r (ring-at ri)) (c (conn-at r slot))
               (addr (a-ref-64 e 8)) (len (a-ref-32 e 4)))
          (declare (type addr e r c addr) (type (unsigned-byte 32) id len) (type (unsigned-byte 8) ri)
                   (type (unsigned-byte 16) slot))
          (let ((wait (- now (the (unsigned-byte 62) (a-ref-64 e 24)))))
            (declare (type fixnum wait))
            (when (> wait wmax) (setf wmax wait)))
          (setf (c-saddr c) addr (c-sleft c) len)
          (submit-send ri r slot (c-gen c) (a-ref-8 e 17) addr len)))
      (setf **wait-max-pass** wmax))
    (setf **rcount** 0)
    count))

;;; ---- idle sweep and bookkeeping ---------------------------------------------------------------
(defun sweep-step (limit)
  (declare (type fixnum limit))
  ;; The sweep walks cold connection records, so its budget is paced by the clock, not by passes:
  ;; every second adds 1/+sweep-cycle-s+ of the slot space (one full cycle per +sweep-cycle-s+ s).
  (unless (= **mono-s** **sweep-sec**)
    (setf **sweep-sec** **mono-s**)
    (setf **sweep-left** (min (+ **sweep-left** (ceiling (* **nrings** 65536) +sweep-cycle-s+))
                              (* **nrings** 65536))))
  (dotimes (k (min **sweep-left** +sweep-per-pass+))
    (decf **sweep-left**)
    (let ((ri **sweep-ri**) (slot **sweep-slot**))
      (declare (type fixnum ri slot))
      (when (< ri **nrings**)
        (let* ((r (ring-at ri)) (c (conn-at r slot)))
          (declare (type addr r c))
          (when (and (= (c-state c) 1) (not (flag-p c (logior +cf-busy+ +cf-fifo+)))
                     (> (- **mono-s** (c-last c)) limit))
            (conn-close ri r slot c))))
      (incf slot)
      (when (>= slot 65536)
        (setf slot 0)
        (incf ri)
        (when (>= ri **nrings**) (setf ri 0)))
      (setf **sweep-ri** ri **sweep-slot** slot)))
  nil)

(defun any-cq-pending ()
  (dotimes (ri **nrings** nil)
    (let ((r (ring-at ri)))
      (unless (= (a-ref-32 (rf r +f-cq-head+) 0) (a-ref-32 (rf r +f-cq-tail+) 0))
        (return t)))))

(defun open-total ()
  (let ((open 0))
    (declare (type fixnum open))
    (dotimes (ri **nrings**) (incf open (the fixnum (rf (ring-at ri) +f-open+))))
    open))

(defun adapt-cap (n elapsed-ns)
  "Answers per pass follow the measured turn: shrink when a pass overruns, grow when a capped pass was quick."
  (declare (type (integer 0 1000000) n) (type (integer 0 100000000000) elapsed-ns))
  (let ((cap **cap**) (us (floor elapsed-ns 1000)))
    (declare (type (integer 0 100000) cap) (type (integer 0 100000000) us))
    (cond ((> us +turn-hi-us+)
           (setf cap (max +answer-cap-min+ (floor (* (max n 1) +turn-aim-us+) (max us 1)))))
          ((and (< us +turn-lo-us+) (>= n cap))
           (setf cap (min +answer-cap-max+ (+ cap (ash cap -2) 1)))))
    (setf **cap** cap)
    nil))

(defun publish-stats (turn-us npass)
  (declare (type fixnum turn-us npass))
  (let* ((st **stats**) (wait-us (floor **wait-max-pass** 1000)))
    (declare (type addr st) (type fixnum wait-us))
    (when (> turn-us (the fixnum (a-ref-64 st 0))) (setf (a-ref-64 st 0) turn-us))
    (when (> wait-us (the fixnum (a-ref-64 st 8))) (setf (a-ref-64 st 8) wait-us))
    (when (> turn-us **sig-turn-max**) (setf **sig-turn-max** turn-us))
    (when (> wait-us **sig-wait-max**) (setf **sig-wait-max** wait-us))
    (when (> turn-us **turn-max-all**) (setf **turn-max-all** turn-us))
    (when (> wait-us **wait-max-all**) (setf **wait-max-all** wait-us))
    (setf **wait-max-pass** 0)
    (setf (a-ref-64 st 16) **cap**
          (a-ref-64 st 32) **nreq**
          (a-ref-64 st 40) **gcs**
          (a-ref-64 st 48) npass
          (a-ref-64 st 56) **turn-max-all**
          (a-ref-64 st 64) **wait-max-all**)
    (let ((open 0))
      (declare (type fixnum open))
      (dotimes (ri **nrings**) (incf open (the fixnum (rf (ring-at ri) +f-open+))))
      (setf (a-ref-64 st 24) open)))
  nil)

;;; ---- the self-tuning wait policy (M7): one generated loop per point, and the controller -----------
;;; EVENT-LOOP-BODY is the pass loop with the three wait numbers as literal constants. The server image
;;; holds 27 compiled variants (levels 1-3 of each knob); EVENT-LOOP below runs the one named by
;;; **VARIANT-WANT** and each variant hands back to it, at the end of a pass, when that changes, so a
;;; switch is a store and a funcall: no consing, no locks. Points on the outer levels are COMPILEd on a
;;; helper thread when the climb asks for one (at most once per +ctl-compile-gap-s+).
(defmacro event-loop-body (id batch-open wait-min wait-ns)
  `(let ((last-cqes **last-cqes**) (npass **npass**))
     (declare (type fixnum last-cqes npass))
     (loop
       ;; 1. submit everything queued; ring 0 goes last and waits unless there is work in hand
       (loop for ri of-type fixnum from (1- **nrings**) downto 1
             do (ring-enter (ring-at ri) 0 0))
       (let ((r0 (ring-at 0)))
         (if (or (/= **fifo-head** **fifo-tail**)
                 (and (any-cq-pending) (< (open-total) ,batch-open)))
             (ring-enter r0 0 0)
             (let ((open (open-total)))
               (declare (type fixnum open))
               (if (or (>= last-cqes +busy-cqes+) (>= open ,batch-open))
                   ;; many connections: collect completions for up to the wait in one enter
                   (ring-enter r0 ,wait-min ,wait-ns)
                   (ring-enter r0 +wait-min-low+
                               (if (and (= **nrings** 1) (zerop last-cqes)) +wait-idle-ns+ ,wait-ns))))))
       (let ((t0 (update-clocks)) (cq 0))
         (declare (type (unsigned-byte 62) t0) (type fixnum cq))
         ;; 2. drain first
         (setf **reads-left** +read-cap+)
         (dotimes (ri **nrings**) (incf cq (the fixnum (reap-ring ri))))
         ;; 3 + 4. answer oldest first, commit once, queue the sends
         (let ((n (answer-phase t0)))
           (declare (type fixnum n))
           (finish-phase)
           (let ((elapsed (- (now-ns) t0)))
             (declare (type fixnum elapsed))
             (when (plusp n) (adapt-cap n elapsed))
             (incf npass)
             (publish-stats (floor elapsed 1000) npass)))
         ;; housekeeping: idle connections, and accepting again after slots were freed
         (sweep-step (if (< (the fixnum (a-ref-64 **stats** 72)) +low-mem-kb+)
                         (if (zerop (the fixnum (a-ref-64 **stats** 72))) +idle-seconds+ +idle-low-mem-seconds+)
                         +idle-seconds+))
         (when (zerop (logand npass 1023))
           (dotimes (ri **nrings**)
             (let ((r (ring-at ri)))
               (when (and (plusp (rf r +f-full+)) (< (rf r +f-open+) (- +max-slots+ 4096)))
                 (setf (rf r +f-full+) 0))))
           (spill))
         (setf last-cqes cq)
         (incf **sig-cqes** cq)
         ;; the controller looks at the load once per window, then maybe names another variant
         (when (>= **mono-s** **ctl-next-s**) (ctl-tick))
         (when (/= **variant-want** ,id)
           (setf **last-cqes** last-cqes **npass** npass)
           (return))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun point-number (b m w) (+ (* (+ (* b 5) m) 5) w)))

(macrolet ((gen ()
             `(progn
                ,@(loop for b from 1 to 3 append
                        (loop for m from 1 to 3 append
                              (loop for w from 1 to 3
                                    collect (let ((id (point-number b m w)))
                                              `(setf (svref **variants** ,id)
                                                     (lambda ()
                                                       (declare (optimize (speed 3) (safety 0) (debug 0)))
                                                       (event-loop-body ,id ,(svref *batch-levels* b)
                                                                        ,(svref *min-levels* m)
                                                                        ,(svref *ns-levels* w))))))))))) 
  (gen))

(defun compile-point (p)
  "COMPILE the loop for point P (any of the 125) and return it."
  (declare (type (integer 0 124) p))
  (let ((b (floor p 25)) (m (mod (floor p 5) 5)) (w (mod p 5))
        (*error-output* (make-broadcast-stream)))
    (handler-bind ((warning #'muffle-warning))
      (compile nil `(lambda ()
                      (declare (optimize (speed 3) (safety 0) (debug 0)))
                      (event-loop-body ,p ,(svref *batch-levels* b) ,(svref *min-levels* m)
                                       ,(svref *ns-levels* w)))))))

(defun event-loop ()
  (loop (let ((p **variant-want**))
          (declare (type (integer 0 124) p))
          (setf **variant-cur** p)
          (funcall (the function (svref **variants** p))))))

;;; ---- controller --------------------------------------------------------------------------------
;;; Inputs, all generic: connections open, completions per enter, requests per second, process CPU time
;;; (getrusage), and the longest a queued answer waited / the longest pass in the window. Nothing else.
;;; Goal: least CPU microseconds per request, with the wait guard. State: a fixnum array and a bad-until
;;; array, both allocated once. Hill-climb over the six neighbours of the current point, A/B against the
;;; current point's last window, 2 % hysteresis, one confirming window, discards windows whose rate moved.
(declaim (optimize (speed 1) (safety 1) (debug 0)))

(defconstant +c-t0+ 0)        ; window start (ns)
(defconstant +c-req+ 1)       ; **nreq** at window start
(defconstant +c-cpu+ 2)       ; process CPU us at window start
(defconstant +c-enters+ 3)
(defconstant +c-cqes+ 4)
(defconstant +c-mode+ 5)
(defconstant +c-cur+ 6)       ; point the climb stands on
(defconstant +c-cand+ 7)      ; point being tried
(defconstant +c-cost+ 8)      ; last cost of +c-cur+ (milli-us per request)
(defconstant +c-rps+ 9)       ; request rate of the previous window
(defconstant +c-cursor+ 10)   ; next neighbour to try (0-5)
(defconstant +c-fails+ 11)    ; neighbours that did not win in this sweep
(defconstant +c-wait+ 12)     ; windows left on the winner
(defconstant +c-weird+ 13)    ; consecutive windows whose signals looked wrong
(defconstant +c-pause+ 14)    ; base policy until this second
(defconstant +c-lastcomp+ 15) ; second of the last live COMPILE
(defconstant +c-compbusy+ 16) ; a compile is running
(defconstant +c-prev+ 17)     ; point before an accepted move
(defconstant +c-prevcost+ 18)
(defconstant +c-nswitch+ 19)
(defconstant +c-ncomp+ 20)
(defconstant +c-nticks+ 21)
(defconstant +c-gcmax+ 22)    ; longest GC pause seen (us)
(defconstant +c-compmax+ 23)  ; longest live COMPILE (ms)

(defconstant +m-idle+ 0)
(defconstant +m-settle-cur+ 1)
(defconstant +m-measure-cur+ 2)
(defconstant +m-settle-cand+ 3)
(defconstant +m-measure-cand+ 4)
(defconstant +m-confirm+ 5)
(defconstant +m-converged+ 6)
(defconstant +m-paused+ 7)

(defmacro cs (i) `(aref **ctl** ,i))

(defun ctl-disable ()
  (setf **ctl-next-s** most-positive-fixnum
        **variant-want** +base-point+))

(defun read-cpu-us ()
  (let ((ru **ctl-ru**))
    (declare (type addr ru))
    (%syscall6 98 0 ru 0 0 0 0)           ; getrusage(RUSAGE_SELF)
    (the fixnum (+ (* 1000000 (+ (the fixnum (a-ref-64 ru 0)) (the fixnum (a-ref-64 ru 16))))
                   (the fixnum (a-ref-64 ru 8)) (the fixnum (a-ref-64 ru 24))))))

(defun pt-unit (d) (case d (0 25) (1 5) (t 1)))
(defun pt-level (p d) (mod (floor p (pt-unit d)) 5))
(defun pt-neighbour (p k)
  "Point one level away from P on knob (k/2), down for even k, up for odd; -1 off the grid."
  (let* ((d (ash k -1)) (lv (pt-level p d)) (u (pt-unit d)))
    (if (evenp k) (if (> lv 0) (- p u) -1) (if (< lv 4) (+ p u) -1))))
(defun pt-family-p (p)
  (and (<= 1 (pt-level p 0) 3) (<= 1 (pt-level p 1) 3) (<= 1 (pt-level p 2) 3)))

(defun ctl-log (what dt rps open cost enters cqes wmax-us tmax-us)
  (let ((p (cs +c-cur+)) (w **variant-want**))
    (log-line "ctl t=~D ~A want=~D(~D/~D/~Dus) cur=~D rps=~D open=~D cost=~D.~3,'0Dus/req cqe/enter=~D wait-max=~Dms turn-max=~Dms gc-max=~Dus comp-max=~Dms switches=~D compiles=~D"
              (- **mono-s** **started-mono**) what w
              (svref *batch-levels* (pt-level w 0)) (svref *min-levels* (pt-level w 1))
              (floor (svref *ns-levels* (pt-level w 2)) 1000)
              p rps open (floor cost 1000) (mod cost 1000)
              (if (plusp enters) (floor cqes enters) 0)
              (floor wmax-us 1000) (floor tmax-us 1000)
              (cs +c-gcmax+) (cs +c-compmax+) (cs +c-nswitch+) (cs +c-ncomp+))))

(defun ctl-want (p)
  (unless (= p **variant-want**)
    (incf (cs +c-nswitch+))
    (setf **variant-want** p)))

(defun compile-worker (p)
  (let ((t0 (get-internal-real-time)))
    (let ((f (compile-point p)))
      (let ((ms (floor (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
        (when (> ms (cs +c-compmax+)) (setf (cs +c-compmax+) ms)))
      (setf (svref **variants** p) f)
      (incf (cs +c-ncomp+))
      (setf (cs +c-compbusy+) 0))))

(defun ctl-request-compile (p)
  "Start COMPILE of point P on a helper thread if the 10 s gap allows it. True when started."
  (when (and (zerop (cs +c-compbusy+))
             (>= (- **mono-s** (cs +c-lastcomp+)) +ctl-compile-gap-s+)
             (not (svref **variants** p)))
    (setf (cs +c-compbusy+) 1
          (cs +c-lastcomp+) **mono-s**)
    (sb-thread:make-thread #'compile-worker :name "compile" :arguments (list p))
    t))

(defun ctl-next-candidate ()
  "The next neighbour of the current point that is allowed and compiled, or -1. Neighbours outside the
precompiled family are asked for (one compile per gap) and tried on a later sweep."
  (let ((cur (cs +c-cur+)))
    (loop while (< (cs +c-cursor+) 6)
          do (let* ((k (cs +c-cursor+)) (p (pt-neighbour cur k)))
               (incf (cs +c-cursor+))
               (when (and (>= p 0) (<= (aref **ctl-bad** p) **mono-s**))
                 (cond ((svref **variants** p) (return-from ctl-next-candidate p))
                       (t (ctl-request-compile p) (incf (cs +c-fails+)))))))
    -1))

(defun ctl-start-sweep ()
  (setf (cs +c-cursor+) 0 (cs +c-fails+) 0))

(defun ctl-pick (cost)
  "Standing on +c-cur+ with a fresh COST: try the next neighbour, or settle on the winner for a while."
  (setf (cs +c-cost+) cost)
  (let ((p (ctl-next-candidate)))
    (cond ((>= p 0)
           (setf (cs +c-cand+) p (cs +c-mode+) +m-settle-cand+)
           (ctl-want p))
          (t (setf (cs +c-mode+) +m-converged+ (cs +c-wait+) +ctl-converged-ticks+)))))

(defun ctl-fall-back (mode)
  (ctl-want +base-point+)
  (setf (cs +c-cur+) +base-point+ (cs +c-mode+) mode (cs +c-cost+) 0)
  (ctl-start-sweep))

(defun ctl-tick-1 ()
  (let* ((c **ctl**) (now **now-ns**) (nreq **nreq**) (cpu (read-cpu-us))
         (enters **sig-enters**) (cqes **sig-cqes**)
         (wmax-us **sig-wait-max**) (tmax-us **sig-turn-max**)
         (open (open-total))
         (dt (- now (cs +c-t0+))) (dreq (- nreq (cs +c-req+))) (dcpu (- cpu (cs +c-cpu+)))
         (denters (- enters (cs +c-enters+))) (dcqes (- cqes (cs +c-cqes+)))
         (primed (/= (cs +c-t0+) 0)))
    (declare (type fixnum now nreq cpu enters cqes wmax-us tmax-us open dt dreq dcpu denters dcqes))
    (setf (cs +c-t0+) now (cs +c-req+) nreq (cs +c-cpu+) cpu
          (cs +c-enters+) enters (cs +c-cqes+) cqes
          **sig-wait-max** 0 **sig-turn-max** 0
          **ctl-next-s** (+ **mono-s** +ctl-tick-s+))
    (incf (cs +c-nticks+))
    (when (and primed (plusp dt))
      (let* ((rps (floor (* dreq 1000000000) dt))
             (cost (if (plusp dreq) (floor (* dcpu 1000) dreq) 0))
             (busy (and (>= open +ctl-min-conns+) (>= rps +ctl-min-rps+)))
             ;; sane: a window about as long as asked, CPU advanced, work done, 0.5-1000 us per request,
             ;; and the loop entered the kernel at all
             (sane (and (< dt (* 4 +ctl-tick-s+ 1000000000)) (plusp dcpu) (plusp dreq) (plusp denters)
                        (<= 500 cost 1000000) (< open 2000000)))
             (steady (let ((prev (cs +c-rps+)))
                       (or (zerop prev) (< (* (abs (- rps prev)) 1000) (* prev +ctl-steady-permille+)))))
             (mode (cs +c-mode+)))
        (declare (type fixnum rps cost mode))
        (setf (cs +c-rps+) rps)
        (cond
          ;; ---- not busy: the base policy, nothing explored, state forgotten
          ((not busy)
           (unless (= mode +m-idle+)
             (ctl-fall-back +m-idle+))
           (setf (cs +c-mode+) +m-idle+ (cs +c-weird+) 0 (cs +c-rps+) 0))
          ;; ---- paused after wrong-looking signals
          ((= mode +m-paused+)
           (when (>= **mono-s** (cs +c-pause+)) (ctl-fall-back +m-settle-cur+)))
          ;; ---- signals look wrong: three in a row sends us to the base policy for a while
          ((not sane)
           (when (>= (incf (cs +c-weird+)) 3)
             (ctl-fall-back +m-paused+)
             (setf (cs +c-pause+) (+ **mono-s** +ctl-pause-s+) (cs +c-weird+) 0)
             (ctl-log "signals-wrong->base" dt rps open cost denters dcqes wmax-us tmax-us)))
          (t
           (setf (cs +c-weird+) 0)
           (when (= mode +m-idle+)             ; load arrived: start climbing from the base policy
             (ctl-fall-back +m-settle-cur+)
             (setf mode +m-settle-cur+))
           (cond
             ;; ---- latency guard: a non-base point whose queue wait grew too long goes back to base
             ((and (/= **variant-want** +base-point+) (> wmax-us +ctl-guard-wait-us+))
              (setf (aref **ctl-bad** **variant-want**) (+ **mono-s** +ctl-bad-s+))
              (ctl-log "guard->base" dt rps open cost denters dcqes wmax-us tmax-us)
              (ctl-fall-back +m-settle-cur+))
             ;; ---- load moved: a comparison would be meaningless; go back to the point we stand on
             ((and (not steady) (or (= mode +m-measure-cand+) (= mode +m-confirm+)))
              (ctl-want (cs +c-cur+))
              (setf (cs +c-mode+) +m-settle-cur+)
              (ctl-log "unsteady" dt rps open cost denters dcqes wmax-us tmax-us))
             (t
              (cond
                ((= mode +m-settle-cur+) (setf (cs +c-mode+) +m-measure-cur+))
                ((= mode +m-measure-cur+)
                 (when steady
                   (ctl-start-sweep)
                   (ctl-pick cost)))
                ((= mode +m-settle-cand+) (setf (cs +c-mode+) +m-measure-cand+))
                ((= mode +m-measure-cand+)
                 (cond ((< (* cost 1000) (* (cs +c-cost+) (- 1000 +ctl-hyst-permille+)))
                        ;; cheaper: stand on it, and confirm once before believing it
                        (setf (cs +c-prev+) (cs +c-cur+) (cs +c-prevcost+) (cs +c-cost+)
                              (cs +c-cur+) (cs +c-cand+) (cs +c-cost+) cost
                              (cs +c-mode+) +m-confirm+))
                       (t (incf (cs +c-fails+))
                          (ctl-want (cs +c-cur+))
                          (setf (cs +c-mode+) +m-settle-cur+))))
                ((= mode +m-confirm+)
                 (cond ((< (* cost 1000) (* (cs +c-prevcost+) (- 1000 (ash +ctl-hyst-permille+ -1))))
                        (ctl-start-sweep)
                        (ctl-pick cost))
                       (t (setf (aref **ctl-bad** (cs +c-cur+)) (+ **mono-s** +ctl-bad-s+))
                          (setf (cs +c-cur+) (cs +c-prev+) (cs +c-cost+) (cs +c-prevcost+))
                          (ctl-want (cs +c-cur+))
                          (setf (cs +c-mode+) +m-settle-cur+))))
                ((= mode +m-converged+)
                 (when (<= (decf (cs +c-wait+)) 0)
                   (setf (cs +c-mode+) +m-measure-cur+))))
              (ctl-log (case (cs +c-mode+)
                         (#.+m-settle-cur+ "settle-cur") (#.+m-measure-cur+ "measure-cur")
                         (#.+m-settle-cand+ "settle-cand") (#.+m-measure-cand+ "measure-cand")
                         (#.+m-confirm+ "confirm") (#.+m-converged+ "converged") (t "?"))
                       dt rps open cost denters dcqes wmax-us tmax-us)))))))))

(defun ctl-tick ()
  (handler-case (ctl-tick-1)
    (error (e)
      (ctl-disable)
      (log-line "ctl: error ~A; controller off, base policy" e))))

(defun ctl-init (path-mode)
  "TUNE=off: base policy only.  TUNE_FIX=b,m,w: one fixed point (levels 0-4).  Otherwise the controller runs."
  (setf **ctl-ru** (foreign-alloc 256) **started-mono** **mono-s**)
  (cond ((equal path-mode "off") (ctl-disable) (log-line "tune: off (base policy, point ~D)" +base-point+))
        ((and path-mode (> (length path-mode) 4) (string= "fix:" path-mode :end2 4))
         (let* ((nums (loop for s = (subseq path-mode 4) then (let ((i (position #\, s))) (and i (subseq s (1+ i))))
                            while s collect (parse-integer s :junk-allowed t)))
                (p (point-number (first nums) (second nums) (third nums))))
           (unless (svref **variants** p) (setf (svref **variants** p) (compile-point p)))
           (setf **ctl-next-s** most-positive-fixnum **variant-want** p)
           (log-line "tune: fixed point ~D" p)))
        (t (setf **ctl-next-s** (+ **mono-s** +ctl-tick-s+))
           (log-line "tune: controller on, base point ~D, tick ~D s" +base-point+ +ctl-tick-s+))))

(declaim (optimize (speed 3) (safety 0) (debug 0)))

;;; ---- toplevel (not hot) -----------------------------------------------------------------------
(declaim (optimize (speed 1) (safety 1) (debug 0)))

(defun report-consed ()
  #+td-count (dotimes (i *xc-n*)
               (log-line "xcross ~A ~D" (aref *xc-names* i) (aref **xc** i)))
  #+td-count (log-line "xcross requests ~D" **nreq**)
  (when **consed-log**
    (log-line "consed: bytes=~D requests=~D gcs=~D" (sb-ext:get-bytes-consed) **nreq** **gcs**))
  (log-line "ctl-summary: want=~D switches=~D compiles=~D compile-max=~Dms gc-max=~Dus gcs=~D"
            **variant-want** (aref **ctl** +c-nswitch+) (aref **ctl** +c-ncomp+) (aref **ctl** +c-compmax+)
            (aref **ctl** +c-gcmax+) **gcs**))

(defun env (name &optional default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun write-perf-map ()
  "PERFMAP=1: on SIGUSR1 write /tmp/perf-<pid>.map (start size name) for every Lisp code object, so
perf can name SBCL frames. Not hot; never runs unless asked."
  (let ((path (format nil "/tmp/perf-~D.map" (sb-unix:unix-getpid))) (n 0))
    (with-open-file (o path :direction :output :if-exists :supersede)
      (sb-vm::map-allocated-objects
       (lambda (obj type size)
         (declare (ignore size))
         (when (= type sb-vm:code-header-widetag)
           (let ((nf (sb-kernel:code-n-entries obj)))
             (dotimes (i nf)
               (let* ((f (sb-kernel:%code-entry-point obj i))
                      (start (sb-sys:sap-int (sb-vm::simple-fun-entry-sap f)))
                      (end (if (< (1+ i) nf)
                               (sb-sys:sap-int (sb-vm::simple-fun-entry-sap
                                                (sb-kernel:%code-entry-point obj (1+ i))))
                               (+ (sb-kernel:get-lisp-obj-address obj)
                                  (- sb-vm:other-pointer-lowtag)
                                  (sb-kernel:%code-code-size obj)
                                  (* sb-vm:n-word-bytes (sb-kernel:code-header-words obj))))))
                 (incf n)
                 (format o "~(~X~) ~(~X~) ~A~%" start (max 16 (- end start))
                         (substitute #\_ #\Space (prin1-to-string (sb-kernel:%simple-fun-name f)))))))))
       :all))
    (log-line "perfmap: ~D functions -> ~A" n path)))

(defun init-loop-memory ()
  (setf **rings** (zeroed-alloc (* 256 +max-rings+))
        **lfds** (foreign-alloc (* 4 +listeners+))
        **ts** (foreign-alloc 64)
        **earg** (foreign-alloc 64)
        **fifo** (zeroed-alloc (* 4 (ash 1 +fifo-log2+)))
        **rlist** (zeroed-alloc (* 32 (+ +answer-cap-max+ 64)))
        **arenas** (zeroed-alloc (* +arenas+ +arena-bytes+))
        **arena-out** (zeroed-alloc (* 4 +arenas+))
        **cap** +answer-cap-init+))

(defun raise-nofile ()
  "A registered descriptor table counts against RLIMIT_NOFILE: lift the soft limit to the hard one."
  (let ((rl (foreign-alloc 16)))
    (when (zerop (%getrlimit +rlimit-nofile+ rl))
      (setf (a-ref-64 rl 0) (a-ref-64 rl 8))
      (%setrlimit +rlimit-nofile+ rl))
    (%free rl)))

(defun serve ()
  (let* ((path (or (env "SQLITE_PATH") (error "SQLITE_PATH is not set")))
         (secret (or (env "JWT_SECRET") (error "JWT_SECRET is not set")))
         (host (env "HOST" "0.0.0.0"))
         (port (parse-integer (env "PORT" "3000"))))
    (setf **consed-log** (and (env "CONSED_LOG") t))
    (init-memory)
    (init-responses)
    (init-loop-memory)
    (init-hmac (sb-ext:string-to-octets secret :external-format :utf-8))
    (db-open path)
    (update-clocks)
    (setf **started** **now**)
    (raise-nofile)
    (make-listeners host port)
    (unless (ring-setup 0) (error "cannot set up io_uring (kernel too old, or blocked by seccomp?)"))
    (setf **nrings** 1)
    (setf **stats** (%td-stats-addr))
    (dotimes (i 16) (setf (a-ref-64 **stats** (* 8 i)) 0))
    (%td-start-helper path (if (env "STATS") 1 0))
    (arm-all 0)
    (setf **gc-last** sb-ext:*gc-run-time*)
    (push (lambda ()
            (incf **gcs**)
            (let* ((r sb-ext:*gc-run-time*) (us (floor (* (- r **gc-last**) 1000000) internal-time-units-per-second)))
              (setf **gc-last** r)
              (when (> us (aref **ctl** +c-gcmax+)) (setf (aref **ctl** +c-gcmax+) us))))
          sb-ext:*after-gc-hooks*)
    (ctl-init (env "TUNE"))
    (sb-sys:enable-interrupt sb-unix:sigterm
                             (lambda (sig info ctx) (declare (ignore sig info ctx))
                               (report-consed) (sb-ext:exit :code 0 :abort t)))
    (sb-sys:enable-interrupt sb-unix:sigint
                             (lambda (sig info ctx) (declare (ignore sig info ctx))
                               (report-consed) (sb-ext:exit :code 0 :abort t)))
    (sb-sys:enable-interrupt sb-unix:sigusr1
                             (lambda (sig info ctx) (declare (ignore sig info ctx)) (report-consed)))
    (when (env "PERFMAP")
      (sb-sys:enable-interrupt sb-unix:sigusr1
                               (lambda (sig info ctx) (declare (ignore sig info ctx))
                                 (handler-case (write-perf-map)
                                   (error (e) (log-line "perfmap failed: ~A" e))))))
    (setf (sb-ext:bytes-consed-between-gcs) (* 64 1024 1024))
    (log-line "listening on ~A:~D (db ~A, io_uring)" host port path)
    (event-loop)))

(defun main ()
  (handler-case (serve)
    (error (e)
      (log-line "fatal: ~A" e)
      (sb-ext:exit :code 1 :abort t))))
