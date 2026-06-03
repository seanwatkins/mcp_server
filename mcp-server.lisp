;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; Copyright (C) 2026 Sean Watkins <sean.watkins@gmail.com>
;;;;
;;;; mcp-server.lisp
;;;;
;;;; MCP (Model Context Protocol) filesystem server for Claude.ai web.
;;;; Implements the MCP Streamable HTTP transport with OAuth 2.0 + PKCE,
;;;; which Claude.ai requires for remote integrations.
;;;;
;;;; Tools exposed to Claude.ai:
;;;;   write_file(path, content)   — create/overwrite a file under MCP_ROOT
;;;;   read_file(path)             — read a file
;;;;   list_directory(path)        — list a directory
;;;;   eval_lisp(code)             — evaluate Common Lisp in the running image
;;;;   exec_command(command)       — run a shell command
;;;;   + any tools loaded from tools.lisp at startup
;;;;
;;;; Adding a tool at runtime (persists across restarts automatically):
;;;;   Call eval_lisp with a define-tool form:
;;;;
;;;;     (define-tool disk_usage
;;;;       "Show disk usage for a path"
;;;;       (jobj "type" "object"
;;;;             "properties" (jobj "path" (jobj "type" "string"
;;;;                                             "description" "Path to check"))
;;;;             "required" (list "path"))
;;;;       (let ((path (or (gethash "path" args) "/")))
;;;;         (values (uiop:run-program (list "du" "-sh" path) :output :string) nil)))
;;;;
;;;; Usage:
;;;;   1. Start server:
;;;;        MCP_SERVER_URL=https://xxx.trycloudflare.com sbcl --load mcp-server.lisp
;;;;   2. In a second terminal, start the HTTPS tunnel:
;;;;        ./tunnel
;;;;   3. Add the tunnel URL to Claude.ai Settings -> Connectors

;;; --- 1. Quicklisp ------------------------------------------------------------
(let ((ql-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-init) (load ql-init)))

(ql:quickload '(:hunchentoot :yason :ironclad :cl-base64 :cl-ppcre :uiop
                :bordeaux-threads :usocket) :silent t)

;;; --- 2. Configuration --------------------------------------------------------
(defparameter *port*
  (or (ignore-errors (parse-integer (uiop:getenv "MCP_PORT"))) 8765))

(defparameter *allowed-root*
  (namestring (uiop:ensure-directory-pathname
               (or (uiop:getenv "MCP_ROOT") "/share/projects/"))))

(defparameter *server-url*
  (string-right-trim "/" (or (uiop:getenv "MCP_SERVER_URL")
                             (format nil "http://localhost:~A" *port*))))

(defparameter *mcp-endpoint*
  (or (uiop:getenv "MCP_ENDPOINT") "/claude"))

;;; --- 3. Logging & MQTT -------------------------------------------------------
(defparameter *log-file*
  (or (uiop:getenv "LOG_FILE") "/share/projects/mcp-server/mcp-server.log"))

(defparameter *mqtt-host*
  (or (uiop:getenv "MQTT_HOST") "10.0.69.63"))

(defparameter *mqtt-port*
  (or (ignore-errors (parse-integer (uiop:getenv "MQTT_PORT"))) 1883))

(defparameter *mqtt-topic*
  (or (uiop:getenv "MQTT_TOPIC") "mcp-server/log"))

(defparameter *mqtt-status-topic*
  (or (uiop:getenv "MQTT_STATUS_TOPIC") "mcp-server/status"))

(defvar *mqtt-socket* nil)
(defvar *mqtt-stream* nil)
(defvar *log-lock* (bt:make-lock "log-lock"))
(defvar *start-time* (get-universal-time))

(defun %mqtt-bytes (s)
  (sb-ext:string-to-octets s :external-format :utf-8))

(defun %mqtt-enc-str (s)
  (let* ((b (%mqtt-bytes s)) (n (length b))
         (r (make-array (+ 2 n) :element-type '(unsigned-byte 8))))
    (setf (aref r 0) (ash n -8) (aref r 1) (logand n #xff))
    (replace r b :start1 2)
    r))

(defun %mqtt-varlen (n)
  (let (acc)
    (loop (let ((b (logand n #x7f)))
            (setf n (ash n -7))
            (push (if (> n 0) (logior b #x80) b) acc)
            (when (= n 0) (return))))
    (coerce (nreverse acc) '(vector (unsigned-byte 8)))))

(defun %mqtt-connect-pkt ()
  (let* ((vh #(0 4 77 81 84 84 4 2 0 60))
         (pl (%mqtt-enc-str "mcp-server"))
         (rl (%mqtt-varlen (+ (length vh) (length pl)))))
    (concatenate '(vector (unsigned-byte 8)) #(#x10) rl vh pl)))

(defun %mqtt-publish-pkt (topic msg)
  (let* ((tb (%mqtt-enc-str topic))
         (mb (%mqtt-bytes msg))
         (rl (%mqtt-varlen (+ (length tb) (length mb)))))
    (concatenate '(vector (unsigned-byte 8)) #(#x30) rl tb mb)))

(defun mqtt-connect ()
  (handler-case
      (progn
        (when *mqtt-socket*
          (ignore-errors (usocket:socket-close *mqtt-socket*)))
        (let* ((sock (usocket:socket-connect *mqtt-host* *mqtt-port*
                                             :element-type '(unsigned-byte 8)))
               (stream (usocket:socket-stream sock)))
          (write-sequence (%mqtt-connect-pkt) stream)
          (finish-output stream)
          (let ((buf (make-array 4 :element-type '(unsigned-byte 8))))
            (read-sequence buf stream))
          (setf *mqtt-socket* sock *mqtt-stream* stream)
          (format t "~&[MQTT] Connected to ~A:~A~%" *mqtt-host* *mqtt-port*)))
    (error (e)
      (format t "~&[MQTT] Connect failed: ~A~%" e)
      (setf *mqtt-socket* nil *mqtt-stream* nil))))

(defun mqtt-publish (topic message)
  (when *mqtt-stream*
    (handler-case
        (progn
          (write-sequence (%mqtt-publish-pkt topic message) *mqtt-stream*)
          (finish-output *mqtt-stream*))
      (error (e)
        (format t "~&[MQTT] Publish failed: ~A, reconnecting...~%" e)
        (ignore-errors (usocket:socket-close *mqtt-socket*))
        (setf *mqtt-socket* nil *mqtt-stream* nil)
        (mqtt-connect)))))

(defun log-timestamp ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D" y mo d h m s)))

(defun log-message (fmt &rest args)
  (let ((line (format nil "~A ~A" (log-timestamp) (apply #'format nil fmt args))))
    (bt:with-lock-held (*log-lock*)
      (format t "~&~A~%" line)
      (finish-output)
      (handler-case
          (with-open-file (f *log-file* :direction :output
                              :if-exists :append :if-does-not-exist :create)
            (write-line line f))
        (error (e) (format t "~&[LOG] File write failed: ~A~%" e)))
      (mqtt-publish *mqtt-topic* line))))

;;; --- 4. Utilities ------------------------------------------------------------
(defun random-token (&optional (len 40))
  (let ((chars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    (coerce (loop repeat len collect (char chars (random (length chars)))) 'string)))

(defun base64url-encode (bytes)
  (let ((b64 (cl-base64:usb8-array-to-base64-string bytes)))
    (string-right-trim "="
      (with-output-to-string (s)
        (loop for ch across b64
              do (write-char (case ch (#\+ #\-) (#\/ #\_) (t ch)) s))))))

(defun sha256-base64url (s)
  (let ((d (ironclad:make-digest :sha256)))
    (ironclad:update-digest d (ironclad:ascii-string-to-byte-array s))
    (base64url-encode (ironclad:produce-digest d))))

(defun html-escape (s)
  (cl-ppcre:regex-replace-all
   "<" (cl-ppcre:regex-replace-all
        ">" (cl-ppcre:regex-replace-all
             "\"" (cl-ppcre:regex-replace-all
                   "&" (or s "") "&amp;")
             "&quot;")
        "&gt;")
   "&lt;"))

;;; --- 5. Path safety ----------------------------------------------------------
(defun safe-path (relative)
  (when (cl-ppcre:scan "\\.\\." (or relative ""))
    (return-from safe-path nil))
  (let* ((dir (uiop:ensure-directory-pathname *allowed-root*))
         (abs (namestring (merge-pathnames (or relative "") dir))))
    (when (and (>= (length abs) (length *allowed-root*))
               (string= *allowed-root* (subseq abs 0 (length *allowed-root*))))
      abs)))

;;; --- 6. OAuth 2.0 state ------------------------------------------------------
(defvar *auth-codes*  (make-hash-table :test #'equal))
(defvar *auth-tokens* (make-hash-table :test #'equal))

(defun issue-code (redirect-uri code-challenge)
  (let ((code (random-token 32)))
    (setf (gethash code *auth-codes*)
          (list :redirect-uri redirect-uri :code-challenge code-challenge
                :issued (get-universal-time)))
    code))

(defun consume-code (code verifier)
  (let ((entry (gethash code *auth-codes*)))
    (unless entry (return-from consume-code nil))
    (when (> (- (get-universal-time) (getf entry :issued)) 60)
      (remhash code *auth-codes*)
      (return-from consume-code nil))
    (let ((challenge (getf entry :code-challenge)))
      (when (and challenge (not (string= challenge ""))
                 verifier  (not (string= verifier "")))
        (unless (string= challenge (sha256-base64url verifier))
          (return-from consume-code nil))))
    (remhash code *auth-codes*)
    t))

(defun issue-token ()
  (let ((token (random-token 48)))
    (setf (gethash token *auth-tokens*) t)
    (log-message "[AUTH] Token issued: ~A..." (subseq token 0 8))
    token))

(defun valid-token-p (token)
  (gethash (or token "") *auth-tokens*))

;;; --- 7. JSON helpers ---------------------------------------------------------
(defun jobj (&rest kv-pairs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv-pairs by #'cddr do (setf (gethash k h) v))
    h))

(defun json-encode (obj)
  (with-output-to-string (s) (yason:encode obj s)))

(defun json-parse (str)
  (ignore-errors (yason:parse str :object-as :hash-table)))

(defun format-uptime (seconds)
  (let* ((d (floor seconds 86400))
         (h (floor (mod seconds 86400) 3600))
         (m (floor (mod seconds 3600) 60))
         (s (mod seconds 60)))
    (if (> d 0)
        (format nil "~Dd ~2,'0Dh ~2,'0Dm ~2,'0Ds" d h m s)
        (format nil "~2,'0Dh ~2,'0Dm ~2,'0Ds" h m s))))

(defun start-status-thread ()
  (bt:make-thread
   (lambda ()
     (loop
       (when *mqtt-stream*
         (handler-case
             (let* ((uptime (- (get-universal-time) *start-time*))
                    (payload (json-encode
                              (jobj "timestamp" (log-timestamp)
                                    "uptime_s"  uptime
                                    "uptime"    (format-uptime uptime)
                                    "root"      *allowed-root*
                                    "port"      *port*
                                    "status"    "running"))))
               (mqtt-publish *mqtt-status-topic* payload))
           (error (e) (format t "~&[STATUS] thread error: ~A~%" e))))
       (sleep 1)))
   :name "mcp-status"))

;;; --- 8. MCP tool implementations ---------------------------------------------
(defun tool-write-file (args)
  (let* ((path    (gethash "path" args))
         (content (gethash "content" args)))
    (unless (and path content)
      (return-from tool-write-file (values "ERROR: missing path or content" t)))
    (let ((abs (safe-path path)))
      (unless abs
        (return-from tool-write-file (values "ERROR: path outside allowed root" t)))
      (handler-case
          (progn
            (ensure-directories-exist abs)
            (with-open-file (out abs :direction :output
                                :if-exists :supersede :if-does-not-exist :create)
              (write-string content out))
            (log-message "[WRITE] ~A (~A bytes)" path (length content))
            (values (format nil "Wrote ~A bytes to ~A" (length content) path) nil))
        (error (e) (values (format nil "ERROR: ~A" e) t))))))

(defun tool-read-file (args)
  (let* ((path (gethash "path" args)))
    (unless path
      (return-from tool-read-file (values "ERROR: missing path argument" t)))
    (let ((abs (safe-path path)))
      (unless abs
        (return-from tool-read-file (values "ERROR: path outside allowed root" t)))
      (unless (probe-file abs)
        (return-from tool-read-file (values (format nil "ERROR: not found: ~A" path) t)))
      (handler-case
          (let ((content (uiop:read-file-string abs)))
            (log-message "[READ] ~A (~A bytes)" path (length content))
            (values content nil))
        (error (e) (values (format nil "ERROR: ~A" e) t))))))

(defun tool-list-directory (args)
  (let* ((rel (or (gethash "path" args) ""))
         (abs (safe-path (if (string= rel "") "." rel))))
    (unless abs
      (return-from tool-list-directory (values "ERROR: path outside allowed root" t)))
    (unless (probe-file abs)
      (return-from tool-list-directory (values (format nil "ERROR: not found: ~A" rel) t)))
    (handler-case
        (let* ((dirs  (mapcar (lambda (d)
                                (format nil "~A/" (car (last (pathname-directory d)))))
                              (uiop:subdirectories abs)))
               (files (mapcar #'file-namestring (uiop:directory-files abs)))
               (all   (sort (append dirs files) #'string<)))
          (log-message "[LIST] ~A (~A entries)" rel (length all))
          (values (format nil "~{~A~^~%~}" all) nil))
      (error (e) (values (format nil "ERROR: ~A" e) t)))))

(defun tool-eval-lisp (args)
  (let ((code (gethash "code" args)))
    (unless code
      (return-from tool-eval-lisp (values "ERROR: missing code argument" t)))
    (log-message "[EVAL] ~A" (subseq code 0 (min 80 (length code))))
    (handler-case
        (let* ((forms  (let (acc)
                         (with-input-from-string (s code)
                           (loop for f = (read s nil :eof)
                                 until (eq f :eof) do (push f acc)))
                         (nreverse acc)))
               (result nil)
               (output (with-output-to-string (*standard-output*)
                         (dolist (form forms)
                           (setf result (multiple-value-list (eval form))))))
               (result-str (format nil "~{~S~^~%~}" result))
               (text (string-trim '(#\Newline)
                       (cond ((and (string/= output "") result)
                              (format nil "~A~%=> ~A" output result-str))
                             ((string/= output "") output)
                             (t (format nil "=> ~A" result-str))))))
          (log-message "[EVAL] => ~A" (subseq result-str 0 (min 60 (length result-str))))
          (values text nil))
      (error (e)
        (log-message "[EVAL] error: ~A" e)
        (values (format nil "ERROR: ~A" e) t)))))

(defparameter *exec-timeout* 30)
(defparameter *exec-max-bytes* (* 50 1024))

(defun tool-exec-command (args)
  (let ((cmd (gethash "command" args)))
    (unless cmd
      (return-from tool-exec-command (values "ERROR: missing command argument" t)))
    (log-message "[EXEC] ~A" cmd)
    (handler-case
        (let* ((proc (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                                         :output :stream :error :stream :wait nil))
               (out-stream (sb-ext:process-output proc))
               (err-stream (sb-ext:process-error  proc))
               (deadline   (+ (get-universal-time) *exec-timeout*))
               (buf        (make-array *exec-max-bytes* :element-type 'character
                                       :fill-pointer 0)))
          (loop
            (when (> (get-universal-time) deadline)
              (sb-ext:process-kill proc 9 :pid)
              (return-from tool-exec-command
                (values (format nil "ERROR: command timed out after ~As~%~A"
                                *exec-timeout* buf) t)))
            (let ((ch (read-char-no-hang out-stream nil :eof)))
              (cond ((eq ch :eof) (return))
                    (ch (when (< (fill-pointer buf) *exec-max-bytes*)
                          (vector-push ch buf)))
                    (t  (sleep 0.05)))))
          (let ((err-str (with-output-to-string (s)
                           (loop for ch = (read-char-no-hang err-stream nil nil)
                                 while ch do (write-char ch s)))))
            (sb-ext:process-wait proc)
            (let* ((exit-code (sb-ext:process-exit-code proc))
                   (output    (if (and (string/= err-str "") (string= buf ""))
                                  err-str
                                  (if (string/= err-str "")
                                      (format nil "~A~%--- stderr ---~%~A" buf err-str)
                                      (coerce buf 'string))))
                   (truncated (> (fill-pointer buf) (1- *exec-max-bytes*))))
              (log-message "[EXEC] exit=~A~A" exit-code (if truncated " (truncated)" ""))
              (values (if truncated
                          (format nil "~A~%[output truncated at ~AKB]"
                                  output (/ *exec-max-bytes* 1024))
                          output)
                      (/= exit-code 0)))))
      (error (e) (values (format nil "ERROR: ~A" e) t)))))

;;; --- 9. Tool registry --------------------------------------------------------
;;;
;;; Built-in tools are registered with register-tool (no persistence).
;;; User tools are added with define-tool, which also appends to tools.lisp.
;;; On startup, load-tools-file replays tools.lisp with *loading-tools* bound
;;; to T, which suppresses re-appending and prevents the file from growing.

(defvar *tool-registry* (make-hash-table :test #'equal)
  "Maps tool name string -> (list handler-fn schema description).")

(defparameter *tools-file*
  (or (uiop:getenv "TOOLS_FILE")
      "/share/projects/mcp-server/tools.lisp")
  "File where user-defined tools are persisted. Loaded at startup after built-ins.")

(defvar *loading-tools* nil
  "Bound to T while tools.lisp is being loaded. Suppresses persist-tool-form
   so that loading the file does not re-append every form to it.")

(defun register-tool (name description input-schema handler-fn)
  "Register NAME in *tool-registry*. Does not persist -- use define-tool for that."
  (setf (gethash name *tool-registry*)
        (list handler-fn input-schema description))
  (log-message "[TOOL] Registered: ~A" name)
  name)

(defun persist-tool-form (form)
  "Append FORM as readable Lisp to *tools-file*."
  (handler-case
      (with-open-file (out *tools-file*
                           :direction :output
                           :if-exists :append
                           :if-does-not-exist :create)
        (terpri out)
        (write form :stream out :pretty t :readably t)
        (terpri out))
    (error (e)
      (log-message "[TOOL] WARNING: could not persist to ~A: ~A" *tools-file* e))))

(defmacro define-tool (name description input-schema &body handler-body)
  "Register a tool and persist it to *tools-file* so it survives restarts.
   NAME         -- unquoted symbol, becomes the MCP tool name string (lowercased)
   DESCRIPTION  -- string shown to Claude
   INPUT-SCHEMA -- form evaluating to a jobj
   HANDLER-BODY -- body of (lambda (args) ...) where ARGS is the arguments hash-table

   When called during load-tools-file (*loading-tools* is T), the tool is
   registered but NOT re-appended to the file."
  (let ((name-str (string-downcase (symbol-name name)))
        (form     `(define-tool ,name ,description ,input-schema ,@handler-body)))
    `(progn
       (register-tool ,name-str
                      ,description
                      ,input-schema
                      (lambda (args) (declare (ignorable args)) ,@handler-body))
       (unless *loading-tools*
         (persist-tool-form ',form)
         (log-message "[TOOL] Persisted: ~A -> ~A" ,name-str *tools-file*))
       ,name-str)))

(defun tools-list ()
  "Return sorted list of tool jobjs for tools/list response."
  (let (result)
    (maphash (lambda (name entry)
               (destructuring-bind (fn schema description) entry
                 (declare (ignore fn))
                 (push (jobj "name" name "description" description "inputSchema" schema)
                       result)))
             *tool-registry*)
    (sort result #'string< :key (lambda (h) (gethash "name" h)))))

(defun load-tools-file ()
  "Load *tools-file* if it exists, registering any define-tool forms inside.
   Binds *loading-tools* to T during the load so define-tool does not
   re-append each form to the file."
  (if (probe-file *tools-file*)
      (handler-case
          (let ((*loading-tools* t))
            (load *tools-file*)
            (log-message "[TOOL] Loaded tools from ~A (~A total)"
                         *tools-file* (hash-table-count *tool-registry*)))
        (error (e)
          (log-message "[TOOL] ERROR loading ~A: ~A" *tools-file* e)))
      (log-message "[TOOL] No tools.lisp at ~A (created on first define-tool)"
                   *tools-file*)))

;;; Register built-in tools (always present, never written to tools.lisp)
(register-tool
 "write_file"
 (format nil "Write content to a file under ~A" *allowed-root*)
 (jobj "type" "object"
       "properties" (jobj "path"    (jobj "type" "string"
                                          "description" "Relative path (e.g. bank-csv/foo.lisp)")
                          "content" (jobj "type" "string"
                                          "description" "Full file content to write"))
       "required" (list "path" "content"))
 #'tool-write-file)

(register-tool
 "read_file"
 (format nil "Read a file from ~A" *allowed-root*)
 (jobj "type" "object"
       "properties" (jobj "path" (jobj "type" "string" "description" "Relative path"))
       "required" (list "path"))
 #'tool-read-file)

(register-tool
 "list_directory"
 (format nil "List files/dirs under ~A" *allowed-root*)
 (jobj "type" "object"
       "properties" (jobj "path" (jobj "type" "string"
                                       "description" "Relative path (default: root)"))
       "required" (list))
 #'tool-list-directory)

(register-tool
 "eval_lisp"
 "Evaluate Common Lisp code in the running server image. Supports multiple top-level forms. Returns printed output and return values."
 (jobj "type" "object"
       "properties" (jobj "code" (jobj "type" "string"
                                       "description" "One or more Common Lisp forms to evaluate"))
       "required" (list "code"))
 #'tool-eval-lisp)

(register-tool
 "exec_command"
 "Execute a shell command on the server. Returns stdout/stderr. Timeout 30s, max 50KB output."
 (jobj "type" "object"
       "properties" (jobj "command" (jobj "type" "string"
                                          "description" "Shell command to execute"))
       "required" (list "command"))
 #'tool-exec-command)

;;; --- 10. MCP JSON-RPC dispatcher ---------------------------------------------
(defun mcp-ok (id result)
  (json-encode (jobj "jsonrpc" "2.0" "id" id "result" result)))

(defun mcp-err (id code message)
  (json-encode (jobj "jsonrpc" "2.0" "id" id
                     "error" (jobj "code" code "message" message))))

(defun dispatch (req)
  (let ((method (gethash "method" req))
        (id     (gethash "id" req))
        (params (or (gethash "params" req) (make-hash-table :test #'equal))))
    (cond
      ((string= method "initialize")
       (mcp-ok id (jobj "protocolVersion" "2024-11-05"
                        "capabilities"    (jobj "tools" (jobj))
                        "serverInfo"      (jobj "name" "mcp-filesystem" "version" "1.0"))))
      ((and (null id) (uiop:string-prefix-p "notifications/" method)) nil)
      ((string= method "tools/list")
       (mcp-ok id (jobj "tools" (tools-list))))
      ((string= method "tools/call")
       (let* ((name  (gethash "name" params))
              (args  (or (gethash "arguments" params) (make-hash-table :test #'equal)))
              (entry (gethash (or name "") *tool-registry*)))
         (if entry
             (multiple-value-bind (text is-err) (funcall (first entry) args)
               (let ((result (jobj "content" (list (jobj "type" "text"
                                                         "text" (or text ""))))))
                 (when is-err (setf (gethash "isError" result) t))
                 (mcp-ok id result)))
             (mcp-ok id (let ((r (jobj "content"
                                       (list (jobj "type" "text"
                                                   "text" (format nil "Unknown tool: ~A" name))))))
                          (setf (gethash "isError" r) t) r)))))
      (t (mcp-err id -32601 (format nil "Method not found: ~A" method))))))

;;; --- 11. HTTP handlers -------------------------------------------------------
(defun set-cors ()
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin")  "https://claude.ai")
  (setf (hunchentoot:header-out "Access-Control-Allow-Headers")
        "Content-Type, Authorization, Mcp-Session-Id")
  (setf (hunchentoot:header-out "Access-Control-Allow-Methods") "GET, POST, OPTIONS"))

(defun auth-bearer ()
  (let ((h (hunchentoot:header-in* "authorization")))
    (when (and h (> (length h) 7) (string= "Bearer " (subseq h 0 7)))
      (subseq h 7))))

(hunchentoot:define-easy-handler (handle-mcp :uri *mcp-endpoint*) ()
  (set-cors)
  (setf (hunchentoot:content-type*) "application/json")
  (when (eq (hunchentoot:request-method*) :options)
    (setf (hunchentoot:return-code*) 204)
    (return-from handle-mcp ""))
  (unless (valid-token-p (auth-bearer))
    (setf (hunchentoot:return-code*) 401)
    (return-from handle-mcp (json-encode (jobj "error" "unauthorized"))))
  (let* ((raw  (hunchentoot:raw-post-data :force-text t))
         (body (when (and raw (not (string= (string-trim " " raw) "")))
                 (json-parse raw))))
    (unless body
      (setf (hunchentoot:return-code*) 400)
      (return-from handle-mcp (json-encode (jobj "error" "invalid JSON"))))
    (if (listp body)
        (json-encode (remove nil (mapcar #'dispatch body)))
        (or (dispatch body) ""))))

(hunchentoot:define-easy-handler
    (handle-oauth-discovery :uri "/.well-known/oauth-authorization-server") ()
  (setf (hunchentoot:content-type*) "application/json")
  (json-encode
   (jobj "issuer"                                *server-url*
         "authorization_endpoint"                (format nil "~A/authorize" *server-url*)
         "token_endpoint"                        (format nil "~A/token" *server-url*)
         "registration_endpoint"                 (format nil "~A/register" *server-url*)
         "response_types_supported"              (list "code")
         "grant_types_supported"                 (list "authorization_code")
         "code_challenge_methods_supported"      (list "S256")
         "token_endpoint_auth_methods_supported" (list "none"))))

(hunchentoot:define-easy-handler (handle-register :uri "/register") ()
  (set-cors)
  (setf (hunchentoot:content-type*) "application/json")
  (when (eq (hunchentoot:request-method*) :options)
    (setf (hunchentoot:return-code*) 204)
    (return-from handle-register ""))
  (unless (eq (hunchentoot:request-method*) :post)
    (setf (hunchentoot:return-code*) 405)
    (return-from handle-register ""))
  (let* ((body      (json-parse (or (hunchentoot:raw-post-data :force-text t) "{}")))
         (redirects (when body (gethash "redirect_uris" body)))
         (client-id (random-token 16)))
    (log-message "[AUTH] Client registered: ~A" client-id)
    (json-encode
     (jobj "client_id"                  client-id
           "client_id_issued_at"        (get-universal-time)
           "token_endpoint_auth_method" "none"
           "grant_types"                (list "authorization_code")
           "response_types"             (list "code")
           "redirect_uris"              (or redirects (list))))))

(hunchentoot:define-easy-handler (handle-authorize :uri "/authorize") ()
  (if (eq (hunchentoot:request-method*) :post)
      (let* ((redirect-uri (hunchentoot:post-parameter "redirect_uri"))
             (state        (hunchentoot:post-parameter "state"))
             (challenge    (hunchentoot:post-parameter "code_challenge"))
             (code         (issue-code redirect-uri challenge))
             (sep          (if (find #\? redirect-uri :test #'char=) "&" "?"))
             (location     (format nil "~A~Acode=~A~A" redirect-uri sep code
                                   (if (and state (not (string= state "")))
                                       (format nil "&state=~A" state) ""))))
        (hunchentoot:redirect location))
      (let ((redirect-uri (hunchentoot:get-parameter "redirect_uri"))
            (state        (hunchentoot:get-parameter "state"))
            (challenge    (hunchentoot:get-parameter "code_challenge")))
        (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
        (format nil "<!DOCTYPE html>
<html><head><title>MCP Authorization</title>
<style>body{font-family:sans-serif;max-width:500px;margin:60px auto;padding:0 20px}
button{background:#7c3aed;color:#fff;border:none;padding:12px 28px;font-size:16px;
border-radius:6px;cursor:pointer}button:hover{background:#6d28d9}
code{background:#f3f4f6;padding:2px 6px;border-radius:3px}</style></head>
<body><h2>MCP Filesystem Server</h2>
<p>Claude.ai is requesting access to write and read files under:</p>
<p><code>~A</code></p>
<form method=\"post\" action=\"/authorize\">
  <input type=\"hidden\" name=\"redirect_uri\" value=\"~A\">
  <input type=\"hidden\" name=\"state\" value=\"~A\">
  <input type=\"hidden\" name=\"code_challenge\" value=\"~A\">
  <button type=\"submit\">Authorize Claude.ai</button>
</form></body></html>"
                (html-escape *allowed-root*)
                (html-escape (or redirect-uri ""))
                (html-escape (or state ""))
                (html-escape (or challenge ""))))))

(hunchentoot:define-easy-handler (handle-token :uri "/token") ()
  (setf (hunchentoot:content-type*) "application/json")
  (let* ((code     (hunchentoot:post-parameter "code"))
         (verifier (hunchentoot:post-parameter "code_verifier")))
    (if (consume-code code verifier)
        (json-encode (jobj "access_token" (issue-token) "token_type" "bearer"))
        (progn (setf (hunchentoot:return-code*) 400)
               (json-encode (jobj "error" "invalid_grant"))))))

;;; --- 12. Entry point ---------------------------------------------------------
(defclass mcp-acceptor (hunchentoot:easy-acceptor) ())

(defmethod hunchentoot:acceptor-log-message ((acceptor mcp-acceptor) log-level fmt &rest args)
  (log-message "[~A] ~A" (string-upcase (symbol-name log-level))
               (apply #'format nil fmt args)))

(defun main ()
  (mqtt-connect)
  (start-status-thread)
  (log-message "MCP Filesystem Server starting")
  (log-message "  Root       : ~A" *allowed-root*)
  (log-message "  Port       : ~A" *port*)
  (log-message "  URL        : ~A" *server-url*)
  (log-message "  Tools file : ~A" *tools-file*)
  (load-tools-file)
  (log-message "  Tools      : ~A registered" (hash-table-count *tool-registry*))
  (let ((acceptor (make-instance 'mcp-acceptor
                                 :port *port*
                                 :access-log-destination nil
                                 :message-log-destination nil)))
    (hunchentoot:start acceptor)
    (log-message "[INFO] Server running - add ~A to Claude.ai Settings -> Connectors"
                 *server-url*)
    (handler-case
        (loop (sleep 3600))
      (#+sbcl sb-sys:interactive-interrupt ()
        (log-message "[INFO] Shutting down...")
        (hunchentoot:stop acceptor)))))

(main)
