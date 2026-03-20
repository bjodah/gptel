;;; gptel-oauth.el --- OAuth helpers for gptel  -*- lexical-binding: t; -*-

;;; Commentary:

;; OAuth/device-flow helpers shared across gptel providers.

;;; Code:

(require 'browse-url)
(require 'gptel-auth-common)

(cl-defun gptel-oauth-authorize-device
    (user-code verification-uri
               &key browser-message ssh-message authorized-message)
  "Guide the user through device authorization for USER-CODE.
VERIFICATION-URI is the page to visit.  In SSH sessions, avoid opening
the browser automatically."
  (ignore-errors (gui-set-selection 'CLIPBOARD user-code))
  (if (gptel-auth-ssh-session-p)
      (progn
        (message "Device code: %s (copied to clipboard)" user-code)
        (read-from-minibuffer
         (or ssh-message
             (format "Code %s is copied. Visit %s in your local browser, \
enter the code, and authorize. Press ENTER after authorizing. "
                     user-code verification-uri))))
    (read-from-minibuffer
     (or browser-message
         (format "Your one-time code %s is copied. Press ENTER to open %s \
in your browser. "
                 user-code verification-uri)))
    (browse-url verification-uri)
    (read-from-minibuffer
     (or authorized-message
         "Press ENTER after authorizing in your browser. "))))

(provide 'gptel-oauth)

;;; gptel-oauth.el ends here
