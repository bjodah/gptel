;;; gptel-oauth.el --- Shared OAuth helpers for gptel  -*- lexical-binding: t; -*-

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Shared helpers for OAuth/device-flow based backends.
;;
;; Keep this file intentionally small: persistence helpers, backend lookup,
;; device-code user interaction, and token-expiry checks.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'url-util)

(defvar gptel-backend)
(defvar gptel--known-backends)

(defun gptel-oauth-save-state (file object)
  "Save OBJECT to FILE."
  (let ((print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (prin1-to-string object) nil file nil :silent)
    object))

(defun gptel-oauth-restore-state (file)
  "Restore Lisp object from FILE.
Return nil if FILE does not exist or cannot be read."
  (when (file-exists-p file)
    (let ((coding-system-for-read 'utf-8-auto-dos))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (goto-char (point-min))
        (condition-case nil
            (read (current-buffer))
          (error nil))))))

(defun gptel-oauth-ssh-session-p ()
  "Return non-nil when Emacs is running in an SSH session."
  (or (getenv "SSH_CLIENT")
      (getenv "SSH_CONNECTION")
      (getenv "SSH_TTY")))

(defun gptel-oauth-expires-soon-p (expires-at &optional margin)
  "Return non-nil if EXPIRES-AT is within MARGIN seconds of now.
When EXPIRES-AT is nil, treat it as expired."
  (< (or expires-at 0)
     (+ (float-time) (or margin 0))))

(defun gptel-oauth-resolve-backend (predicate setup-message)
  "Return an active backend satisfying PREDICATE.
Checks `gptel-backend' first, then `gptel--known-backends'.
Signal `user-error' with SETUP-MESSAGE if none is found."
  (or (and (boundp 'gptel-backend)
           gptel-backend
           (funcall predicate gptel-backend)
           gptel-backend)
      (cl-find-if predicate (mapcar #'cdr gptel--known-backends))
      (user-error "%s" setup-message)))

(cl-defun gptel-oauth-authorize-device
    (user-code verification-uri
               &key browser-message ssh-message authorized-message)
  "Guide the user through device authorization for USER-CODE.
VERIFICATION-URI is the page to visit.  In SSH sessions, avoid opening
the browser automatically."
  (ignore-errors (gui-set-selection 'CLIPBOARD user-code))
  (if (gptel-oauth-ssh-session-p)
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

(defun gptel-oauth-url-encode-params (params)
  "Encode PARAMS alist as application/x-www-form-urlencoded.
PARAMS must be an alist of string key/value pairs."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (car pair))
             "="
             (url-hexify-string (cdr pair))))
   params "&"))

(provide 'gptel-oauth)

+;;; gptel-oauth.el ends here
