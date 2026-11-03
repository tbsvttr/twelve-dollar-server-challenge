;;;; Loaded by build.sh: loads shim.so, compiles src/*.lisp in order, saves bin/server.
;;;; Core only: no Quicklisp, no contribs.
(defvar *root* (sb-ext:posix-getenv "BUILD_DIR"))
(defvar *so* (sb-ext:posix-getenv "SHIM_SO"))
(when (sb-ext:posix-getenv "TD_COUNT") (pushnew :td-count *features*))

(sb-alien:load-shared-object *so*)      ; absolute path: the saved core re-opens it from here

(defparameter *files* '("package" "ffi" "tune" "json" "jwt" "http" "btree" "db" "routes" "server"))

(ensure-directories-exist (concatenate 'string *root* "/build/fasl/"))

(dolist (f *files*)
  (let ((src (format nil "~A/src/~A.lisp" *root* f))
        (out (format nil "~A/build/fasl/~A.fasl" *root* f)))
    (multiple-value-bind (fasl warnings-p failure-p)
        (let ((*compile-verbose* nil))
          (compile-file src :output-file out))
      (declare (ignore warnings-p))
      (when (or (null fasl) failure-p)
        (format *error-output* "~&BUILD FAILED in ~A~%" src)
        (sb-ext:exit :code 1 :abort t))
      (load fasl))))

(sb-ext:save-lisp-and-die (format nil "~A/bin/server" *root*)
                          :executable t
                          :save-runtime-options t
                          :toplevel (symbol-function (find-symbol "MAIN" "FEED")))
