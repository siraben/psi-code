(define (psi-object->string obj)
  (call-with-output-string
    (lambda (port)
      (write obj port))))

(define (psi-handle-print prompt)
  (string-append
    "psi bootstrap online\n"
    "version: " (psi-version) "\n"
    "prompt: " prompt))

(define (psi-handle-eval value)
  (if (string? value)
      value
      (psi-object->string value)))
