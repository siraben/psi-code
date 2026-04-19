(define (psi-object->string obj)
  (call-with-output-string
    (lambda (port)
      (write obj port))))

(define (psi-handle-print prompt)
  (string-append
    "psi bootstrap online\n"
    "version: " (psi-version) "\n"
    "session-messages: " (number->string (psi-session-message-count)) "\n"
    "prompt: " prompt))

(define (psi-handle-eval value)
  (if (string? value)
      value
      (psi-object->string value)))
