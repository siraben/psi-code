;;; session.scm --- session model helpers over psi-message records.
;;;
;;; Session storage (the growable array) lives in C. This layer provides
;;; idiomatic Scheme access and the pure compaction algorithm, using
;;; psi-message records internally. The C layer exposes four primitives:
;;;   (psi-session-message-count)       -> integer
;;;   (psi-session-messages)            -> list of alists
;;;   (psi-session-append! role text data-or-#f)
;;;   (psi-session-clear!)

(define (psi-session-count)
  (psi-session-message-count))

(define (psi-session-record-messages)
  (psi-messages-from-alists (psi-session-messages)))

(define (psi-session-append-message! msg)
  (psi-session-append!
   (psi-message-role msg)
   (psi-message-text msg)
   (psi-message-data msg)))

;; Compaction: replace the session with a COMPACTION_SUMMARY message
;; followed by the last `keep-recent` messages.
(define (psi-session-do-compact keep-recent summary-text)
  (let* ((messages (psi-session-record-messages))
         (total    (psi-list-length messages))
         (keep     (if (> keep-recent total) total keep-recent))
         (tail     (psi-drop messages (- total keep))))
    (psi-session-clear!)
    (psi-session-append-message!
     (psi-make-message "compaction-summary" summary-text #f))
    (for-each psi-session-append-message! tail)
    #t))

;; Role prefix for compaction transcripts.
(define (psi-compaction-role-prefix msg)
  (let ((role (psi-message-role msg)))
    (cond
      ((string=? role "user")               "User: ")
      ((string=? role "assistant")          "Assistant: ")
      ((string=? role "tool-call")          "Tool call: ")
      ((string=? role "tool-result")        "Tool result: ")
      ((string=? role "compaction-summary") "Previous summary: ")
      ((string=? role "branch-summary")     "Branch summary: ")
      (else                                 "Message: "))))
