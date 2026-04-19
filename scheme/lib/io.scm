;;; io.scm --- safe file I/O wrappers

(define (psi-safe-read-file path)
  (if (and path (psi-file-exists? path))
      (psi-read-file path)
      #f))
