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

(DEFINE-TOOL GRAFANA
    "Make a Grafana REST API call. method=GET/POST/PUT/DELETE, path=/api/..., body=JSON string (optional)."
    (JOBJ "type" "object" "properties"
          (JOBJ "method"
                (JOBJ "type" "string" "description"
                      "HTTP method: GET POST PUT DELETE")
                "path"
                (JOBJ "type" "string" "description"
                      "API path e.g. /api/dashboards/uid/xxx")
                "body"
                (JOBJ "type" "string" "description"
                      "JSON body (for POST/PUT)"))
          "required" (LIST "method" "path"))
  (LET ((METHOD (STRING-UPCASE (OR (GETHASH "method" ARGS) "GET")))
        (PATH (GETHASH "path" ARGS))
        (BODY (GETHASH "body" ARGS)))
    (UNLESS (AND (BOUNDP '*GRAFANA-URL*) *GRAFANA-URL*)
      (RETURN-FROM NIL (VALUES "ERROR: *grafana-url* not set" T)))
    (HANDLER-CASE
     (LET* ((URL (FORMAT NIL "~A~A" *GRAFANA-URL* PATH))
            (HDRS
             `(("Authorization" . ,(GRAFANA-AUTH))
               ("Content-Type" . "application/json")))
            (RESP
             (COND ((STRING= METHOD "GET") (DEXADOR:GET URL :HEADERS HDRS))
                   ((STRING= METHOD "POST")
                    (DEXADOR:POST URL :HEADERS HDRS :CONTENT (OR BODY "{}")))
                   ((STRING= METHOD "PUT")
                    (DEXADOR:PUT URL :HEADERS HDRS :CONTENT (OR BODY "{}")))
                   ((STRING= METHOD "DELETE")
                    (DEXADOR:DELETE URL :HEADERS HDRS))
                   (T (ERROR "Unknown method ~A" METHOD)))))
       (VALUES RESP NIL))
     (ERROR (E) (VALUES (FORMAT NIL "ERROR: ~A" E) T)))))
