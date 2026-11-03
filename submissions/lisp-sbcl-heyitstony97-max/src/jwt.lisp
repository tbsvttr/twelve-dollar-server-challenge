;;;; SHA-256, HMAC-SHA256 with precomputed pad states, base64url, and HS256 bearer-token checks.
;;;; Everything reads straight from foreign memory.
(in-package #:feed)

(declaim (optimize (speed 3) (safety 0) (debug 0)))

;;; ---- SHA-256 ---------------------------------------------------------------------------

(declaim (type (simple-array (unsigned-byte 32) (64)) +k256+))
(sb-ext:defglobal +k256+
  (make-array 64 :element-type '(unsigned-byte 32)
                 :initial-contents
                 '(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
                   #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
                   #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
                   #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
                   #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
                   #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
                   #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
                   #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2)))

(deftype h32 () '(simple-array (unsigned-byte 32) (8)))
(deftype w64 () '(simple-array (unsigned-byte 32) (64)))
(defmacro h32-iv ()
  `(make-array 8 :element-type '(unsigned-byte 32)
                 :initial-contents '(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                                     #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19)))

(sb-ext:defglobal **h** (h32-iv))              ; working state
(sb-ext:defglobal **w64** (make-array 64 :element-type '(unsigned-byte 32)))
(sb-ext:defglobal **ipad-state** (h32-iv))
(sb-ext:defglobal **opad-state** (h32-iv))
(declaim (type h32 **h** **ipad-state** **opad-state**) (type w64 **w64**))

(sb-ext:defglobal **tail** 0)   ; 128 bytes of foreign scratch
(sb-ext:defglobal **digest** 0) ; 64 bytes of foreign scratch
(declaim (type addr **tail** **digest**))

(defmacro rotr32 (x n)
  `(logior (ldb (byte 32 0) (ash ,x ,(- 32 n))) (ash ,x ,(- n))))

(defun sha256-block (h sap offset)
  "Compress the 64 bytes at SAP+OFFSET into state H."
  (declare (type h32 h) (type addr sap) (type fixnum offset)
           (optimize (speed 3) (safety 0) (debug 0)))
  (let ((w **w64**) (k +k256+))
    (declare (type w64 w k))
    (dotimes (i 16)
      (let ((p (+ offset (* i 4))))
        (declare (type fixnum p))
        (setf (aref w i)
              (logior (ash (a-ref-8 sap p) 24) (ash (a-ref-8 sap (+ p 1)) 16)
                      (ash (a-ref-8 sap (+ p 2)) 8) (a-ref-8 sap (+ p 3))))))
    (loop for i of-type fixnum from 16 below 64
          do (let* ((w15 (aref w (- i 15))) (w2 (aref w (- i 2)))
                    (s0 (logxor (rotr32 w15 7) (rotr32 w15 18) (ash w15 -3)))
                    (s1 (logxor (rotr32 w2 17) (rotr32 w2 19) (ash w2 -10))))
               (declare (type (unsigned-byte 32) w15 w2 s0 s1))
               (setf (aref w i)
                     (ldb (byte 32 0) (+ (aref w (- i 16)) s0 (aref w (- i 7)) s1)))))
    (let ((a (aref h 0)) (b (aref h 1)) (c (aref h 2)) (d (aref h 3))
          (e (aref h 4)) (f (aref h 5)) (g (aref h 6)) (hh (aref h 7)))
      (declare (type (unsigned-byte 32) a b c d e f g hh))
      (dotimes (i 64)
        (let* ((s1 (logxor (rotr32 e 6) (rotr32 e 11) (rotr32 e 25)))
               (ch (logxor (logand e f) (logand (logxor e #xFFFFFFFF) g)))
               (t1 (ldb (byte 32 0) (+ hh s1 ch (aref k i) (aref w i))))
               (s0 (logxor (rotr32 a 2) (rotr32 a 13) (rotr32 a 22)))
               (maj (logxor (logand a b) (logand a c) (logand b c)))
               (t2 (ldb (byte 32 0) (+ s0 maj))))
          (declare (type (unsigned-byte 32) s1 ch t1 s0 maj t2))
          (setf hh g g f f e
                e (ldb (byte 32 0) (+ d t1))
                d c c b b a
                a (ldb (byte 32 0) (+ t1 t2)))))
      (setf (aref h 0) (ldb (byte 32 0) (+ (aref h 0) a))
            (aref h 1) (ldb (byte 32 0) (+ (aref h 1) b))
            (aref h 2) (ldb (byte 32 0) (+ (aref h 2) c))
            (aref h 3) (ldb (byte 32 0) (+ (aref h 3) d))
            (aref h 4) (ldb (byte 32 0) (+ (aref h 4) e))
            (aref h 5) (ldb (byte 32 0) (+ (aref h 5) f))
            (aref h 6) (ldb (byte 32 0) (+ (aref h 6) g))
            (aref h 7) (ldb (byte 32 0) (+ (aref h 7) hh))))
    nil))

(defun sha256-run (h sap len prefix)
  "Feeds LEN bytes at SAP through the blocks and the padded tail, into H. PREFIX is the number
of bytes already absorbed into H (64 for HMAC's inner hash), which the length field counts."
  (declare (type h32 h) (type addr sap) (type fixnum len prefix))
  (let* ((full (ash len -6))
         (rem (logand len 63))
         (tail **tail**))
    (dotimes (i full) (sha256-block h sap (* i 64)))
    (%memmove tail (a+ sap (* full 64)) rem)
    (setf (a-ref-8 tail rem) #x80)
    (let* ((nblocks (if (< rem 56) 1 2))
           (total (* nblocks 64))
           (bits (* 8 (+ prefix len))))
      (loop for i from (1+ rem) below total do (setf (a-ref-8 tail i) 0))
      (dotimes (i 8)
        (setf (a-ref-8 tail (- total 1 i)) (ldb (byte 8 (* i 8)) bits)))
      (dotimes (i nblocks) (sha256-block h tail (* i 64)))))
  h)

(defun digest-to-sap (h dst)
  (declare (type h32 h) (type addr dst))
  (dotimes (i 8)
    (let ((x (aref h i)))
      (setf (a-ref-8 dst (* i 4)) (ldb (byte 8 24) x)
            (a-ref-8 dst (+ 1 (* i 4))) (ldb (byte 8 16) x)
            (a-ref-8 dst (+ 2 (* i 4))) (ldb (byte 8 8) x)
            (a-ref-8 dst (+ 3 (* i 4))) (ldb (byte 8 0) x)))))

(defun init-hmac (secret)
  "Precompute the inner/outer pad states for SECRET (an octet vector)."
  (declare (type octets secret))
  (let ((key (foreign-alloc 64))
        (blk (foreign-alloc 64)))
    (dotimes (i 64) (setf (a-ref-8 key i) 0))
    (if (> (length secret) 64)
        (let ((tmp (foreign-alloc (length secret))) (h (h32-iv)))
          (copy-octets-in secret tmp 0 (length secret))
          (sha256-run h tmp (length secret) 0)
          (digest-to-sap h key)
          (%free tmp))
        (copy-octets-in secret key 0 (length secret)))
    (flet ((pad-state (state x)
             (dotimes (i 64) (setf (a-ref-8 blk i) (logxor x (a-ref-8 key i))))
             (replace state (h32-iv))
             (sha256-block state blk 0)))
      (pad-state **ipad-state** #x36)
      (pad-state **opad-state** #x5c))
    (%free key) (%free blk)
    t))

(defun hmac-sha256 (sap len)
  "HMAC of the LEN bytes at SAP with the configured secret; the 32-byte result is left in **digest**."
  (declare (type addr sap) (type fixnum len))
  (let ((h **h**))
    (replace h **ipad-state**)
    (sha256-run h sap len 64)
    (let ((d **digest**))
      (digest-to-sap h d)
      ;; outer: one block = 32 digest bytes, 0x80, zeros, bit length 96*8 = 768
      (let ((blk (a+ d 32)))
        (%memmove blk d 32)
        (setf (a-ref-8 blk 32) #x80)
        (loop for i from 33 below 62 do (setf (a-ref-8 blk i) 0))
        (setf (a-ref-8 blk 62) 3 (a-ref-8 blk 63) 0)
        (replace h **opad-state**)
        (sha256-block h blk 0)
        (digest-to-sap h d))))
  nil)

;;; ---- base64url -------------------------------------------------------------------------

(declaim (type (simple-array (signed-byte 16) (256)) **b64-dec**) (type octets **b64-enc**))
(sb-ext:defglobal **b64-enc**
  (octets "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))
(sb-ext:defglobal **b64-dec**
  (let ((a (make-array 256 :element-type '(signed-byte 16) :initial-element -1)))
    (dotimes (i 64) (setf (aref a (aref **b64-enc** i)) i))
    a))

(defun b64url-encode-digest (src dst)
  "The 32 bytes at SRC as 43 base64url characters at DST."
  (declare (type addr src dst))
  (let ((enc **b64-enc**) (o 0))
    (declare (type fixnum o))
    (loop for i from 0 below 30 by 3
          do (let ((n (logior (ash (ref src i) 16) (ash (ref src (+ i 1)) 8) (ref src (+ i 2)))))
               (dotimes (k 4)
                 (setf (a-ref-8 dst o) (aref enc (ldb (byte 6 (* 6 (- 3 k))) n)))
                 (incf o))))
    ;; last two bytes -> 3 chars
    (let ((n (logior (ash (ref src 30) 16) (ash (ref src 31) 8))))
      (dotimes (k 3)
        (setf (a-ref-8 dst o) (aref enc (ldb (byte 6 (* 6 (- 3 k))) n)))
        (incf o)))
    43))

(defun b64url-decode (src start end dst)
  "Decodes SRC[START,END) into DST. Returns the byte count, or -1 on any invalid character."
  (declare (type addr src dst) (type fixnum start end))
  (let ((dec **b64-dec**) (acc 0) (bits 0) (o 0))
    (declare (type fixnum acc bits o))
    (when (= (mod (- end start) 4) 1) (return-from b64url-decode -1))
    (loop for i of-type fixnum from start below end
          do (let ((v (aref dec (ref src i))))
               (when (< v 0) (return-from b64url-decode -1))
               (setf acc (logior (ash (logand acc #xFFFF) 6) v))
               (incf bits 6)
               (when (>= bits 8)
                 (decf bits 8)
                 (setf (a-ref-8 dst o) (ldb (byte 8 bits) acc))
                 (incf o))))
    o))

;;; ---- Bearer tokens ---------------------------------------------------------------------

(sb-ext:defglobal **jwt-buf** 0)   ; 16 KB scratch
(declaim (type addr **jwt-buf**))
(sb-ext:defglobal **user-id** 0)
(sb-ext:defglobal **username-start** 0)   ; raw (still escaped) username inside **jwt-buf**
(sb-ext:defglobal **username-end** 0)
(declaim (type fixnum **user-id** **username-start** **username-end**))

(defconstant +auth-missing+ -1)
(defconstant +auth-invalid+ -2)
(defconstant +auth-payload+ -3)

(sb-ext:defglobal **names-alg** (vector (octets "alg")))
(sb-ext:defglobal **names-claims** (vector (octets "exp") (octets "sub") (octets "username")))
(declaim (type simple-vector **names-alg** **names-claims**))

(defun parse-uint (sap start end)
  "Digits only, value fits in 62 bits; -1 otherwise."
  (declare (type addr sap) (type fixnum start end))
  (when (or (<= end start) (> (- end start) 18)) (return-from parse-uint -1))
  (let ((n 0))
    (declare (type (unsigned-byte 62) n))
    (loop for i of-type fixnum from start below end
          do (let ((b (ref sap i)))
               (unless (digit-p b) (return-from parse-uint -1))
               (setf n (the (unsigned-byte 62) (+ (the (unsigned-byte 62) (* n 10)) (- b 48))))))
    n))

(defun number-floor (sap start end)
  "Integer part of a JSON number (exp). Fractions are floored; returns most-negative-fixnum on junk."
  (declare (type addr sap) (type fixnum start end))
  (let ((neg nil) (i start) (n 0))
    (declare (type fixnum i) (type (unsigned-byte 62) n))
    (when (and (< i end) (= (ref sap i) 45)) (setf neg t) (incf i))
    (loop while (and (< i end) (digit-p (ref sap i)))
          do (when (> n (ash 1 50)) (return-from number-floor most-positive-fixnum))
             (setf n (the (unsigned-byte 62) (+ (the (unsigned-byte 62) (* n 10)) (- (ref sap i) 48))))
             (incf i))
    ;; exponent forms are not used by token issuers; treat the mantissa as-is
    (if neg (- n) n)))

(defun authenticate (hdr-start hdr-end buf now)
  "Checks the Authorization header value BUF[HDR-START,HDR-END). Returns a positive user id
(and sets **username-start/end**), or one of +auth-missing+ / +auth-invalid+ / +auth-payload+."
  (declare (type fixnum hdr-start hdr-end now) (type addr buf))
  (when (or (< hdr-start 0)
            (< (- hdr-end hdr-start) 7)
            (not (and (= (ref buf hdr-start) (bc #\B)) (= (ref buf (+ hdr-start 1)) (bc #\e))
                      (= (ref buf (+ hdr-start 2)) (bc #\a)) (= (ref buf (+ hdr-start 3)) (bc #\r))
                      (= (ref buf (+ hdr-start 4)) (bc #\e)) (= (ref buf (+ hdr-start 5)) (bc #\r))
                      (= (ref buf (+ hdr-start 6)) 32))))
    (return-from authenticate +auth-missing+))
  (let* ((ts (+ hdr-start 7)) (te hdr-end)
         (d1 -1) (d2 -1))
    (declare (type fixnum ts te d1 d2))
    (loop for i of-type fixnum from ts below te
          do (when (= (ref buf i) 46)
               (cond ((< d1 0) (setf d1 i))
                     ((< d2 0) (setf d2 i))
                     (t (return-from authenticate +auth-invalid+)))))
    (when (or (< d1 0) (< d2 0) (= d1 ts) (= d2 (1+ d1)) (/= (- te d2 1) 43) (> (- d2 ts) 4000))
      (return-from authenticate +auth-invalid+))
    ;; signature over "header.payload"
    (hmac-sha256 (a+ buf ts) (- d2 ts))
    (let ((enc (a+ **jwt-buf** 12288)) (diff 0))
      (declare (type fixnum diff))
      ;; encode into the last quarter of the jwt scratch, compare in constant time
      (b64url-encode-digest **digest** enc)
      (dotimes (i 43) (setf diff (logior diff (logxor (ref enc i) (ref buf (+ d2 1 i))))))
      (unless (zerop diff) (return-from authenticate +auth-invalid+)))
    ;; header: alg must be "HS256"
    (let* ((hbuf **jwt-buf**)
           (hn (b64url-decode buf ts d1 hbuf)))
      (declare (type fixnum hn))
      (when (or (< hn 0) (> hn 4000)) (return-from authenticate +auth-invalid+))
      (setf **json-names** **names-alg**)
      (unless (and (= (json-find-fields hbuf hn) 0)
                   (= (aref **jf-type** 0) 1)
                   (key-matches-p hbuf (aref **jf-start** 0) (aref **jf-end** 0) (load-time-value (octets "HS256") t)))
        (return-from authenticate +auth-invalid+)))
    ;; payload
    (let* ((pbuf (a+ **jwt-buf** 4096))
           (pn (b64url-decode buf (1+ d1) d2 pbuf)))
      (declare (type fixnum pn))
      (when (or (< pn 0) (> pn 4000)) (return-from authenticate +auth-invalid+))
      (setf **json-names** **names-claims**)
      (unless (= (json-find-fields pbuf pn) 0) (return-from authenticate +auth-invalid+))
      ;; exp: required, must be in the future
      (unless (= (aref **jf-type** 0) 2) (return-from authenticate +auth-invalid+))
      (when (<= (number-floor pbuf (aref **jf-start** 0) (aref **jf-end** 0)) now)
        (return-from authenticate +auth-invalid+))
      ;; sub: a string of a positive integer; username: a string
      (let ((uid (if (= (aref **jf-type** 1) 1)
                     (parse-uint pbuf (aref **jf-start** 1) (aref **jf-end** 1))
                     -1)))
        (declare (type fixnum uid))
        (when (or (<= uid 0) (/= (aref **jf-type** 2) 1))
          (return-from authenticate +auth-payload+))
        (setf **username-start** (+ 4096 (aref **jf-start** 2))
              **username-end** (+ 4096 (aref **jf-end** 2)))
        uid))))
