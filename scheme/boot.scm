;;; boot.scm --- psi Scheme bootstrap: load every module in order.
;;;
;;; Module load order matters: later modules reference definitions from
;;; earlier ones. `load` resolves relative to the process cwd, so we
;;; build absolute paths from this file's directory.

(import (scheme base) (scheme load) (scheme eval))

(define psi-boot-dir
  (let ((entry (assq 'boot-file (psi-runtime-info))))
    (psi-parent-directory (or (and entry (cdr entry)) "."))))

(define (psi-load-lib name)
  (load (string-append psi-boot-dir "/lib/" name)))

;; --- low-level reusable helpers --------------------------------------
(psi-load-lib "prelude.scm"); strings, lists, alists, paths
(psi-load-lib "io.scm")      ; safe file read
(psi-load-lib "ansi.scm")    ; color escapes
(psi-load-lib "diff.scm")    ; colored diff + preview

;; --- typed data model -----------------------------------------------
(psi-load-lib "records.scm") ; psi-message, psi-tool, psi-tool-result,
                                ; psi-tool-frame, psi-process-result, ...

;; --- session + tool plumbing ----------------------------------------
(psi-load-lib "session.scm") ; session accessors and compaction
(psi-load-lib "tool-registry.scm"); registration and dispatch
(psi-load-lib "tool-shell.scm")  ; shell quoting + shell-tool wrapper
(psi-load-lib "tools.scm")   ; built-in tool impls (read/write/bash/...)

;; --- presentation ---------------------------------------------------
(psi-load-lib "prompt.scm")  ; system prompt, compaction request, summary
(psi-load-lib "render.scm")  ; hooks, tool frames, event rendering
(psi-load-lib "commands.scm"); slash-command dispatch
(psi-load-lib "hooks.scm")   ; default hook registrations
