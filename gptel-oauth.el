;;; gptel-oauth.el --- OAuth utilities for gptel  -*- lexical-binding: t; -*-

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

;; Provides common OAuth 2.0 device flow utilities, token persistence, and
;; JWT parsing used across various gptel backends (e.g., GitHub Copilot,
;; ChatGPT Codex).

;;; Code:

(require 'cl-lib)
(require 'browse-url)

(declare-function gptel--json-read-string "gptel-request")

(defun gptel-oauth-save-token (file token)
  "Save TOKEN plist to FILE."
  (let ((print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region (prin1-to-string token) nil file nil :silent)
    token))

(defun gptel-oauth-restore-token (file)
  "Restore token plist from FILE."
  (when (file-exists-p file)
    ;; Set coding system to auto-dos so files with CR EOL read properly.
    (let ((coding-system-for-read 'utf-8-auto-dos))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (goto-char (point-min))
        (condition-case nil
            (read (current-buffer))
          (error nil))))))

(defun gptel-oauth-device-auth-prompt (user-code verification-uri)
  "Prompt the user to authorize the device flow using USER-CODE and VERIFICATION-URI.
Copies USER-CODE to the clipboard and conditionally opens a browser."
  (let ((in-ssh-session (or (getenv "SSH_CLIENT")
                            (getenv "SSH_CONNECTION")
                            (getenv "SSH_TTY"))))
    (ignore-errors (gui-set-selection 'CLIPBOARD user-code))
    (if in-ssh-session
        (progn
          (message "Device Code: %s (copied to clipboard)" user-code)
          (read-from-minibuffer
           (format "Code %s is copied. Visit %s in your local browser, enter the code, and authorize.  Press ENTER after authorizing. "
                   user-code verification-uri)))
      (read-from-minibuffer
       (format "Your one-time code %s is copied. Press ENTER to open the authorization page. If your browser does not open automatically, browse to %s."
               user-code verification-uri))
      (browse-url verification-uri)
      (read-from-minibuffer "Press ENTER after authorizing. "))))

(defun gptel-oauth-base64url-decode (str)
  "Decode Base64URL string STR, adding padding if necessary."
  (let* ((str (replace-regexp-in-string "-" "+" str))
         (str (replace-regexp-in-string "_" "/" str))
         (pad (% (length str) 4)))
    (when (> pad 0)
      (setq str (concat str (make-string (- 4 pad) ?=))))
    (decode-coding-string (base64-decode-string str) 'utf-8 t)))

(defun gptel-oauth-jwt-payload (jwt-string)
  "Parse the payload of JWT-STRING and return it as a plist.
Returns nil if parsing fails."
  (condition-case nil
      (let* ((parts (split-string jwt-string "\\."))
             (payload (nth 1 parts)))
        (when payload
          (gptel--json-read-string
           (gptel-oauth-base64url-decode payload))))
    (error nil)))

(provide 'gptel-oauth)

;;; gptel-oauth.el ends here

