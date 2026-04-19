;;; tool-shell.scm --- shell quoting and command-result wrapping.

;; POSIX single-quote quoting: wraps text in ''; embedded quotes escaped
;; as '\'' (close-quote, escaped-quote, re-open).
(define (psi-shell-quote text)
  (if (not text)
      "''"
      (let ((len (string-length text))
            (port (open-output-string)))
        (display "'" port)
        (let loop ((i 0))
          (if (= i len)
              (begin (display "'" port) (get-output-string port))
              (let ((ch (string-ref text i)))
                (if (char=? ch #\')
                    (display "'\\''" port)
                    (write-char ch port))
                (loop (+ i 1))))))))

;; Run a shell command and package the outcome as a psi-tool-result
;; record suitable for returning from a tool impl.
(define (psi-shell-run-tool tool-name command path keep-output-on-error?)
  (let* ((proc      (psi-process-run-record command))
         (output    (psi-process-result-output proc))
         (status    (psi-process-result-status proc))
         (truncated (psi-process-result-truncated? proc))
         (ok?       (psi-process-result-ok? proc))
         (include-output?
          (or keep-output-on-error? ok?
              (and output (> (string-length output) 0))))
         (extras
          (append
           (if path (list (cons 'path path)) '())
           (list
            (cons 'command command)
            (cons 'status status)
            (cons 'truncated (if truncated #t #f)))
           (if include-output?
               (list (cons 'output (or output "")))
               '()))))
    (psi-make-tool-result ok? tool-name #f extras)))

;; Wrap the raw psi-process-run FFI into record form.
(define (psi-process-run-record command)
  (psi-process-result-from-alist (psi-process-run command)))
