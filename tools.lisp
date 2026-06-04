(define-tool server_info
  "Returns basic info about the MCP server: uptime, tool count, hostname."
  (jobj "type" "object" "properties" (jobj) "required" (list))
  (let ((uptime (- (get-universal-time) *start-time*)))
    (values (format nil "Uptime: ~A~%Tools: ~A~%Host: ~A"
                    (format-uptime uptime)
                    (hash-table-count *tool-registry*)
                    (uiop:run-program "hostname" :output :string))
            nil)))

(define-tool reverse_string
  "Reverses a string and returns it."
  (jobj "type" "object"
        "properties" (jobj "input" (jobj "type" "string"
                                         "description" "The string to reverse"))
        "required" (list "input"))
  (let ((input (gethash "input" args)))
    (if input
        (values (reverse input) nil)
        (values "ERROR: missing input" t))))

(define-tool grafana
    "Make a Grafana REST API call. method=GET/POST/PUT/DELETE, path=/api/..., body=JSON string (optional)."
    (jobj "type" "object" "properties"
          (jobj "method" (jobj "type" "string" "description" "HTTP method: GET POST PUT DELETE")
                "path"   (jobj "type" "string" "description" "API path e.g. /api/dashboards/uid/xxx")
                "body"   (jobj "type" "string" "description" "JSON body (for POST/PUT)"))
          "required" (list "method" "path"))
  (let ((grafana-url  (uiop:getenv "GRAFANA_URL"))
        (grafana-user (or (uiop:getenv "GRAFANA_USER") "admin"))
        (grafana-pass (or (uiop:getenv "GRAFANA_PASS") "")))
    (unless grafana-url
      (return-from grafana (values "ERROR: GRAFANA_URL env var not set" t)))
    (let ((method (string-upcase (or (gethash "method" args) "GET")))
          (path   (gethash "path" args))
          (body   (gethash "body" args)))
      (handler-case
          (let* ((url  (format nil "~A~A" grafana-url path))
                 (auth (cl-base64:string-to-base64-string
                        (format nil "~A:~A" grafana-user grafana-pass)))
                 (hdrs (list (cons "Authorization" (format nil "Basic ~A" auth))
                             (cons "Content-Type" "application/json")))
                 (resp (cond ((string= method "GET")    (dexador:get    url :headers hdrs))
                             ((string= method "POST")   (dexador:post   url :headers hdrs :content (or body "{}")))
                             ((string= method "PUT")    (dexador:put    url :headers hdrs :content (or body "{}")))
                             ((string= method "DELETE") (dexador:delete url :headers hdrs))
                             (t (error "Unknown method ~A" method)))))
            (values resp nil))
        (error (e) (values (format nil "ERROR: ~A" e) t))))))

(DEFINE-TOOL PIG_LATIN
    "Converts an English text string into Pig Latin. Each word is transformed: words starting with a vowel get 'yay' appended; words starting with consonants move leading consonants to the end and add 'ay'."
    (JOBJ "type" "object" "properties"
          (JOBJ "text"
                (JOBJ "type" "string" "description"
                      "The English text to convert to Pig Latin"))
          "required" (LIST "text"))
  (LET ((TEXT (GETHASH "text" ARGS)))
    (IF TEXT
        (VALUES (PIG-LATIN-SENTENCE TEXT) NIL)
        (VALUES "ERROR: missing text" T))))
