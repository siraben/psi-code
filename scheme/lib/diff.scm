;;; diff.scm --- simple line-based colored diff rendering

(define (psi-common-prefix-length xs ys)
  (let loop ((l xs) (r ys) (count 0))
    (if (or (null? l) (null? r) (not (string=? (car l) (car r))))
        count
        (loop (cdr l) (cdr r) (+ count 1)))))

(define (psi-common-suffix-length xs ys prefix-count)
  (psi-common-prefix-length
   (reverse (psi-drop xs prefix-count))
   (reverse (psi-drop ys prefix-count))))

(define (psi-middle-lines xs prefix-count suffix-count)
  (let* ((rest (psi-drop xs prefix-count))
         (middle (- (psi-list-length rest) suffix-count)))
    (if (<= middle 0) '() (psi-take rest middle))))

(define (psi-limit-lines lines max-lines)
  (if (<= (psi-list-length lines) max-lines)
      lines
      (append (psi-take lines max-lines) (list (psi-dim "...")))))

(define (psi-render-context-lines lines prefix)
  (map (lambda (line) (string-append prefix line)) lines))

(define (psi-render-colored-diff before-text after-text)
  (let* ((before (psi-string-split-lines (or before-text "")))
         (after  (psi-string-split-lines (or after-text "")))
         (pc (psi-common-prefix-length before after))
         (sc (psi-common-suffix-length before after pc))
         (before-middle (psi-middle-lines before pc sc))
         (after-middle  (psi-middle-lines after  pc sc))
         (before-ctx (psi-take-right (psi-take before pc) 2))
         (after-ctx  (psi-take (reverse (psi-take (reverse after) sc)) 2))
         (rendered
          (append
           (psi-render-context-lines before-ctx (psi-dim "  "))
           (map (lambda (l) (psi-red   (string-append "- " l)))
                (psi-limit-lines before-middle 40))
           (map (lambda (l) (psi-green (string-append "+ " l)))
                (psi-limit-lines after-middle 40))
           (psi-render-context-lines after-ctx (psi-dim "  ")))))
    (if (null? rendered)
        (psi-dim "  no visible diff")
        (psi-string-join rendered "\n"))))

(define (psi-preview-output text)
  (psi-string-join
   (psi-limit-lines (psi-string-split-lines text) 20)
   "\n"))
