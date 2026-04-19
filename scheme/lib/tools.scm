;;; tools.scm --- psi's built-in tool implementations.
;;;
;;; Each tool is a psi-tool record registered into the global registry.
;;; Implementations receive an input alist (parsed from JSON by the C
;;; FFI glue) and return a psi-tool-result record.

;; ---------- schema helpers ----------

(define (psi-schema-type type)
  (list (cons 'type type)))

(define (psi-schema-object properties required)
  (list
   (cons 'type "object")
   (cons 'properties properties)
   (cons 'required required)))

;; ---------- read ----------

(define (psi-tool-impl-read input)
  (let ((path (psi-tool-require-string input 'path)))
    (cond
      ((not path) (psi-tool-failure "read" "missing string field: path"))
      (else
       (let ((text (psi-read-file path)))
         (psi-make-tool-result
          #t "read" #f
          (list (cons 'path path) (cons 'text text))))))))

;; ---------- write ----------

(define (psi-tool-impl-write input)
  (let ((path    (psi-tool-require-string input 'path))
        (content (or (psi-assq-ref input 'content)
                     (psi-assq-ref input 'text))))
    (cond
      ((not path) (psi-tool-failure "write" "missing string field: path"))
      ((not (string? content))
       (psi-tool-failure "write" "missing string field: content"))
      ((not (psi-file-write path content))
       (psi-tool-failure "write" "could not write full file"))
      (else
       (psi-make-tool-result
        #t "write" #f
        (list
         (cons 'path path)
         (cons 'bytes_written (string-length content))))))))

;; ---------- edit ----------

(define (psi-apply-edits text edits)
  (let loop ((rest edits) (current text) (count 0))
    (cond
      ((null? rest) (cons current count))
      ((not (pair? (car rest))) #f)
      (else
       (let* ((entry    (car rest))
              (old-text (psi-assq-ref entry 'oldText))
              (new-text (psi-assq-ref entry 'newText)))
         (cond
           ((or (not (string? old-text)) (not (string? new-text))) #f)
           (else
            (let ((next (psi-string-replace-first current old-text new-text)))
              (if next
                  (loop (cdr rest) next (+ count 1))
                  #f)))))))))

(define (psi-tool-impl-edit input)
  (let* ((path     (psi-tool-require-string input 'path))
         (edits    (psi-assq-ref input 'edits))
         (old-text (psi-assq-ref input 'oldText))
         (new-text (psi-assq-ref input 'newText)))
    (cond
      ((not path) (psi-tool-failure "edit" "missing string field: path"))
      (else
       (let ((original (psi-safe-read-file path)))
         (cond
           ((not original) (psi-tool-failure "edit" "could not read file"))
           (else
            (let ((outcome
                   (cond
                     ((list? edits) (psi-apply-edits original edits))
                     ((and (string? old-text) (string? new-text))
                      (let ((next (psi-string-replace-first original old-text new-text)))
                        (and next (cons next 1))))
                     ((not (string? old-text))
                      (psi-tool-failure "edit" "missing string field: oldText"))
                     ((not (string? new-text))
                      (psi-tool-failure "edit" "missing string field: newText"))
                     (else #f))))
              (cond
                ((psi-tool-result? outcome) outcome)
                ((not outcome) (psi-tool-failure "edit" "target text not found"))
                (else
                 (let ((edited (car outcome)) (replacements (cdr outcome)))
                   (if (not (psi-file-write path edited))
                       (psi-tool-failure "edit" "could not write full file")
                       (psi-make-tool-result
                        #t "edit" #f
                        (list
                         (cons 'path path)
                         (cons 'replacements replacements)))))))))))))))

;; ---------- bash ----------

(define (psi-tool-impl-bash input)
  (let ((command (psi-tool-require-string input 'command)))
    (if (not command)
        (psi-tool-failure "bash" "missing string field: command")
        (psi-shell-run-tool "bash" command #f #t))))

;; ---------- grep ----------

(define (psi-build-grep-command pattern path glob limit context ignore-case? literal?)
  (let ((port (open-output-string)))
    (display "command -v rg >/dev/null 2>&1 || { echo 'rg is required for grep' >&2; exit 127; }; " port)
    (display "rg -n --no-heading --color never --hidden --max-count " port)
    (display limit port)
    (when-positive context
                   (lambda (n)
                     (display " -C " port)
                     (display n port)))
    (if ignore-case? (display " -i" port) #f)
    (if literal? (display " -F" port) #f)
    (if glob
        (begin (display " --glob " port) (display (psi-shell-quote glob) port))
        #f)
    (display " " port)
    (display (psi-shell-quote pattern) port)
    (display " " port)
    (display (psi-shell-quote path) port)
    (get-output-string port)))

(define (when-positive value proc)
  (if (and (number? value) (> value 0)) (proc value) #f))

(define (psi-tool-impl-grep input)
  (let ((pattern (psi-tool-require-string input 'pattern)))
    (if (not pattern)
        (psi-tool-failure "grep" "missing string field: pattern")
        (let* ((path        (psi-tool-optional-string input 'path "."))
               (glob        (psi-assq-ref input 'glob))
               (glob        (if (string? glob) glob #f))
               (limit       (psi-tool-optional-number input 'limit 100))
               (context     (psi-tool-optional-number input 'context 0))
               (ignore-case (psi-tool-optional-boolean input 'ignoreCase #f))
               (literal     (psi-tool-optional-boolean input 'literal #f))
               (command     (psi-build-grep-command
                              pattern path glob limit context ignore-case literal)))
          (psi-shell-run-tool "grep" command path #t)))))

;; ---------- find ----------

(define (psi-tool-impl-find input)
  (let ((pattern (psi-tool-require-string input 'pattern)))
    (if (not pattern)
        (psi-tool-failure "find" "missing string field: pattern")
        (let* ((path    (psi-tool-optional-string input 'path "."))
               (limit   (psi-tool-optional-number input 'limit 1000))
               (command (string-append
                         "command -v fd >/dev/null 2>&1 || "
                         "{ echo 'fd is required for find' >&2; exit 127; }; "
                         "fd --hidden --max-results " (number->string limit)
                         " --glob " (psi-shell-quote pattern)
                         " " (psi-shell-quote path))))
          (psi-shell-run-tool "find" command path #t)))))

;; ---------- ls ----------

(define (psi-tool-impl-ls input)
  (let* ((path    (psi-tool-optional-string input 'path "."))
         (limit   (psi-tool-optional-number input 'limit 500))
         (command (string-append
                   "ls -1A " (psi-shell-quote path)
                   " | sed -n '1," (number->string limit) "p'")))
    (psi-shell-run-tool "ls" command path #t)))

;; ---------- scheme (introspection/eval) ----------

(define (psi-tool-impl-scheme input)
  (let* ((mode       (psi-tool-optional-string input 'mode "summary"))
         (expression (or (psi-assq-ref input 'expression)
                         (psi-assq-ref input 'code))))
    (cond
      ((or (string=? mode "summary") (string=? mode "inspect"))
       (psi-make-tool-result
        #t "scheme" #f
        (list
         (cons 'mode mode)
         (cons 'result (psi-runtime-summary)))))
      ((string=? mode "eval")
       (cond
         ((not (string? expression))
          (psi-tool-failure "scheme" "missing string field: expression"))
         (else
          (psi-make-tool-result
           #t "scheme" #f
           (list
            (cons 'mode mode)
            (cons 'expression expression)
            (cons 'result (psi-eval-to-string expression)))))))
      (else (psi-tool-failure "scheme" "unsupported mode")))))

(define (psi-eval-to-string expression)
  (let ((value (eval (read (open-input-string expression))
                     (interaction-environment))))
    (if (string? value) value (psi-object->string value))))

;; ---------- registrations ----------

(define psi-edit-item-schema
  (psi-schema-object
   (list (cons 'oldText (psi-schema-type "string"))
         (cons 'newText (psi-schema-type "string")))
   '("oldText" "newText")))

(psi-register-tool!
 (psi-make-tool
  "read"
  "Read the contents of a file. Use this to inspect source files, configuration, and other project assets."
  "Read file contents"
  '("Use read to examine files instead of cat or sed.")
  (psi-schema-object
   (list (cons 'path (psi-schema-type "string")))
   '("path"))
  psi-tool-impl-read))

(psi-register-tool!
 (psi-make-tool
  "bash"
  "Execute a shell command in the current working directory and return its output."
  "Execute bash commands (ls, rg, find, tests, git, build commands)"
  '("Use bash for commands such as ls, rg, find, git, and tests.")
  (psi-schema-object
   (list
    (cons 'command (psi-schema-type "string"))
    (cons 'timeout (psi-schema-type "number")))
   '("command"))
  psi-tool-impl-bash))

(psi-register-tool!
 (psi-make-tool
  "edit"
  "Edit a single file using exact text replacement. Prefer small, precise edits over broad rewrites."
  "Make precise file edits with exact text replacement, including multiple disjoint edits in one call"
  '("Use edit for precise changes where old text can be matched exactly."
    "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[]."
    "Keep edits[].oldText as small as possible while still being unique in the file.")
  (psi-schema-object
   (list
    (cons 'path (psi-schema-type "string"))
    (cons 'edits
          (list (cons 'type "array")
                (cons 'items psi-edit-item-schema))))
   '("path" "edits"))
  psi-tool-impl-edit))

(psi-register-tool!
 (psi-make-tool
  "write"
  "Write content to a file. Creates the file if it does not exist and overwrites it if it does."
  "Create or overwrite files"
  '("Use write for new files or full rewrites.")
  (psi-schema-object
   (list
    (cons 'path (psi-schema-type "string"))
    (cons 'content (psi-schema-type "string")))
   '("path" "content"))
  psi-tool-impl-write))

(psi-register-tool!
 (psi-make-tool
  "grep"
  "Search file contents for a pattern and return matching lines with file paths and line numbers."
  "Search file contents for patterns (prefer this over broad shell grep)"
  '("Prefer grep over bash when searching file contents.")
  (psi-schema-object
   (list
    (cons 'pattern    (psi-schema-type "string"))
    (cons 'path       (psi-schema-type "string"))
    (cons 'glob       (psi-schema-type "string"))
    (cons 'ignoreCase (psi-schema-type "boolean"))
    (cons 'literal    (psi-schema-type "boolean"))
    (cons 'context    (psi-schema-type "number"))
    (cons 'limit      (psi-schema-type "number")))
   '("pattern"))
  psi-tool-impl-grep))

(psi-register-tool!
 (psi-make-tool
  "find"
  "Find files by glob pattern relative to a directory."
  "Find files by glob pattern"
  '("Prefer find over bash when locating files.")
  (psi-schema-object
   (list
    (cons 'pattern (psi-schema-type "string"))
    (cons 'path    (psi-schema-type "string"))
    (cons 'limit   (psi-schema-type "number")))
   '("pattern"))
  psi-tool-impl-find))

(psi-register-tool!
 (psi-make-tool
  "ls"
  "List directory contents."
  "List directory contents"
  '("Prefer ls over bash for a quick directory listing.")
  (psi-schema-object
   (list
    (cons 'path  (psi-schema-type "string"))
    (cons 'limit (psi-schema-type "number")))
   '())
  psi-tool-impl-ls))

(psi-register-tool!
 (psi-make-tool
  "scheme"
  "Inspect or evaluate expressions in psi's embedded Scheme runtime. Use this to inspect loaded helpers, prompt state, tool specs, or runtime environment."
  "Inspect or evaluate the embedded Scheme runtime and helper environment"
  '("Use scheme with mode summary to inspect the current runtime and helper environment."
    "Use scheme with mode eval and an expression string to inspect or interact with psi's Scheme state.")
  (psi-schema-object
   (list
    (cons 'mode       (psi-schema-type "string"))
    (cons 'expression (psi-schema-type "string"))
    (cons 'code       (psi-schema-type "string")))
   '())
  psi-tool-impl-scheme))
