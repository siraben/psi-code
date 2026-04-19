;;; tool-registry.scm --- registration and dispatch over psi-tool records.
;;;
;;; Tools are registered as psi-tool records with a name, metadata, JSON
;;; input_schema, and an `impl` procedure of type
;;;     (input-alist) -> psi-tool-result
;;;
;;; Callers:
;;;   - psi-register-tool! installs or replaces a spec.
;;;   - psi-tool-specs returns all registered tools (records).
;;;   - psi-select-tool-specs (called from C) returns alists so the
;;;     anthropic adapter can serialize them to JSON.
;;;   - psi-tool-dispatch-json is the entry used by C to run a tool
;;;     given a JSON-shaped input (already converted to an alist by the
;;;     FFI glue) and returns a JSON-shaped alist.

(define *psi-tools* '())

(define (psi-tool-filter pred xs)
  (cond
    ((null? xs) '())
    ((pred (car xs)) (cons (car xs) (psi-tool-filter pred (cdr xs))))
    (else (psi-tool-filter pred (cdr xs)))))

(define (psi-register-tool! tool)
  (let ((name (psi-tool-name tool)))
    (set! *psi-tools*
          (append
           (psi-tool-filter
            (lambda (t) (not (string=? (psi-tool-name t) name)))
            *psi-tools*)
           (list tool)))))

(define (psi-tool-specs) *psi-tools*)

(define (psi-find-tool name)
  (let loop ((rest *psi-tools*))
    (cond
      ((null? rest) #f)
      ((string=? (psi-tool-name (car rest)) name) (car rest))
      (else (loop (cdr rest))))))

;; Called from C (psi_vm_active_tool_specs_json) -> list of alists.
(define (psi-select-tool-specs user-text)
  user-text
  (map psi-tool->alist *psi-tools*))

;; Internal dispatch: input is alist, result is psi-tool-result record.
(define (psi-tool-dispatch name input)
  (let ((tool (psi-find-tool name)))
    (if tool
        ((psi-tool-impl tool) input)
        (psi-tool-failure name "unknown tool"))))

;; Entry point for C: takes name + input alist, returns result alist.
;; This is what `psi-tool-call` (the FFI primitive) invokes internally.
(define (psi-tool-dispatch-alist name input)
  (psi-tool-result->alist (psi-tool-dispatch name input)))

;; Guardrail helpers for tool impls.
(define (psi-tool-require-string input key)
  (let ((value (psi-assq-ref input key)))
    (and (string? value) (> (string-length value) 0) value)))

(define (psi-tool-optional-string input key default)
  (let ((value (psi-assq-ref input key)))
    (if (string? value) value default)))

(define (psi-tool-optional-number input key default)
  (let ((value (psi-assq-ref input key)))
    (if (number? value) value default)))

(define (psi-tool-optional-boolean input key default)
  (let ((value (psi-assq-ref input key)))
    (cond
      ((eqv? value #t) #t)
      ((eqv? value #f) default)
      (else default))))
