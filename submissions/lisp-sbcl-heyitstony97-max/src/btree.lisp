;;;; Reads through SQLite's own B-tree cursors (the organiser allowed this in PR #153). The cursors
;;;; are opened in the pass's read transaction (csrc/shim.c); records are decoded here with
;;;; sap-ref and nothing is consed. Every request seeks and reads its rows live; the only things kept
;;;; between requests are the cursors and four root page numbers that the startup check resolved from
;;;; sqlite_schema. Any surprise (schema, a record that is not in the expected form, a missing user)
;;;; makes the caller answer with the prepared-SQL query instead.
(in-package #:feed)

(declaim (optimize (speed 3) (safety 0) (debug 0)))

(sb-ext:defglobal **bt-on** nil)
(sb-ext:defglobal **bt-mem** 0)          ; scratch (see layout below)
(sb-ext:defglobal **cur-posts** 0)
(sb-ext:defglobal **cur-users** 0)
(sb-ext:defglobal **cur-feed** 0)
(sb-ext:defglobal **cur-likes** 0)
(sb-ext:defglobal **vp** 0)              ; varint reader position
(sb-ext:defglobal **tpos** 0)            ; next free byte of the text buffer
(declaim (type addr **bt-mem** **cur-posts** **cur-users** **cur-feed** **cur-likes**)
         (type fixnum **vp** **tpos**))

;;; Scratch layout (bytes from **bt-mem**)
(defconstant +bt-len+ 0)                 ; u32 out-word for td_payload
(defconstant +bt-cols+ 64)               ; 4 columns x (u64 serial type, u64 address)
(defconstant +bt-rows+ 256)              ; 20 rows x 64 bytes
(defconstant +bt-order+ 1536)            ; 20 x u8: row indices, ascending id
(defconstant +bt-counts+ 2048)           ; 513 x u32 like counters
(defconstant +bt-text+ 8192)             ; text buffer
(defconstant +bt-text-size+ 131072)
(defconstant +bt-feed-rows+ 20)
(defconstant +bt-span+ 512)              ; one range walk of the likes index when ids lie this close
(defconstant +bt-bad+ most-negative-fixnum)

;;; Row fields (offset from the row)
(defconstant +r-id+ 0)
(defconstant +r-uid+ 8)
(defconstant +r-body+ 16)                ; u32 text offset, u32 length at +4
(defconstant +r-created+ 24)
(defconstant +r-author+ 32)
(defconstant +r-likes+ 40)

(defconstant +bt-ok+ 0)
(defconstant +bt-missing+ 1)
(defconstant +bt-fallback+ 3)

(defmacro bt-row (i) `(+ **bt-mem** +bt-rows+ (* 64 ,i)))

(declaim (inline varint))
(defun varint (p limit)
  "The varint at P+**vp** (bytes before LIMIT); advances **vp**. -1 when truncated or 9 bytes long."
  (declare (type addr p) (type fixnum limit))
  (let ((pos **vp**))
    (declare (type fixnum pos))
    (if (>= pos limit)
        -1
        (let ((b (ref p pos)))
          (if (< b 128)
              (progn (setf **vp** (1+ pos)) b)
              (varint-long p limit))))))

(defun varint-long (p limit)
  (declare (type addr p) (type fixnum limit))
  (fast
    (let ((v 0) (pos **vp**))
      (declare (type (unsigned-byte 56) v) (type fixnum pos))
      (dotimes (k 8 -1)
        (when (>= pos limit) (return -1))
        (let ((b (ref p pos)))
          (incf pos)
          (setf v (logior (logand (ash v 7) #xFFFFFFFFFFFFFF) (logand b 127)))
          (when (< b 128)
            (setf **vp** pos)
            (return v)))))))

(declaim (inline serial-len))
(defun serial-len (ty)
  (declare (type (unsigned-byte 56) ty))
  (cond ((<= ty 4) ty)
        ((= ty 5) 6)
        ((<= ty 7) 8)
        ((<= ty 11) 0)
        (t (ash (- ty 12) -1))))

(defun rec-cols (p len n)
  "Reads the header of the record at P (LEN bytes) and stores serial type and address of its first N
columns in the scratch columns. NIL when the record is shorter or malformed."
  (declare (type addr p) (type fixnum len n))
  (fast
    (setf **vp** 0)
    (let ((hsize (varint p len)) (cols (+ **bt-mem** +bt-cols+)))
      (declare (type fixnum hsize) (type addr cols))
      (when (or (< hsize 1) (> hsize len)) (return-from rec-cols nil))
      (let ((body hsize))
        (declare (type fixnum body))
        (dotimes (i n)
          (when (>= **vp** hsize) (return-from rec-cols nil))
          (let ((ty (varint p hsize)))
            (declare (type fixnum ty))
            (when (< ty 0) (return-from rec-cols nil))
            (let ((sl (serial-len ty)))
              (declare (type fixnum sl))
              (when (> (+ body sl) len) (return-from rec-cols nil))
              (setf (a-ref-64 cols (* 16 i)) ty
                    (a-ref-64 cols (+ 8 (* 16 i))) (+ p body))
              (incf body sl)))))
      t)))

(defun col-int (i)
  "Column I as an integer (serial types 1-5, 8, 9), or +bt-bad+."
  (declare (type fixnum i))
  (fast
    (let* ((cols (+ **bt-mem** +bt-cols+))
           (ty (a-ref-64 cols (* 16 i)))
           (a (a-ref-64 cols (+ 8 (* 16 i)))))
      (declare (type addr cols a) (type (unsigned-byte 62) ty))
      (cond ((= ty 8) 0)
            ((= ty 9) 1)
            ((<= 1 ty 5)
             (let ((n (if (= ty 5) 6 ty))
                   (v (let ((b (ref a 0))) (if (>= b 128) (- b 256) b))))
               (declare (type fixnum n) (type (signed-byte 56) v))
               (loop for k of-type fixnum from 1 below n
                     do (setf v (logior (the (signed-byte 56) (ash (the (signed-byte 48) v) 8)) (ref a k))))
               v))
            (t +bt-bad+)))))

(defun col-text-copy (i)
  "Copies the TEXT column I into the text buffer. Returns its offset (length is 4 bytes before it is
needed: stored at offset+0... see below) -- here: returns the start offset, or -1; **tpos** advances."
  (declare (type fixnum i))
  (fast
    (let* ((cols (+ **bt-mem** +bt-cols+))
           (ty (a-ref-64 cols (* 16 i)))
           (a (a-ref-64 cols (+ 8 (* 16 i)))))
      (declare (type addr cols a) (type (unsigned-byte 62) ty))
      (if (and (>= ty 13) (logtest ty 1))
          (let ((n (ash (- ty 13) -1)) (at **tpos**))
            (declare (type fixnum n at))
            (if (> (+ at n) +bt-text-size+)
                -1
                (progn (%memmove (+ **bt-mem** +bt-text+ at) a n)
                       (setf **tpos** (+ at n))
                       at)))
          -1))))

(defun col-text-len (i)
  (declare (type fixnum i))
  (fast
    (let ((ty (a-ref-64 (+ **bt-mem** +bt-cols+) (* 16 i))))
      (declare (type (unsigned-byte 62) ty))
      (ash (- ty 13) -1))))

(defun payload-of (c)
  "Record bytes of the cursor's current row: sets the length word, returns the address (0 on error)."
  (declare (type addr c))
  (%td-payload c (+ **bt-mem** +bt-len+)))

(defmacro cur-record (c n)
  "True when cursor C's current record has N decodable columns (columns land in the scratch)."
  `(let ((p (payload-of ,c)))
     (declare (type addr p))
     (and (/= p 0) (rec-cols p (a-ref-32 **bt-mem** +bt-len+) ,n))))

(defun bt-count-likes (id)
  "Likes of post ID, or -1 to fall back."
  (declare (type fixnum id))
  (let ((cnt (+ **bt-mem** +bt-counts+)))
    (setf (a-ref-32 cnt 0) 0)
    (if (zerop (%td-count-likes **cur-likes** id id cnt))
        (a-ref-32 cnt 0)
        -1)))

(defun bt-open (err)
  "Startup: verify the schema and resolve the root pages (csrc/shim.c). T when the B-tree path is on."
  (declare (type addr err))
  (setf **bt-on** nil)
  (cond ((/= 0 (%td-bt-init err 1024)) nil)
        (t
         (when (zerop **bt-mem**)
           (setf **bt-mem** (foreign-alloc (+ +bt-text+ +bt-text-size+))))
         (setf **cur-posts** (%td-cursor 0) **cur-users** (%td-cursor 1)
               **cur-feed** (%td-cursor 2) **cur-likes** (%td-cursor 3)
               **bt-on** t)
         t)))

;;; ---- GET /posts/:id and the like handler's existence check -----------------------------------

(defun bt-post-exists (id)
  (declare (type fixnum id))
  (let ((r (%td-seek **cur-posts** id)))
    (cond ((= r 1) +bt-ok+) ((= r 0) +bt-missing+) (t +bt-fallback+))))

(defun bt-get-post (id)
  "Writes {\"post\":{...}} for post ID. +bt-ok+, +bt-missing+, or +bt-fallback+ (nothing written)."
  (declare (type fixnum id))
  (let ((start **wp**) (uid 0))
    (declare (type fixnum start uid))
    (let ((r (%td-seek **cur-posts** id)))
      (cond ((= r 0) (return-from bt-get-post +bt-missing+))
            ((/= r 1) (return-from bt-get-post +bt-fallback+))))
    (unless (cur-record **cur-posts** 4) (return-from bt-get-post +bt-fallback+))
    (let ((cols (+ **bt-mem** +bt-cols+)))
      (declare (type addr cols))
      (setf uid (col-int 1))
      (when (= uid +bt-bad+) (return-from bt-get-post +bt-fallback+))
      (let ((ty-b (a-ref-64 cols 32)) (ty-c (a-ref-64 cols 48)))
        (declare (type (unsigned-byte 62) ty-b ty-c))
        (unless (and (>= ty-b 13) (logtest ty-b 1) (>= ty-c 13) (logtest ty-c 1))
          (return-from bt-get-post +bt-fallback+))
        (w-lit "{\"post\":{\"id\":")
        (w-int id)
        (w-lit ",\"body\":\"")
        (w-json-string-body (a-ref-64 cols 40) (ash (- ty-b 13) -1))
        (w-lit "\",\"created_at\":\"")
        (w-json-string-body (a-ref-64 cols 56) (ash (- ty-c 13) -1))
        (w-lit "\",\"author\":\"")))
    ;; the post's cell is not needed any more: the users cursor may move now
    (let ((r (%td-seek **cur-users** uid)))
      (declare (type fixnum r))
      (unless (= r 1)
        (setf **wp** start)
        (return-from bt-get-post (if (= r 0) +bt-missing+ +bt-fallback+))))
    (unless (cur-record **cur-users** 2) (setf **wp** start) (return-from bt-get-post +bt-fallback+))
    (let ((cols (+ **bt-mem** +bt-cols+)))
      (declare (type addr cols))
      (let ((ty (a-ref-64 cols 16)))
        (declare (type (unsigned-byte 62) ty))
        (unless (and (>= ty 13) (logtest ty 1)) (setf **wp** start) (return-from bt-get-post +bt-fallback+))
        (w-json-string-body (a-ref-64 cols 24) (ash (- ty 13) -1))))
    (let ((n (bt-count-likes id)))
      (declare (type fixnum n))
      (when (< n 0) (setf **wp** start) (return-from bt-get-post +bt-fallback+))
      (w-lit "\",\"like_count\":")
      (w-int n)
      (w-lit "}}"))
    +bt-ok+))

;;; ---- GET /feed -------------------------------------------------------------------------------
;;; The newest 20 posts by (created_at DESC, id DESC) are read off posts_created_at_id_idx, whose
;;; records already hold created_at and id. The post rows are then fetched in ascending id order
;;; (consecutive ids sit next to each other in the table, so each seek is a step along the leaf),
;;; then the authors, then the like counts in one walk of likes_post_id_idx. Every cursor holds one
;;; cell at a time, so each text field is copied into the text buffer before the cursor moves.

(defun bt-feed-rows ()
  "Fills the row scratch. Returns the number of rows, or -1 when SQL should answer instead."
  (fast
    (let ((n 0) (ci **cur-feed**) (cp **cur-posts**) (cu **cur-users**))
      (declare (type fixnum n) (type addr ci cp cu))
      (setf **tpos** 0)
      ;; 1. the index
      (let ((r (%td-first ci)))
        (declare (type fixnum r))
        (loop while (and (= r 1) (< n +bt-feed-rows+))
              do (unless (cur-record ci 2) (return-from bt-feed-rows -1))
                 (let ((row (bt-row n))
                       (id (col-int 1))
                       (at (col-text-copy 0)))
                   (declare (type addr row) (type fixnum id at))
                   (when (or (= id +bt-bad+) (< at 0)) (return-from bt-feed-rows -1))
                   (setf (a-ref-64 row +r-id+) id
                         (a-ref-32 row +r-created+) at
                         (a-ref-32 row (+ +r-created+ 4)) (col-text-len 0))
                   (incf n))
                 (setf r (%td-next ci)))
        (when (< r 0) (return-from bt-feed-rows -1)))
      ;; 2. ascending id order (normally the reverse of the index order)
      (let ((ord (+ **bt-mem** +bt-order+)))
        (declare (type addr ord))
        (dotimes (i n) (setf (a-ref-8 ord i) (- n 1 i)))
        (loop for i of-type fixnum from 1 below n
              do (let ((x (a-ref-8 ord i)) (j (1- i)))
                   (declare (type fixnum x j))
                   (loop while (and (>= j 0)
                                    (> (a-sref-64 (bt-row (a-ref-8 ord j)) +r-id+)
                                       (a-sref-64 (bt-row x) +r-id+)))
                         do (setf (a-ref-8 ord (1+ j)) (a-ref-8 ord j))
                            (decf j))
                   (setf (a-ref-8 ord (1+ j)) x)))
        (dotimes (k n)
          (let* ((row (bt-row (a-ref-8 ord k))))
            (declare (type addr row))
            (unless (= (%td-seek cp (a-sref-64 row +r-id+)) 1) (return-from bt-feed-rows -1))
            (unless (cur-record cp 3) (return-from bt-feed-rows -1))
            (let ((uid (col-int 1)) (at (col-text-copy 2)))
              (declare (type fixnum uid at))
              (when (or (= uid +bt-bad+) (< at 0)) (return-from bt-feed-rows -1))
              (setf (a-ref-64 row +r-uid+) uid
                    (a-ref-32 row +r-body+) at
                    (a-ref-32 row (+ +r-body+ 4)) (col-text-len 2)))))
        ;; 3. authors
        (dotimes (i n)
          (let ((row (bt-row i)))
            (declare (type addr row))
            (unless (= (%td-seek cu (a-sref-64 row +r-uid+)) 1) (return-from bt-feed-rows -1))
            (unless (cur-record cu 2) (return-from bt-feed-rows -1))
            (let ((at (col-text-copy 1)))
              (declare (type fixnum at))
              (when (< at 0) (return-from bt-feed-rows -1))
              (setf (a-ref-32 row +r-author+) at
                    (a-ref-32 row (+ +r-author+ 4)) (col-text-len 1)))))
        ;; 4. like counts
        (when (> n 0)
          (let ((lo (a-sref-64 (bt-row (a-ref-8 ord 0)) +r-id+))
                (hi (a-sref-64 (bt-row (a-ref-8 ord (1- n))) +r-id+))
                (cnt (+ **bt-mem** +bt-counts+)))
            (declare (type (signed-byte 62) lo hi) (type addr cnt))
            (cond ((<= 0 (- hi lo) +bt-span+)
                   (dotimes (i (1+ (- hi lo))) (setf (a-ref-32 cnt (* 4 i)) 0))
                   (unless (zerop (%td-count-likes **cur-likes** lo hi cnt)) (return-from bt-feed-rows -1))
                   (dotimes (i n)
                     (let ((row (bt-row i)))
                       (declare (type addr row))
                       (setf (a-ref-64 row +r-likes+)
                             (a-ref-32 cnt (* 4 (the (integer 0 512) (- (the (signed-byte 62) (a-sref-64 row +r-id+)) lo))))))))
                  (t
                   (dotimes (i n)
                     (let ((row (bt-row i)))
                       (declare (type addr row))
                       (let ((c (bt-count-likes (a-sref-64 row +r-id+))))
                         (declare (type fixnum c))
                         (when (< c 0) (return-from bt-feed-rows -1))
                         (setf (a-ref-64 row +r-likes+) c)))))))))
      n)))

(defun bt-feed ()
  "Writes {\"posts\":[...]}. +bt-ok+, or +bt-fallback+ with nothing written."
  (let ((n (bt-feed-rows)) (text (+ **bt-mem** +bt-text+)))
    (declare (type fixnum n) (type addr text))
    (when (< n 0) (return-from bt-feed +bt-fallback+))
    (w-lit "{\"posts\":[")
    (dotimes (i n)
      (let ((row (bt-row i)))
        (declare (type addr row))
        (when (> i 0) (w-byte (bc #\,)))
        (w-lit "{\"id\":")
        (w-int (a-sref-64 row +r-id+))
        (w-lit ",\"body\":\"")
        (w-json-string-body (+ text (a-ref-32 row +r-body+)) (a-ref-32 row (+ +r-body+ 4)))
        (w-lit "\",\"created_at\":\"")
        (w-json-string-body (+ text (a-ref-32 row +r-created+)) (a-ref-32 row (+ +r-created+ 4)))
        (w-lit "\",\"author\":\"")
        (w-json-string-body (+ text (a-ref-32 row +r-author+)) (a-ref-32 row (+ +r-author+ 4)))
        (w-lit "\",\"like_count\":")
        (w-int (a-ref-64 row +r-likes+))
        (w-byte (bc #\}))))
    (w-byte (bc #\]))
    (w-byte (bc #\}))
    +bt-ok+))
