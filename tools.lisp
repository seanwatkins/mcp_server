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


(defun to-pig-latin (word)
  (let* ((w (string-downcase word))
         (vowels aeiou)
         (starts-vowel (find (char w 0) vowels)))
    (if starts-vowel
        (concatenate 'string w yay)
        (let ((i (loop for i from 0 below (length w)
                       when (find (char w i) vowels)
                       return i)))
          (if i
              (concatenate 'string (subseq w i) (subseq w 0 i) ay)
              (concatenate 'string w ay))))))

(defun pig-latin-sentence (text)
  (let ((words (uiop:split-string text :separator " ")))
    (format nil "~{~A~^ ~}" (mapcar #'to-pig-latin words))))

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

;; Helper functions must come before the tool definition - patch them in here
;; (define-tool pig_latin above calls these)



;;; --- Home Assistant LED Tools -------------------------------------------

(define-tool LED_ON
  "Turn on the Home Assistant LED light (light.testmcu_my_udp_led)."
  (jobj "type" "object" "properties" (jobj) "required" (list))
  (let ((ha-url (or (uiop:getenv "HA_URL") "http://10.0.69.190:8123"))
        (token  (uiop:getenv "HA_TOKEN")))
    (if (null token)
        (values "ERROR: HA_TOKEN env var not set" t)
        (handler-case
            (progn
              (dexador:post
               (format nil "~a/api/services/light/turn_on" ha-url)
               :headers (list (cons "Authorization" (format nil "Bearer ~a" token))
                              (cons "Content-Type" "application/json"))
               :content "{\"entity_id\": \"light.testmcu_my_udp_led\"}")
              (values "LED is ON" nil))
          (error (e) (values (format nil "ERROR: ~A" e) t))))))

(define-tool LED_OFF
  "Turn off the Home Assistant LED light (light.testmcu_my_udp_led)."
  (jobj "type" "object" "properties" (jobj) "required" (list))
  (let ((ha-url (or (uiop:getenv "HA_URL") "http://10.0.69.190:8123"))
        (token  (uiop:getenv "HA_TOKEN")))
    (if (null token)
        (values "ERROR: HA_TOKEN env var not set" t)
        (handler-case
            (progn
              (dexador:post
               (format nil "~a/api/services/light/turn_off" ha-url)
               :headers (list (cons "Authorization" (format nil "Bearer ~a" token))
                              (cons "Content-Type" "application/json"))
               :content "{\"entity_id\": \"light.testmcu_my_udp_led\"}")
              (values "LED is OFF" nil))
          (error (e) (values (format nil "ERROR: ~A" e) t))))))

(define-tool LED_MORSE
  "Flash a message in Morse code via the Home Assistant LED. Pass a 'text' string to transmit."
  (jobj "type" "object"
        "properties" (jobj "text" (jobj "type" "string"
                                        "description" "Text to transmit in Morse code via LED flashes"))
        "required" (list "text"))
  (let* ((token  (uiop:getenv "HA_TOKEN"))
         (ha-url (or (uiop:getenv "HA_URL") "http://10.0.69.190:8123"))
         (entity "light.testmcu_my_udp_led")
         (text   (gethash "text" args)))
    (if (null token)
        (values "ERROR: HA_TOKEN env var not set" t)
        (let* ((headers (list (cons "Authorization" (format nil "Bearer ~a" token))
                              (cons "Content-Type" "application/json")))
               (body (format nil "{\"entity_id\": \"~a\"}" entity))
               (dit 0.15)
               (dah (* 3 dit))
               (sym-gap dit)
               (letter-gap (* 3 dit))
               (word-gap  (* 7 dit))
               (morse-table
                '((#\A . ".-")    (#\B . "-...")  (#\C . "-.-.")  (#\D . "-..")
                  (#\E . ".")     (#\F . "..-.")  (#\G . "--.")   (#\H . "....")
                  (#\I . "..")    (#\J . ".---")  (#\K . "-.-")   (#\L . ".-..")
                  (#\M . "--")    (#\N . "-.")    (#\O . "---")   (#\P . ".--.")
                  (#\Q . "--.-")  (#\R . ".-.")   (#\S . "...")   (#\T . "-")
                  (#\U . "..-")   (#\V . "...-")  (#\W . ".--")   (#\X . "-..-")
                  (#\Y . "-.--")  (#\Z . "--..")
                  (#\0 . "-----") (#\1 . ".----") (#\2 . "..---") (#\3 . "...--")
                  (#\4 . "....-") (#\5 . ".....") (#\6 . "-....") (#\7 . "--...")
                  (#\8 . "---..")  (#\9 . "----.")
                  (#\. . ".-.-.-") (#\, . "--..--") (#\? . "..--..") (#\! . "-.-.--"))))
          (handler-case
              (progn
                (flet ((flash (duration)
                         (dexador:post (format nil "~a/api/services/light/turn_on" ha-url)
                                       :headers headers :content body)
                         (sleep duration)
                         (dexador:post (format nil "~a/api/services/light/turn_off" ha-url)
                                       :headers headers :content body)
                         (sleep sym-gap)))
                  (loop for ch across (string-upcase text) do
                    (cond
                      ((char= ch #\Space) (sleep word-gap))
                      (t (let ((code (cdr (assoc ch morse-table))))
                           (when code
                             (loop for sym across code do
                               (if (char= sym #\.) (flash dit) (flash dah))))
                           (sleep letter-gap))))))
                (values (format nil "Morse sent: ~a" text) nil))
            (error (e) (values (format nil "ERROR: ~a" e) t)))))))
