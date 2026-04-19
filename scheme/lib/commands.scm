;;; commands.scm --- slash-command dispatch.
;;;
;;; psi-handle-command returns a psi-command-action record (or #f).
;;; C calls psi-handle-command-list which returns a plain (kind-string
;;; payload) list for easy parsing by the vm bridge.

(define psi-compact-default-count 12)

(define (psi-parse-compact-count line)
  (let ((rest (psi-string-trim (substring line 8 (string-length line)))))
    (if (= (string-length rest) 0)
        psi-compact-default-count
        (or (string->number rest) psi-compact-default-count))))

(define (psi-command-compact? line)
  (and (psi-string-prefix? "/compact" line)
       (or (= (string-length line) 8)
           (let ((ch (string-ref line 8)))
             (or (char=? ch #\space) (char=? ch #\tab))))))

(define (psi-session-status-text)
  (string-append
   "session-messages: "
   (number->string (psi-session-message-count))))

(define (psi-handle-command line)
  (cond
    ((or (string=? line "/help") (string=? line "/h"))
     (psi-make-command-action 'print (psi-build-help-text)))
    ((string=? line "/session")
     (psi-make-command-action 'print (psi-session-status-text)))
    ((string=? line "/system-prompt")
     (psi-make-command-action 'print (psi-build-system-prompt)))
    ((psi-command-compact? line)
     (psi-make-command-action 'compact (psi-parse-compact-count line)))
    (else #f)))

;; Bridge for C: returns either #f or a (kind-string payload) list.
(define (psi-handle-command-list line)
  (let ((action (psi-handle-command line)))
    (if action (psi-command-action->list action) #f)))
