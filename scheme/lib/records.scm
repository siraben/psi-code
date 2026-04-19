;;; records.scm --- central SRFI-9 record definitions.
;;;
;;; All structured data that stays inside the Scheme layer uses records
;;; defined here. Data crossing the C FFI boundary (tool-call payloads,
;;; event payloads, tool specs seen by the Anthropic adapter) is still
;;; shaped as alists because the C layer serializes alists to JSON
;;; directly; converters between records and alists live alongside each
;;; record.

;; ---------- psi-message: session entry ----------

(define-record-type psi-message
  (psi-make-message role text data)
  psi-message?
  (role psi-message-role)       ;; string: "user" | "assistant" | "tool-call" | ...
  (text psi-message-text)       ;; string
  (data psi-message-data))      ;; string or #f (JSON payload)

(define (psi-message-from-alist entry)
  (psi-make-message
   (psi-assq-ref entry 'role)
   (or (psi-assq-ref entry 'text) "")
   (psi-assq-ref entry 'data)))

(define (psi-messages-from-alists entries)
  (map psi-message-from-alist entries))

;; ---------- psi-tool: declarative spec + implementation ----------

(define-record-type psi-tool
  (psi-make-tool name description prompt-snippet guidelines input-schema impl)
  psi-tool?
  (name            psi-tool-name)
  (description     psi-tool-description)
  (prompt-snippet  psi-tool-prompt-snippet)
  (guidelines      psi-tool-guidelines)     ;; list of strings
  (input-schema    psi-tool-input-schema)   ;; alist (JSON schema)
  (impl            psi-tool-impl))          ;; (input-alist -> psi-tool-result)

;; Converter used by the Anthropic adapter to serialize tool specs to JSON.
(define (psi-tool->alist tool)
  (list
   (cons 'name            (psi-tool-name tool))
   (cons 'description     (psi-tool-description tool))
   (cons 'prompt-snippet  (psi-tool-prompt-snippet tool))
   (cons 'prompt-guidelines (psi-tool-guidelines tool))
   (cons 'input_schema    (psi-tool-input-schema tool))))

;; ---------- psi-tool-result: dispatch outcome ----------

(define-record-type psi-tool-result
  (psi-make-tool-result ok? tool error extras)
  psi-tool-result?
  (ok?    psi-tool-result-ok?)
  (tool   psi-tool-result-tool)
  (error  psi-tool-result-error)    ;; string or #f
  (extras psi-tool-result-extras))  ;; alist of tool-specific fields

(define (psi-tool-result-ref result key)
  (psi-assq-ref (psi-tool-result-extras result) key))

(define (psi-tool-success tool . extras)
  (psi-make-tool-result #t tool #f
                        (if (null? extras) '() (car extras))))

(define (psi-tool-failure tool message)
  (psi-make-tool-result #f tool message '()))

(define (psi-tool-result->alist result)
  (append
   (list (cons 'ok   (psi-tool-result-ok? result))
         (cons 'tool (psi-tool-result-tool result)))
   (if (psi-tool-result-error result)
       (list (cons 'error (psi-tool-result-error result)))
       '())
   (psi-tool-result-extras result)))

;; Construct a result from an alist (used when decoding results that
;; come back via the FFI path, e.g. tool output parsed from JSON).
(define (psi-tool-result-from-alist alist)
  (let ((ok    (psi-assq-ref alist 'ok))
        (tool  (psi-assq-ref alist 'tool))
        (err   (psi-assq-ref alist 'error)))
    (psi-make-tool-result
     (and ok (not (eqv? ok #f)))
     (or tool "unknown")
     err
     (filter-alist alist '(ok tool error)))))

(define (filter-alist alist drop-keys)
  (cond
    ((null? alist) '())
    ((memq (caar alist) drop-keys) (filter-alist (cdr alist) drop-keys))
    (else (cons (car alist) (filter-alist (cdr alist) drop-keys)))))

;; ---------- psi-tool-frame: in-flight call metadata ----------

(define-record-type psi-tool-frame
  (psi-make-tool-frame tool input path before-text)
  psi-tool-frame?
  (tool        psi-tool-frame-tool)
  (input       psi-tool-frame-input)       ;; alist
  (path        psi-tool-frame-path)        ;; string or #f
  (before-text psi-tool-frame-before-text));; string or #f

;; ---------- psi-process-result: shell execution outcome ----------

(define-record-type psi-process-result
  (psi-make-process-result output status truncated?)
  psi-process-result?
  (output     psi-process-result-output)
  (status     psi-process-result-status)
  (truncated? psi-process-result-truncated?))

(define (psi-process-result-from-alist alist)
  (psi-make-process-result
   (or (psi-assq-ref alist 'output) "")
   (or (psi-assq-ref alist 'status) -1)
   (let ((t (psi-assq-ref alist 'truncated))) (and t (not (eqv? t #f))))))

(define (psi-process-result-ok? r)
  (eqv? (psi-process-result-status r) 0))

;; ---------- psi-context-file: project-context file entry ----------

(define-record-type psi-context-file
  (psi-make-context-file path content)
  psi-context-file?
  (path    psi-context-file-path)
  (content psi-context-file-content))

;; ---------- psi-command-action: slash-command outcome ----------
;;
;; A command returns either #f (unrecognized) or a command-action record.
;; The C driver calls psi-command-action->list for its on-wire form.

(define-record-type psi-command-action
  (psi-make-command-action kind payload)
  psi-command-action?
  (kind    psi-command-action-kind)       ;; symbol: print | compact
  (payload psi-command-action-payload))   ;; string or number

(define (psi-command-action->list action)
  (list (symbol->string (psi-command-action-kind action))
        (psi-command-action-payload action)))
