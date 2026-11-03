;;;; Every tunable of the event loop, in one place. Milestone 3's self-tuning recompiles the files
;;;; from here on with other values; nothing else names these numbers.
;;;; None of them depends on the route mix or on who the client is: the loop reads only its own
;;;; queue state and timings (rule 7).
(in-package #:feed)

;;; ---- rings and sockets ------------------------------------------------------------------
(defconstant +listeners+ 8)             ; SO_REUSEPORT listeners on the one port
(defconstant +sq-entries+ 4096)
(defconstant +cq-entries+ 65536)
(defconstant +max-rings+ 16)            ; x up to 65,535 direct descriptors each
(defconstant +max-slots+ 65535)         ; direct-descriptor table size per ring
(defconstant +buf-count+ 4096)          ; provided receive buffers per ring (power of two)
(defconstant +buf-size+ 2048)

;;; ---- the wait in io_uring_enter (ring 0 waits; the other rings submit and collect) --------
;;; Newer kernels cap the deferred task work one enter runs in proportion to min_complete, so a
;;; busy pass waits for many completions; a quiet one for a single completion.
(defconstant +wait-min+ 256)            ; completions that end the wait when the last pass was busy
(defconstant +wait-min-low+ 1)          ; ...and when it was quiet
(defconstant +busy-cqes+ 32)            ; "busy" means this many completions in the last pass
(defconstant +batch-open+ 256)          ; with at least this many connections open, always wait for a batch
(defconstant +wait-ns+ 1000000)         ; the wait gives up after this long (1 ms)
(defconstant +wait-idle-ns+ 50000000)   ; ...or this long when nothing is happening and one ring exists

;;; ---- queue scheduling: drain first, oldest first, adaptive batch ------------------------
(defconstant +read-cap+ 16384)          ; receive completions taken from the kernel per pass
(defconstant +answer-cap-init+ 2048)    ; requests answered per pass; adapted from measured turns
(defconstant +answer-cap-min+ 64)
(defconstant +answer-cap-max+ 4096)     ; also bounds the per-pass response list
(defconstant +turn-lo-us+ 20000)        ; a cap-limited pass faster than this grows the cap
(defconstant +turn-hi-us+ 50000)        ; a pass slower than this shrinks it (and ends early)
(defconstant +turn-aim-us+ 35000)       ; ...towards this
(defconstant +clock-every+ 32)          ; requests between clock reads inside the answer phase
(defconstant +fifo-log2+ 20)            ; connections waiting for an answer: 2^20 entries

;;; ---- response arenas ---------------------------------------------------------------------
;;; A response is built in place in an arena; the arena stays pinned until every send from it is
;;; done. Several arenas, so a slow client never stalls the next pass.
(defconstant +arenas+ 8)
(defconstant +arena-bytes+ (* 8 1024 1024))
(defconstant +arena-need+ (* 192 1024))      ; room required before serving one request

;;; ---- connections -------------------------------------------------------------------------
(defconstant +idle-seconds+ 300)        ; idle keep-alive limit (the spec needs >= 65 s)
(defconstant +idle-low-mem-seconds+ 70) ; ...when MemAvailable is under +low-mem-kb+
(defconstant +low-mem-kb+ 98304)
(defconstant +sweep-per-pass+ 128)      ; most connection slots examined in one pass by the idle sweep
(defconstant +sweep-cycle-s+ 20)        ; ...paced so the sweep covers every slot once per this many seconds
(defconstant +pend-max+ 70000)          ; bytes of one request kept per connection

;;; ---- the self-tuning wait policy (M7) -----------------------------------------------------------
;;; The wait above is a point in a small grid. Each of the three knobs has five levels; the event loop is
;;; generated once per point with the three numbers baked in as constants. The middle three levels of
;;; every knob (27 points) are compiled when the server image is built; the outer levels are compiled
;;; live, at most once per +ctl-compile-gap-s+, only when the controller's climb reaches them.
;;; Point number = (batch-level * 5 + min-level) * 5 + ns-level.  Level 2 of each knob is the base
;;; policy (+batch-open+, +wait-min+, +wait-ns+ above), point 62.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *batch-levels* #(64 128 256 512 1024))            ; connections open: always wait for a batch
  (defparameter *min-levels* #(64 128 256 512 1024))              ; completions that end a busy wait
  (defparameter *ns-levels* #(250000 500000 1000000 2000000 4000000))) ; the wait gives up after this long
(defconstant +npoints+ 125)
(defconstant +base-point+ 62)

;;; ---- the controller (reads only generic load signals; see README "Rule 7") ----------------------
(defconstant +ctl-tick-s+ 3)            ; seconds per measurement window
(defconstant +ctl-min-conns+ 256)       ; below this many open connections: base policy, no exploring
(defconstant +ctl-min-rps+ 4000)        ; ...or below this many requests per second
(defconstant +ctl-hyst-permille+ 40)    ; a candidate must cost this much (4 %) less per request to win
(defconstant +ctl-steady-permille+ 50)  ; windows whose request rate differs by more than 5 % are discarded
(defconstant +ctl-guard-wait-us+ 250000); longest queued-answer wait allowed in a window on a non-base point
(defconstant +ctl-bad-s+ 120)           ; a point that broke the guard (or lost the confirm) rests this long
(defconstant +ctl-converged-ticks+ 15)  ; windows spent on the winner before the next sweep (30 s)
(defconstant +ctl-pause-s+ 30)          ; base policy this long after the signals looked wrong
(defconstant +ctl-compile-gap-s+ 10)    ; live COMPILE: at most once per this many seconds
