;;; prelude.scm --- strings, lists, alists, paths, basic helpers
;;;
;;; Small, reusable pieces used by the rest of the Scheme layer.
;;; Everything is psi-prefixed so names do not collide with R7RS.

;; ---------- object printing ----------

(define (psi-object->string obj)
  (call-with-output-string
    (lambda (port) (write obj port))))

;; ---------- alist accessors ----------

(define (psi-assq-ref alist key)
  (let ((entry (assq key alist)))
    (if entry (cdr entry) #f)))

(define (psi-assoc key alist)
  (cond
    ((null? alist) #f)
    ((equal? key (caar alist)) (car alist))
    (else (psi-assoc key (cdr alist)))))

(define (psi-assoc-ref alist key)
  (let ((entry (psi-assoc key alist)))
    (if entry (cdr entry) #f)))

;; ---------- strings ----------

(define (psi-string-prefix? prefix text)
  (let ((plen (string-length prefix))
        (tlen (string-length text)))
    (and (<= plen tlen)
         (string=? prefix (substring text 0 plen)))))

(define (psi-char-space? ch)
  (or (char=? ch #\space) (char=? ch #\tab)))

(define (psi-string-trim text)
  (let ((len (string-length text)))
    (let loop-left ((i 0))
      (if (or (= i len) (not (psi-char-space? (string-ref text i))))
          (let loop-right ((e len))
            (if (or (= e i) (not (psi-char-space? (string-ref text (- e 1)))))
                (substring text i e)
                (loop-right (- e 1))))
          (loop-left (+ i 1))))))

(define (psi-string-split text separator)
  (let ((len (string-length text)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
        ((= i len)
         (reverse (if (< start i) (cons (substring text start i) acc) acc)))
        ((char=? (string-ref text i) separator)
         (loop (+ i 1) (+ i 1)
               (if (< start i) (cons (substring text start i) acc) acc)))
        (else (loop (+ i 1) start acc))))))

(define (psi-string-split-on-space text)
  (psi-string-split text #\space))

(define (psi-string-split-lines text)
  (let ((len (string-length text)))
    (let loop ((i 0) (start 0) (acc '()))
      (if (= i len)
          (reverse (cons (substring text start i) acc))
          (if (char=? (string-ref text i) #\newline)
              (loop (+ i 1) (+ i 1)
                    (cons (substring text start i) acc))
              (loop (+ i 1) start acc))))))

(define (psi-string-join pieces separator)
  (if (null? pieces)
      ""
      (let loop ((rest (cdr pieces)) (out (car pieces)))
        (if (null? rest)
            out
            (loop (cdr rest) (string-append out separator (car rest)))))))

(define (psi-string-contains? haystack needle)
  (let ((hlen (string-length haystack))
        (nlen (string-length needle)))
    (and (<= nlen hlen)
         (let loop ((i 0))
           (cond
             ((> i (- hlen nlen)) #f)
             ((string=? (substring haystack i (+ i nlen)) needle) i)
             (else (loop (+ i 1))))))))

(define (psi-string-replace-first text old-text new-text)
  (let ((index (psi-string-contains? text old-text)))
    (if index
        (string-append
         (substring text 0 index)
         new-text
         (substring text (+ index (string-length old-text)) (string-length text)))
        #f)))

;; ---------- lists ----------

(define (psi-list-length xs)
  (let loop ((rest xs) (count 0))
    (if (null? rest) count (loop (cdr rest) (+ count 1)))))

(define (psi-take xs count)
  (if (or (<= count 0) (null? xs))
      '()
      (cons (car xs) (psi-take (cdr xs) (- count 1)))))

(define (psi-drop xs count)
  (if (or (<= count 0) (null? xs))
      xs
      (psi-drop (cdr xs) (- count 1))))

(define (psi-take-right xs count)
  (reverse (psi-take (reverse xs) count)))

(define (psi-drop-right xs count)
  (reverse (psi-drop (reverse xs) count)))

;; ---------- paths ----------

(define (psi-path-join base name)
  (cond
    ((string=? base "/") (string-append "/" name))
    ((string=? base ".") name)
    (else (string-append base "/" name))))
