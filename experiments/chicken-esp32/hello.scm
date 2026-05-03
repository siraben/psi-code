;; Minimal Scheme used to verify Chicken's csc → C path.
;; If we ever embed Chicken on the ESP32, the system-prompt builder
;; (currently a baked-in C string in src/backend/esp/esp_main.c) is
;; the natural first port, since it wants string interpolation +
;; light-weight composition that Scheme handles well.

(define (psi-build-system-prompt mac)
  (string-append
   "You are psi on an ESP32 (mac " mac ").\n"
   "Tools: system_info wifi_scan http_fetch gpio_* nvs_* uart_log time_now restart.\n"
   "Be concise."))

(display (psi-build-system-prompt "e0:8c:fe:5d:20:a8")) (newline)
