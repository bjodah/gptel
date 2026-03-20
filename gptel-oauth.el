;;; gptel-oauth.el --- Shared OAuth helpers for gptel backends  -*- lexical-binding: t; -*-

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

;; This file provides shared helpers used by gptel backends that authenticate
;; via OAuth or similar token-based flows.  Currently used by:
;;
;;   - gptel-chatgpt-codex.el  (OpenAI device-flow OAuth)
;;   - gptel-gh.el             (GitHub device-flow OAuth)
;;
;; The helpers fall into three groups:
;;
;;   1. Token file persistence  (`gptel-oauth--save', `gptel-oauth--restore')
;;
;;   2. Device-flow login UX   (`gptel-oauth--device-flow-prompt')
;;      Handles the SSH-vs-local distinction, clipboard copy, browser open,
;;      and the two `read-from-minibuffer' prompts that every device-flow
;;      login shares.
;;
;;   3. Synchronous HTTP helper (`gptel-oauth--request')
;;      A thin wrapper around `url-retrieve-synchronously' for the blocking
;;      POST calls needed during the device-flow exchange steps.  Backends
;;      that already have access to `gptel--url-retrieve' (an async-capable
;;      helper in gptel-request.el) may prefer that for non-blocking use.
;;
;;   4. URL form-encoding       (`gptel-oauth--url-encode-params')

;;; Code:

(require 'url-http)
(require 'browse-url)

;; gptel-request provides gptel--json-encode / gptel--json-read
(declare-function gptel--json-encode "gptel-request")
(declare-function gptel--json-read   "gptel-request")


;;;; ---- 1. Token file persistence ----------------------------------------

(defun gptel-oauth--save (file obj)
  "Persist OBJ (a plist) to FILE and return OBJ.

Creates any missing parent directories.  Writes with Unix line endings
and UTF-8 encoding so the file is portable across platforms."
  (let ((print-length nil)
        (print-level  nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (prin1-to-string obj) nil file nil :silent)
    obj))

(defun gptel-oauth--restore (file)
  "Read and return the plist previously saved to FILE.

Returns nil if FILE does not exist or cannot be parsed.  Reading uses
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


;;;; ---- 2. Device-flow login UX ------------------------------------------

(defun gptel-oauth--device-flow-prompt (user-code verification-uri &optional auth-uri-label)
  "Guide the user through a device-flow authorization step.

USER-CODE is the short code the user must enter on the provider's
website.  VERIFICATION-URI is the URL to open.  AUTH-URI-LABEL is an
optional human-readable name for the authorization page (used only in
the SSH-session message); it defaults to VERIFICATION-URI.

The function:
  1. Copies USER-CODE to the system clipboard (best-effort).
  2. In an SSH session: displays the URL and code, then blocks on
     `read-from-minibuffer' until the user presses ENTER.
  3. In a local session: prompts the user to press ENTER, opens
     VERIFICATION-URI in the browser, then blocks again.

Returns nil; callers should start polling after this returns."
  (let ((label (or auth-uri-label verification-uri))
        (in-ssh (or (getenv "SSH_CLIENT")
                    (getenv "SSH_CONNECTION")
                    (getenv "SSH_TTY"))))
    (ignore-errors (gui-set-selection 'CLIPBOARD user-code))
    (if in-ssh
        (progn
          (message "Device Code: %s (copied to clipboard)" user-code)
          (read-from-minibuffer
           (format "Code %s is copied.  Visit %s in your local browser, \
enter the code, and authorize.  Press ENTER after authorizing. "
                   user-code label)))
      (read-from-minibuffer
       (format "Your one-time code %s is copied.  \
Press ENTER to open the authorization page.  \
If your browser does not open, visit %s"
               user-code verification-uri))
      (browse-url verification-uri)
      (read-from-minibuffer "Press ENTER after authorizing in your browser. "))))


;;;; ---- 3. Synchronous HTTP helper ---------------------------------------

(defun gptel-oauth--request (url &optional data content-type extra-headers)
  "Synchronously POST to URL and return (:status N :body PLIST :raw STRING).

DATA is the request body.  CONTENT-TYPE defaults to
\"application/json\"; pass \"application/x-www-form-urlencoded\" for
form-encoded bodies (in which case DATA must already be an encoded
string).  For JSON bodies DATA should be a plist.

EXTRA-HEADERS is an alist of additional request headers.

This is intentionally blocking — suitable only for the short
handshake steps of a device-flow exchange that happen before any
gptel request is in-flight.  Use `gptel--url-retrieve' for
non-blocking network calls."
  (require 'gptel-request)
  (let* ((content-type (or content-type "application/json"))
         (url-request-method "POST")
         (url-request-data
          (encode-coding-string
           (if (string-prefix-p "application/json" content-type)
               (gptel--json-encode data)
             data)
           'utf-8))
         (url-request-extra-headers
          `(("Content-Type" . ,content-type)
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


;;;; ---- 4. URL form-encoding ---------------------------------------------

(defun gptel-oauth--url-encode-params (params)
  "Encode PARAMS alist as an application/x-www-form-urlencoded string.

PARAMS is an alist of (KEY . VALUE) string pairs.  Both keys and
values are percent-encoded via `url-hexify-string'."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair))
                       "="
                       (url-hexify-string (cdr pair))))
             params "&"))


(provide 'gptel-oauth)
;;; gptel-oauth.el ends here
