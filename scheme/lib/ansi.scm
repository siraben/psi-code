;;; ansi.scm --- ANSI color helpers

(define psi-ansi-escape (string #\x1b))

(define (psi-ansi code text)
  (string-append psi-ansi-escape "[" code "m" text psi-ansi-escape "[0m"))

(define (psi-bold text)   (psi-ansi "1" text))
(define (psi-dim text)    (psi-ansi "2" text))
(define (psi-cyan text)   (psi-ansi "36" text))
(define (psi-green text)  (psi-ansi "32" text))
(define (psi-red text)    (psi-ansi "31" text))
(define (psi-yellow text) (psi-ansi "33" text))
