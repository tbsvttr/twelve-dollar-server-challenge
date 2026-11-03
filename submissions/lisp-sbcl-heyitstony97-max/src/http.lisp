;;;; HTTP/1.1 request parsing over foreign memory, and the response plumbing: fixed responses
;;;; (complete octet vectors, Content-Length baked in, copied to foreign memory at boot) and the
;;;; dynamic-response header writer.
(in-package #:feed)

(declaim (optimize (speed 3) (safety 0) (debug 0)))

;;; ---- Foreign working memory (allocated at boot, never in the Lisp heap) ------------------

(defconstant +rbuf-size+ 65536)
(sb-ext:defglobal **rbuf** 0)        ; shared receive buffer
(sb-ext:defglobal **body-buf** 0)    ; unescaped POST body
(declaim (type addr **rbuf** **body-buf**))

(defun init-memory ()
  (setf **rbuf** (foreign-alloc +rbuf-size+)
        **w** (foreign-alloc +arena-size+)
        **body-buf** (foreign-alloc (* 2 +rbuf-size+))
        **jwt-buf** (foreign-alloc 16384)
        **tail** (foreign-alloc 128)
        **digest** (foreign-alloc 128)
        **wp** +hdr-room+)
  t)

;;; ---- Request parsing -------------------------------------------------------------------

(sb-ext:defglobal **req-method** 0)       ; 0 GET, 1 POST, 2 other
(sb-ext:defglobal **req-ps** 0)           ; path start/end (query string excluded)
(sb-ext:defglobal **req-pe** 0)
(sb-ext:defglobal **req-auth-s** -1)      ; Authorization value, -1 when absent
(sb-ext:defglobal **req-auth-e** -1)
(sb-ext:defglobal **req-clen** 0)
(sb-ext:defglobal **req-head** 0)         ; offset just past the blank line
(sb-ext:defglobal **req-close** nil)
(sb-ext:defglobal **req-expect** nil)
(declaim (type fixnum **req-method** **req-ps** **req-pe** **req-auth-s** **req-auth-e** **req-clen** **req-head**))

(defconstant +parse-incomplete+ 0)
(defconstant +parse-bad+ -1)
(defconstant +parse-too-big+ -2)
(defconstant +max-head+ 16384)

(defmacro name-is (sap start end lit)
  "Case-insensitive compare of SAP[START,END) with the lower-case literal LIT."
  (let ((n (length lit)))
    `(and (= (- ,end ,start) ,n)
          ,@(loop for i from 0 below n
                  collect `(= (logior (ref ,sap (+ ,start ,i)) 32) ,(char-code (char lit i)))))))

(defun find-head-end (buf len)
  "Offset just past the first CRLFCRLF in BUF[0,LEN), or -1."
  (declare (type addr buf) (type fixnum len))
  (loop for i of-type fixnum from 3 below len
        do (when (and (= (ref buf i) 10) (= (ref buf (- i 1)) 13)
                      (= (ref buf (- i 2)) 10) (= (ref buf (- i 3)) 13))
             (return-from find-head-end (1+ i))))
  -1)

(defun parse-request (buf len)
  "Parses the request at BUF[0,LEN). Returns the request's total length (head + body) when it is
complete, +parse-incomplete+ when more bytes are needed, +parse-bad+ / +parse-too-big+ otherwise.
Fills the **req-...** globals."
  (declare (type addr buf) (type fixnum len))
  (setf **req-expect** nil **req-head** 0)
  (let ((head (find-head-end buf len)))
    (declare (type fixnum head))
    (when (< head 0)
      (return-from parse-request (if (> len +max-head+) +parse-too-big+ +parse-incomplete+)))
    (when (> head +max-head+) (return-from parse-request +parse-too-big+))
    ;; request line
    (let ((i 0))
      (declare (type fixnum i))
      (cond ((and (>= head 4) (= (ref buf 0) (bc #\G)) (= (ref buf 1) (bc #\E)) (= (ref buf 2) (bc #\T)) (= (ref buf 3) 32))
             (setf **req-method** 0 i 4))
            ((and (>= head 5) (= (ref buf 0) (bc #\P)) (= (ref buf 1) (bc #\O)) (= (ref buf 2) (bc #\S))
                  (= (ref buf 3) (bc #\T)) (= (ref buf 4) 32))
             (setf **req-method** 1 i 5))
            (t (setf **req-method** 2)
               (loop while (and (< i head) (/= (ref buf i) 32)) do (incf i))
               (incf i)))
      (setf **req-ps** i)
      (loop while (and (< i head) (/= (ref buf i) 32) (/= (ref buf i) 63) (/= (ref buf i) 13)) do (incf i))
      (setf **req-pe** i)
      (loop while (and (< i head) (/= (ref buf i) 32) (/= (ref buf i) 13)) do (incf i))
      (unless (and (< (+ i 10) head) (= (ref buf i) 32)
                   (= (ref buf (+ i 1)) (bc #\H)) (= (ref buf (+ i 2)) (bc #\T)) (= (ref buf (+ i 3)) (bc #\T))
                   (= (ref buf (+ i 4)) (bc #\P)) (= (ref buf (+ i 5)) 47) (= (ref buf (+ i 6)) (bc #\1))
                   (= (ref buf (+ i 7)) 46) (= (ref buf (+ i 10)) 10) (= (ref buf (+ i 9)) 13))
        (return-from parse-request +parse-bad+))
      (setf **req-close** (/= (ref buf (+ i 8)) (bc #\1)))   ; HTTP/1.0 closes unless it asks otherwise
      (setf i (+ i 11))
      (setf **req-auth-s** -1 **req-auth-e** -1 **req-clen** 0 **req-expect** nil **req-head** head)
      ;; headers
      (loop
        (when (>= i (- head 2)) (return))
        (let ((ls i) (colon -1) (le -1))
          (declare (type fixnum ls colon le))
          (loop for j of-type fixnum from i below head
                do (let ((b (ref buf j)))
                     (when (and (< colon 0) (= b 58)) (setf colon j))
                     (when (= b 13) (setf le j) (return))))
          (when (or (< colon 0) (< le 0) (= colon ls)) (return-from parse-request +parse-bad+))
          (let ((vs (1+ colon)) (ve le))
            (declare (type fixnum vs ve))
            (loop while (and (< vs ve) (or (= (ref buf vs) 32) (= (ref buf vs) 9))) do (incf vs))
            (loop while (and (> ve vs) (or (= (ref buf (1- ve)) 32) (= (ref buf (1- ve)) 9))) do (decf ve))
            (cond ((name-is buf ls colon "authorization") (setf **req-auth-s** vs **req-auth-e** ve))
                  ((name-is buf ls colon "content-length")
                   (let ((n (parse-uint buf vs ve)))
                     (when (< n 0) (return-from parse-request +parse-bad+))
                     (setf **req-clen** n)))
                  ((name-is buf ls colon "transfer-encoding") (return-from parse-request +parse-bad+))
                  ((name-is buf ls colon "connection")
                   (when (> ve vs)
                     (let ((c (logior (ref buf vs) 32)))
                       (cond ((= c (bc #\c)) (setf **req-close** t))
                             ((= c (bc #\k)) (setf **req-close** nil))))))
                  ((name-is buf ls colon "expect")
                   (setf **req-expect** t))))
          (setf i (+ le 2))))
      (let ((total (+ head **req-clen**)))
        (declare (type fixnum total))
        (cond ((> total (- +rbuf-size+ 1)) +parse-too-big+)
              ((> total len) +parse-incomplete+)
              (t total))))))

;;; ---- Responses -------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun status-text (s)
    (ecase s (100 "Continue") (200 "OK") (201 "Created") (400 "Bad Request") (401 "Unauthorized")
      (404 "Not Found") (413 "Payload Too Large") (500 "Internal Server Error") (503 "Service Unavailable")))

  (defun status-prefix (status)
    "Everything up to the Content-Length digits."
    (octets "HTTP/1.1 " (format nil "~D ~A" status (status-text status)) (crlf)
            "Content-Type: application/json" (crlf) "Content-Length: "))

  (defvar *response-index* (make-hash-table :test 'eq))
  (defvar *response-defs* (make-hash-table)))

(sb-ext:defglobal **fixed-addr** (make-array 64 :element-type 'fixnum :initial-element 0))
(sb-ext:defglobal **fixed-len** (make-array 64 :element-type 'fixnum :initial-element 0))
(declaim (type (simple-array fixnum (64)) **fixed-addr** **fixed-len**))

(defun register-response (idx bytes) (setf (gethash idx *response-defs*) bytes))

(defun init-responses ()
  "Copy every fixed response into one block of foreign memory."
  (let ((total (loop for v being the hash-values of *response-defs* sum (length v))))
    (let ((block (foreign-alloc (max total 1))) (off 0))
      (loop for idx being the hash-keys of *response-defs* using (hash-value v)
            do (copy-octets-in v block off (length v))
               (setf (aref **fixed-addr** idx) (+ (addr-id block) off)
                     (aref **fixed-len** idx) (length v))
               (incf off (length v)))))
  t)

(defmacro defresponse (name status message)
  "A complete error response: status line, headers, Content-Length and body, all built at compile time."
  (let* ((idx (or (gethash name *response-index*)
                  (setf (gethash name *response-index*) (hash-table-count *response-index*))))
         (body (octets (format nil "{\"error\":\"~A\"}" message)))
         (bytes (octets (status-prefix status) (format nil "~D" (length body)) (crlf) (crlf) body)))
    `(progn (defconstant ,name ,idx)
            (register-response ,idx ,bytes))))

(defmacro defraw-response (name string)
  (let ((idx (or (gethash name *response-index*)
                 (setf (gethash name *response-index*) (hash-table-count *response-index*)))))
    `(progn (defconstant ,name ,idx)
            (register-response ,idx ,(octets string)))))

;;; The response the connection layer will send: an address in foreign memory and a length.
(sb-ext:defglobal **out-addr** 0)
(sb-ext:defglobal **out-len** 0)
(declaim (type fixnum **out-addr** **out-len**))

(declaim (inline respond-fixed))
(defun respond-fixed (idx)
  (declare (type fixnum idx))
  (setf **out-addr** (aref **fixed-addr** idx) **out-len** (aref **fixed-len** idx)))

(defmacro finish-dynamic (status)
  "The body is in the arena from +hdr-room+ to **wp**; write the header right before it."
  `(finish-dynamic-with (load-time-value (status-prefix ,status) t)))

(defun finish-dynamic-with (prefix)
  (declare (type octets prefix))
  (let* ((blen (- **wp** +hdr-room+))
         (save **wp**))
    (declare (type fixnum blen save))
    ;; the header is at most 256 bytes; write it ending exactly at +hdr-room+
    (setf **wp** 0)
    (w-octets prefix)
    (w-int blen)
    (w-byte 13) (w-byte 10) (w-byte 13) (w-byte 10)
    (let ((hlen **wp**))
      (declare (type fixnum hlen))
      (%memmove (a+ **w** (- +hdr-room+ hlen)) **w** hlen)
      (setf **out-addr** (+ (addr-id **w**) (- +hdr-room+ hlen))
            **out-len** (+ hlen blen)))
    (setf **wp** save)
    nil))
