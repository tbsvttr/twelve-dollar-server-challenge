;;;; The database layer: one connection, prepared statements kept for the life of the process.
;;;; Every function reads or writes live rows and, on success, leaves the JSON body in the arena.
(in-package #:feed)

(declaim (optimize (speed 3) (safety 0) (debug 0)))

(sb-ext:defglobal **db** 0)
(sb-ext:defglobal **st-post** 0)
(sb-ext:defglobal **st-feed** 0)
(sb-ext:defglobal **st-insert-post** 0)
(sb-ext:defglobal **st-insert-like** 0)
(sb-ext:defglobal **st-exists** 0)
(sb-ext:defglobal **st-health** 0)
(sb-ext:defglobal **st-begin** 0)
(sb-ext:defglobal **st-commit** 0)
(sb-ext:defglobal **st-rollback** 0)
(sb-ext:defglobal **in-txn** nil)       ; a group-commit transaction is open
(sb-ext:defglobal **wrote** nil)        ; the request being served wrote rows
(declaim (type addr **db** **st-post** **st-feed** **st-insert-post** **st-insert-like** **st-exists** **st-health**
               **st-begin** **st-commit** **st-rollback**))

(sb-ext:defglobal **broken** nil)       ; SQLite ended the pass's transaction itself (a failed write)

(defconstant +db-ok+ 0)
(defconstant +db-missing+ 1)
(defconstant +db-error+ 2)

(defun sap-string (sap &optional (limit 4096))
  (let ((chars '()))
    (dotimes (i limit)
      (let ((b (ref sap i)))
        (when (zerop b) (return))
        (push (code-char b) chars)))
    (coerce (nreverse chars) 'string)))

(defparameter *post-select*
  "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count FROM posts p JOIN users u ON u.id = p.user_id")

(defun db-open (path)
  "Opens PATH and prepares every statement; signals an error with SQLite's message on failure."
  (let ((err (foreign-alloc 1024)))
    (setf (a-ref-8 err 0) 0)
    (let ((db (%shim-open path err 1024)))
      (when (zerop (addr-id db)) (error "cannot open database: ~A" (sap-string err)))
      (setf **db** db)
      (flet ((prep (sql)
               (let ((st (%shim-prepare db sql err 1024)))
                 (when (zerop (addr-id st)) (error "~A (~A)" (sap-string err) sql))
                 st)))
        (setf **st-post** (prep (concatenate 'string *post-select* " WHERE p.id = ?"))
              **st-feed** (prep (concatenate 'string *post-select* " ORDER BY p.created_at DESC, p.id DESC LIMIT 20"))
              **st-insert-post** (prep "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at")
              **st-insert-like** (prep "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING")
              **st-exists** (prep "SELECT 1 FROM posts WHERE id = ?")
              **st-health** (prep "SELECT 1")
              **st-begin** (prep "BEGIN")
              **st-commit** (prep "COMMIT")
              **st-rollback** (prep "ROLLBACK"))))
    (if (or (sb-ext:posix-getenv "NO_BTREE") (not (bt-open err)))
        (format *error-output* "B-tree reads off: ~A~%"
                (if (sb-ext:posix-getenv "NO_BTREE") "NO_BTREE set" (sap-string err)))
        (format *error-output* "B-tree reads on (schema verified)~%"))
    (%free err)
    t))

;;; ---- group commit: one transaction per loop pass ---------------------------------------------
;;; The first write of a pass opens it; the loop commits once, before any write response is sent.

(defun db-ensure-txn ()
  "T when a transaction is open (opening one if needed). With the B-tree path on, the first request
of a pass that touches the database, read or write, opens it and the cursors with it."
  (cond (**broken** nil)
        (**in-txn** t)
        (t (let ((rc (%step **st-begin**)))
             (%reset **st-begin**)
             (when (= rc +sqlite-done+)
               (cond ((not **bt-on**) (setf **in-txn** t))
                     ((zerop (%td-bt-open-cursors)) (setf **in-txn** t))
                     (t (%step **st-rollback**) (%reset **st-rollback**))))
             **in-txn**))))

(defun db-check-broken ()
  "After a failed write: SQLite may have rolled the transaction back itself; then the pass is lost."
  (when (and **in-txn** (zerop (%td-in-txn)))
    (when **bt-on** (%td-bt-close-cursors))
    (setf **broken** t)))

(defun db-commit ()
  (when **bt-on** (%td-bt-close-cursors))
  (let ((rc (%step **st-commit**)) (ok (not **broken**)))
    (%reset **st-commit**)
    (setf **in-txn** nil **broken** nil)
    (and ok (= rc +sqlite-done+))))

(defun db-rollback ()
  (when **bt-on** (%td-bt-close-cursors))
  (%step **st-rollback**)
  (%reset **st-rollback**)
  (setf **in-txn** nil **broken** nil)
  t)

(defun w-column-string (st col)
  (declare (type addr st) (type fixnum col))
  (let ((p (%column-text st col)) (n (%column-bytes st col)))
    (w-json-string-body p n)))

(defun w-post-row (st)
  "The statement's current row as a post object."
  (declare (type addr st))
  (w-lit "{\"id\":")
  (w-int (%column-int64 st 0))
  (w-lit ",\"body\":\"")
  (w-column-string st 1)
  (w-lit "\",\"created_at\":\"")
  (w-column-string st 2)
  (w-lit "\",\"author\":\"")
  (w-column-string st 3)
  (w-lit "\",\"like_count\":")
  (w-int (%column-int64 st 4))
  (w-byte (bc #\})))

(defun db-get-post-sql (id)
  (declare (type fixnum id))
  (let ((st **st-post**))
    (%bind-int64 st 1 id)
    (let ((rc (%step st)))
      (cond ((= rc +sqlite-row+)
             (w-lit "{\"post\":")
             (w-post-row st)
             (w-byte (bc #\}))
             (%reset st)
             +db-ok+)
            ((= rc +sqlite-done+) (%reset st) +db-missing+)
            (t (%reset st) +db-error+)))))

(defun db-get-post (id)
  "B-tree cursors when the startup check passed; the prepared query otherwise, and for any row the
cursor decoders do not recognise."
  (declare (type fixnum id))
  (if (and **bt-on** (db-ensure-txn))
      (let ((r (bt-get-post id)))
        (cond ((= r +bt-ok+) +db-ok+)
              ((= r +bt-missing+) +db-missing+)
              (t (db-get-post-sql id))))
      (db-get-post-sql id)))

(defun db-feed ()
  "Every GET /feed reads its rows live (rule 5: no response or result caching)."
  (if (and **bt-on** (db-ensure-txn) (= (bt-feed) +bt-ok+))
      +db-ok+
      (db-feed-sql)))

(defun db-feed-sql ()
  (let ((st **st-feed**) (first t))
    (w-lit "{\"posts\":[")
    (loop
      (let ((rc (%step st)))
        (cond ((= rc +sqlite-row+)
               (if first (setf first nil) (w-byte (bc #\,)))
               (w-post-row st))
              ((= rc +sqlite-done+) (return))
              (t (%reset st) (return-from db-feed-sql +db-error+)))))
    (%reset st)
    (w-byte (bc #\]))
    (w-byte (bc #\}))
    +db-ok+))

(defun db-post-exists (id)
  (declare (type fixnum id))
  (when (and **bt-on** (db-ensure-txn))
    (let ((r (bt-post-exists id)))
      (cond ((= r +bt-ok+) (return-from db-post-exists +db-ok+))
            ((= r +bt-missing+) (return-from db-post-exists +db-missing+)))))
  (let ((st **st-exists**))
    (%bind-int64 st 1 id)
    (let ((rc (%step st)))
      (%reset st)
      (cond ((= rc +sqlite-row+) +db-ok+)
            ((= rc +sqlite-done+) +db-missing+)
            (t +db-error+)))))

(defun db-like (user-id post-id)
  "Returns +db-ok+ with **wp** untouched; the caller reads (db-like-new-p)."
  (declare (type fixnum user-id post-id))
  (unless (db-ensure-txn) (return-from db-like +db-error+))
  (setf **wrote** t)
  (let ((st **st-insert-like**))
    (%bind-int64 st 1 user-id)
    (%bind-int64 st 2 post-id)
    (let ((rc (%step st)))
      (let ((changed (%changes **db**)))
        (%reset st)
        (cond ((/= rc +sqlite-done+) (db-check-broken) +db-error+)
              ((> changed 0) 1)      ; new like
              (t 0))))))             ; already liked

(defun db-insert-post (user-id body n)
  "Inserts the post and writes the 201 body. The commit happens when the statement finishes, so the
body is only kept when that last step reports DONE."
  (declare (type fixnum user-id n) (type addr body))
  (unless (db-ensure-txn) (return-from db-insert-post +db-error+))
  (setf **wrote** t)
  (let ((st **st-insert-post**) (start **wp**))
    (%bind-int64 st 1 user-id)
    (%bind-text st 2 body n 0)
    (let ((rc (%step st)))
      (cond ((= rc +sqlite-row+)
             (w-lit "{\"post\":{\"id\":")
             (w-int (%column-int64 st 0))
             (w-lit ",\"body\":\"")
             (w-json-string-body body n)
             (w-lit "\",\"created_at\":\"")
             (w-column-string st 1)
             (w-lit "\",\"author\":\"")
             (w-sap (a+ **jwt-buf** **username-start**) (- **username-end** **username-start**))
             (w-lit "\",\"like_count\":0}}")
             (let ((rc2 (%step st)))
               (%reset st)
               (cond ((= rc2 +sqlite-done+) +db-ok+)
                     (t (setf **wp** start) (db-check-broken) +db-error+))))
            (t (%reset st) (db-check-broken) +db-error+)))))

(defun db-health ()
  "Writes the health body. Returns +db-ok+, or +db-error+ with the degraded body written."
  (let ((st **st-health**))
    (let ((rc (%step st)))
      (%reset st)
      (cond ((= rc +sqlite-row+) +db-ok+)
            (t
             (let ((msg (%errmsg **db**)))
               (w-lit "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"")
               (let ((n 0)) (loop while (and (< n 1000) (/= (ref msg n) 0)) do (incf n))
                 (w-json-string-body msg n))
               (w-lit "\"}"))
             +db-error+)))))
