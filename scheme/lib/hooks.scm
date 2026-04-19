;;; hooks.scm --- default event-hook registrations.

(psi-register-hook! 'assistant-text
  (lambda (payload)
    (or (psi-assq-ref payload 'text) "")))

(psi-register-hook! 'tool-call  psi-capture-tool-frame!)
(psi-register-hook! 'tool-call  psi-render-tool-call)
(psi-register-hook! 'tool-result psi-render-tool-result)
(psi-register-hook! 'tool-result psi-release-tool-frame!)

(psi-register-hook! 'after-turn
  (lambda (payload) payload "\n"))
