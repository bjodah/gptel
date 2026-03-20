;;; gptel-auth-common.el --- Shared auth helpers for gptel  -*- lexical-binding: t; -*-

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Backend-agnostic authentication helpers shared across gptel providers.
;;
;; This file is intentionally small and boring:
;; - persistence of auth state
;; - backend resolution by predicate
;; - SSH-session detection
;; - expiry checks
;; - application/x-www-form-urlencoded encoding
;;
;; OAuth/device-flow prompting belongs in `gptel-oauth.el'.

;;; Code:

(require 'cl-lib)
(require 'url-util)

(defvar gptel-backend)
(defvar gptel--known-backends)

(defun gptel-auth-save-state (file object)
  "Save OBJECT to FILE and return OBJECT."
  (let ((print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (prin1-to-string object) nil file nil :silent)
    object))

(defun gptel-auth-restore-state (file)
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

(defun gptel-auth-ssh-session-p ()
  "Return non-nil when Emacs appears to be running in an SSH session."
  (or (getenv "SSH_CLIENT")
      (getenv "SSH_CONNECTION")
      (getenv "SSH_TTY")))

(defun gptel-auth-expires-soon-p (expires-at &optional margin)
  "Return non-nil if EXPIRES-AT is within MARGIN seconds of now.
Nil EXPIRES-AT is treated as expired."
  (< (or expires-at 0)
     (+ (float-time) (or margin 0))))

(defun gptel-auth-resolve-backend (predicate setup-message)
  "Return the active backend satisfying PREDICATE.
Check `gptel-backend' first, then `gptel--known-backends'.
Signal `user-error' with SETUP-MESSAGE if no backend matches."
  (or (and (boundp 'gptel-backend)
           gptel-backend
           (funcall predicate gptel-backend)
           gptel-backend)
      (cl-find-if predicate (mapcar #'cdr gptel--known-backends))
      (user-error "%s" setup-message)))

(defun gptel-auth-url-encode-params (params)
  "Encode PARAMS alist as application/x-www-form-urlencoded.
PARAMS must be an alist of string key/value pairs."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (car pair))
             "="
             (url-hexify-string (cdr pair))))
   params "&"))

(provide 'gptel-auth-common)

;;; gptel-auth-common.el ends here
