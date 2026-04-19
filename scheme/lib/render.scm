;;; render.scm --- hooks, tool-frame tracking, and event rendering.

;; ---------- hooks ----------

(define *psi-hooks* '())

(define (psi-register-hook! event proc)
  (let ((entry (assq event *psi-hooks*)))
    (if entry
        (set-cdr! entry (append (cdr entry) (list proc)))
        (set! *psi-hooks*
              (append *psi-hooks* (list (cons event (list proc))))))))

(define (psi-run-hooks event payload)
  (let ((entry (assq event *psi-hooks*)))
    (if entry (map (lambda (p) (p payload)) (cdr entry)) '())))

(define (psi-render-hook-results results)
  (let loop ((rest results) (acc '()))
    (if (null? rest)
        (psi-string-join (reverse acc) "")
        (let ((item (car rest)))
          (loop (cdr rest)
                (if (and item (string? item)) (cons item acc) acc))))))

(define (psi-handle-event event payload)
  (psi-render-hook-results (psi-run-hooks event payload)))

;; ---------- tool frame registry ----------

(define *psi-tool-frames* '())

(define (psi-store-tool-frame! id frame)
  (let loop ((rest *psi-tool-frames*) (acc '()))
    (cond
      ((null? rest)
       (set! *psi-tool-frames* (reverse (cons (cons id frame) acc))))
      ((equal? id (caar rest))
       (set! *psi-tool-frames*
             (append (reverse acc) (cons (cons id frame) (cdr rest)))))
      (else (loop (cdr rest) (cons (car rest) acc))))))

(define (psi-lookup-tool-frame id)
  (psi-assoc-ref *psi-tool-frames* id))

(define (psi-remove-tool-frame! id)
  (let loop ((rest *psi-tool-frames*) (acc '()))
    (cond
      ((null? rest) (set! *psi-tool-frames* (reverse acc)))
      ((equal? id (caar rest))
       (set! *psi-tool-frames* (append (reverse acc) (cdr rest))))
      (else (loop (cdr rest) (cons (car rest) acc))))))

;; ---------- renderer helpers ----------

(define (psi-render-tool-banner tool path)
  (string-append
   "\n" (psi-bold (psi-cyan tool))
   (if path (string-append " " path) "")
   "\n"))

;; Event payload helpers. Events are passed in from C as alists with
;; keys tool/id/input/result. We still use alist accessors here because
;; the event payload is the raw FFI shape; individual renderers can
;; wrap the `result` into a psi-tool-result record via the helper below.

(define (psi-payload-tool p)   (psi-assq-ref p 'tool))
(define (psi-payload-id p)     (psi-assq-ref p 'id))
(define (psi-payload-input p)  (or (psi-assq-ref p 'input) '()))
(define (psi-payload-result p)
  (psi-tool-result-from-alist (or (psi-assq-ref p 'result) '())))

;; ---------- call renderers ----------

(define (psi-render-read-call payload)
  (psi-render-tool-banner "read" (psi-assq-ref (psi-payload-input payload) 'path)))

(define (psi-render-bash-call payload)
  (let ((command (psi-assq-ref (psi-payload-input payload) 'command)))
    (string-append "\n" (psi-bold (psi-cyan "$")) " " (or command "") "\n")))

(define (psi-render-write-call payload)
  (psi-render-tool-banner "write" (psi-assq-ref (psi-payload-input payload) 'path)))

(define (psi-render-edit-call payload)
  (let* ((input (psi-payload-input payload))
         (path  (psi-assq-ref input 'path))
         (edits (psi-assq-ref input 'edits))
         (count (if (pair? edits) (psi-list-length edits) 1)))
    (string-append
     (psi-render-tool-banner "edit" path)
     (psi-dim (string-append "planned edits: " (number->string count)))
     "\n")))

(define (psi-render-search-call tool payload)
  (let* ((input   (psi-payload-input payload))
         (pattern (psi-assq-ref input 'pattern))
         (path    (or (psi-assq-ref input 'path) ".")))
    (string-append
     (psi-render-tool-banner tool path)
     (if pattern
         (string-append (psi-dim (string-append "pattern: " pattern)) "\n")
         ""))))

(define (psi-render-scheme-call payload)
  (let* ((input (psi-payload-input payload))
         (mode  (or (psi-assq-ref input 'mode) "summary")))
    (string-append "\n" (psi-bold (psi-cyan "scheme")) " " mode "\n")))

(define (psi-render-generic-call payload)
  (psi-render-tool-banner
   (or (psi-payload-tool payload) "tool")
   (psi-assq-ref (psi-payload-input payload) 'path)))

;; ---------- result renderers ----------

(define (psi-result-error-line tool-name result)
  (string-append
   (psi-red (string-append tool-name " failed"))
   ": "
   (or (psi-tool-result-error result) "unknown error")
   "\n"))

(define (psi-render-read-result payload frame)
  (let ((result (psi-payload-result payload))
        (path   (and frame (psi-tool-frame-path frame))))
    (if (psi-tool-result-ok? result)
        (string-append
         (psi-dim "completed read")
         (if path (string-append " " path) "")
         "\n")
        (psi-result-error-line "read" result))))

(define (psi-render-bash-result payload frame)
  frame
  (let* ((result (psi-payload-result payload))
         (status (psi-tool-result-ref result 'status))
         (output (psi-tool-result-ref result 'output))
         (banner (if (psi-tool-result-ok? result)
                     (psi-dim (string-append "command finished with status "
                                             (psi-object->string status)))
                     (psi-red (string-append "command failed with status "
                                             (psi-object->string status))))))
    (string-append
     banner "\n"
     (if (and output (> (string-length output) 0))
         (string-append (psi-preview-output output) "\n")
         ""))))

(define (psi-render-write-result payload frame)
  (let* ((result      (psi-payload-result payload))
         (input       (and frame (psi-tool-frame-input frame)))
         (path        (or (and frame (psi-tool-frame-path frame))
                          (psi-tool-result-ref result 'path)
                          (and input (psi-assq-ref input 'path))))
         (before-text (and frame (psi-tool-frame-before-text frame)))
         (after-text  (if path (psi-safe-read-file path) #f))
         (content     (and input (or (psi-assq-ref input 'content)
                                     (psi-assq-ref input 'text)))))
    (if (psi-tool-result-ok? result)
        (string-append
         (psi-dim (string-append (if before-text "updated " "created ") path))
         "\n"
         (psi-render-colored-diff before-text (or after-text content ""))
         "\n")
        (psi-result-error-line "write" result))))

(define (psi-render-edit-result payload frame)
  (let* ((result      (psi-payload-result payload))
         (path        (or (and frame (psi-tool-frame-path frame))
                          (psi-tool-result-ref result 'path)))
         (before-text (and frame (psi-tool-frame-before-text frame)))
         (after-text  (if path (psi-safe-read-file path) #f)))
    (if (psi-tool-result-ok? result)
        (string-append
         (psi-dim (string-append "updated " path))
         "\n"
         (psi-render-colored-diff before-text (or after-text ""))
         "\n")
        (psi-result-error-line "edit" result))))

(define (psi-render-search-result payload)
  (let* ((result (psi-payload-result payload))
         (output (psi-tool-result-ref result 'output)))
    (if (psi-tool-result-ok? result)
        (if (and output (> (string-length output) 0))
            (string-append (psi-preview-output output) "\n")
            (string-append (psi-dim "no output") "\n"))
        (psi-result-error-line "tool" result))))

(define (psi-render-scheme-result payload frame)
  frame
  (let* ((result (psi-payload-result payload))
         (text   (or (psi-tool-result-ref result 'result) "")))
    (if (psi-tool-result-ok? result)
        (string-append (psi-preview-output text) "\n")
        (psi-result-error-line "scheme" result))))

(define (psi-render-generic-result payload frame)
  frame
  (let ((result (psi-payload-result payload)))
    (string-append
     (if (psi-tool-result-ok? result)
         (psi-dim "tool completed")
         (psi-red (string-append
                   "tool failed: "
                   (or (psi-tool-result-error result) "unknown error"))))
     "\n")))

;; ---------- dispatch ----------

(define (psi-render-tool-call payload)
  (let ((tool (psi-payload-tool payload)))
    (cond
      ((string=? tool "read")   (psi-render-read-call payload))
      ((string=? tool "bash")   (psi-render-bash-call payload))
      ((string=? tool "write")  (psi-render-write-call payload))
      ((string=? tool "edit")   (psi-render-edit-call payload))
      ((string=? tool "grep")   (psi-render-search-call "grep" payload))
      ((string=? tool "find")   (psi-render-search-call "find" payload))
      ((string=? tool "ls")     (psi-render-search-call "ls" payload))
      ((string=? tool "scheme") (psi-render-scheme-call payload))
      (else                     (psi-render-generic-call payload)))))

(define (psi-render-tool-result payload)
  (let* ((id    (psi-payload-id payload))
         (tool  (psi-payload-tool payload))
         (frame (and id (psi-lookup-tool-frame id))))
    (cond
      ((string=? tool "read")   (psi-render-read-result payload frame))
      ((string=? tool "bash")   (psi-render-bash-result payload frame))
      ((string=? tool "write")  (psi-render-write-result payload frame))
      ((string=? tool "edit")   (psi-render-edit-result payload frame))
      ((or (string=? tool "grep") (string=? tool "find") (string=? tool "ls"))
       (psi-render-search-result payload))
      ((string=? tool "scheme") (psi-render-scheme-result payload frame))
      (else                     (psi-render-generic-result payload frame)))))

;; ---------- frame capture/release ----------

(define (psi-capture-tool-frame! payload)
  (let* ((tool  (psi-payload-tool payload))
         (input (psi-payload-input payload))
         (id    (psi-payload-id payload))
         (path  (and input (psi-assq-ref input 'path)))
         (before-text
          (if (and path (or (string=? tool "write") (string=? tool "edit")))
              (psi-safe-read-file path)
              #f)))
    (if id
        (psi-store-tool-frame!
         id
         (psi-make-tool-frame tool input path before-text))
        #f)
    #f))

(define (psi-release-tool-frame! payload)
  (let ((id (psi-payload-id payload)))
    (if id (psi-remove-tool-frame! id) #f)
    #f))
