;;; gptel-auth-common.el --- Shared auth helpers for gptel  -*- lexical-binding: t; -*-

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Backend-agnostic authentication helpers shared across gptel providers.
;;
;; This file is intentionally small and boring:
;;   - persistence of auth state to/from disk
;;   - backend resolution by predicate
;;   - SSH-session detection
;;   - token expiry checks
;;   - application/x-www-form-urlencoded encoding
;;   - a synchronous form-POST helper (for flows that need HTTP status codes
;;     and send form-encoded rather than JSON bodies)
;;
;; OAuth/device-flow prompting and JWT parsing belong in `gptel-oauth.el'.
;; AWS SigV4 signing belongs in `gptel-bedrock.el'.
;;
;; `gptel-request.el' provides `gptel--url-retrieve' for JSON POST/GET.
;; Use that where possible; use `gptel-auth-form-post' only when you need
;; the raw HTTP status code or a form-encoded body.

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'url-http)

(defvar gptel-backend)
(defvar gptel--known-backends)
(declare-function gptel--json-read "gptel-request")


;;;; ---- Persistence -------------------------------------------------------

(defun gptel-auth-save-state (file object)
  "Persist OBJECT to FILE and return OBJECT.
Creates any missing parent directories.  Writes UTF-8 with Unix line
endings so the file is portable and round-trips cleanly on Windows."
  (let ((print-length nil)
        (print-level  nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (prin1-to-string object) nil file nil :silent)
    object))

(defun gptel-auth-restore-state (file)
  "Read and return the Lisp object previously saved to FILE.
Returns nil if FILE does not exist or cannot be parsed.  Uses
`utf-8-auto-dos' so files written on Windows (CR+LF endings) are
handled transparently."
  (when (file-exists-p file)
    (let ((coding-system-for-read 'utf-8-auto-dos))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (goto-char (point-min))
        (condition-case nil
            (read (current-buffer))
          (error nil))))))


;;;; ---- Environment helpers -----------------------------------------------

(defun gptel-auth-ssh-session-p ()
  "Return non-nil when Emacs appears to be running inside an SSH session."
  (or (getenv "SSH_CLIENT")
      (getenv "SSH_CONNECTION")
      (getenv "SSH_TTY")))

(defun gptel-auth-expires-soon-p (expires-at &optional margin)
  "Return non-nil if EXPIRES-AT unix timestamp is within MARGIN seconds of now.
A nil EXPIRES-AT is treated as already expired.
MARGIN defaults to 0 (expires exactly now)."
  (< (or expires-at 0)
     (+ (float-time) (or margin 0))))


;;;; ---- Backend resolution ------------------------------------------------

(defun gptel-auth-resolve-backend (predicate setup-message)
  "Return the active gptel backend satisfying PREDICATE.
Checks `gptel-backend' first, then all entries in `gptel--known-backends'.
Signals `user-error' with SETUP-MESSAGE if no matching backend is found."
  (or (and (boundp 'gptel-backend)
           gptel-backend
           (funcall predicate gptel-backend)
           gptel-backend)
      (cl-find-if predicate (mapcar #'cdr gptel--known-backends))
      (user-error "%s" setup-message)))


;;;; ---- URL encoding -------------------------------------------------------

(defun gptel-auth-url-encode-params (params)
  "Encode PARAMS as an application/x-www-form-urlencoded string.
PARAMS must be an alist of (STRING-KEY . STRING-VALUE) pairs."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair))
                       "="
                       (url-hexify-string (cdr pair))))
             params "&"))


;;;; ---- Synchronous form-POST ---------------------------------------------
;;
;; Use this only when you need the raw HTTP status code alongside the body,
;; or when the request body is form-encoded rather than JSON.
;; For plain JSON POST/GET, prefer `gptel--url-retrieve' from gptel-request.el.

(defun gptel-auth-form-post (url body-string &optional extra-headers)
  "Synchronously POST BODY-STRING (form-encoded) to URL.
Returns a plist (:status N :body PLIST :raw STRING).

EXTRA-HEADERS is an alist of additional request headers.

The response body is parsed as JSON into a plist; :raw holds the
unparsed string for error messages."
  (require 'gptel-request)
  (let* ((url-request-method "POST")
         (url-request-data (encode-coding-string body-string 'utf-8))
         (url-request-extra-headers
          `(("Content-Type" . "application/x-www-form-urlencoded")
            ("Accept"       . "application/json")
            ,@extra-headers))
         (url-mime-accept-string "application/json")
         (buf (url-retrieve-synchronously url 'silent)))
    (unwind-protect
        (if (not (buffer-live-p buf))
            (list :status nil :body nil :raw "")
          (with-current-buffer buf
            (let ((status   (bound-and-true-p url-http-response-status))
                  (raw-body "")
                  (parsed   nil))
              (when (bound-and-true-p url-http-end-of-headers)
                (goto-char url-http-end-of-headers)
                (setq raw-body (buffer-substring-no-properties (point) (point-max)))
                (condition-case nil
                    (progn (goto-char url-http-end-of-headers)
                           (setq parsed (gptel--json-read)))
                  (error nil)))
              (list :status status :body parsed :raw raw-body))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


(provide 'gptel-auth-common)
;;; gptel-auth-common.el ends here
