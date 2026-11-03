;;;; Package and the few types and macros every file shares.
;;;; Foreign memory is addressed by plain integers (type ADDR), never by SAP objects: a SAP held in
;;;; a global or passed to a full call is heap-allocated, an integer is not. That is what keeps
;;;; the request path from consing.
(defpackage #:feed
  (:use #:cl)
  (:export #:main))

(in-package #:feed)

(deftype addr () '(unsigned-byte 62))
(deftype u8 () '(unsigned-byte 8))
(deftype u32 () '(unsigned-byte 32))
(deftype u64 () '(unsigned-byte 64))
(deftype index () '(integer 0 #.(ash 1 40)))
(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defmacro fast (&body body)
  "Hot-path code: no checks, no debug info."
  `(locally (declare (optimize (speed 3) (safety 0) (debug 0))) ,@body))

;;; Reads and writes of foreign memory at ADDR+OFFSET. All are SETF-able (the macro expands first).
(defmacro a-ref-8 (a o) `(sb-sys:sap-ref-8 (sb-sys:int-sap ,a) ,o))
(defmacro a-ref-16 (a o) `(sb-sys:sap-ref-16 (sb-sys:int-sap ,a) ,o))
(defmacro a-ref-32 (a o) `(sb-sys:sap-ref-32 (sb-sys:int-sap ,a) ,o))
(defmacro a-ref-64 (a o) `(sb-sys:sap-ref-64 (sb-sys:int-sap ,a) ,o))
(defmacro a-sref-32 (a o) `(sb-sys:signed-sap-ref-32 (sb-sys:int-sap ,a) ,o))
(defmacro a-sref-64 (a o) `(sb-sys:signed-sap-ref-64 (sb-sys:int-sap ,a) ,o))
(defmacro ref (a i) `(a-ref-8 ,a ,i))
(defmacro a+ (a o) `(the addr (+ (the addr ,a) (the fixnum ,o))))
(defmacro addr-id (a) a)
(defmacro bc (ch) (char-code ch))

;;; Helpers used while macros expand (compile time) as well as at run time.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun crlf () (coerce (list #\Return #\Linefeed) 'string))

  (defun octets (&rest parts)
    "Concatenate strings (ASCII/Latin-1), octet vectors and single bytes into one octet vector."
    (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
      (dolist (p parts)
        (etypecase p
          (string (loop for c across p do (vector-push-extend (char-code c) out)))
          (vector (loop for b across p do (vector-push-extend b out)))
          (integer (vector-push-extend p out))))
      (coerce out '(simple-array (unsigned-byte 8) (*))))))
