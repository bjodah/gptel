;;; gptel-oauth.el --- OAuth device-flow helpers for gptel  -*- lexical-binding: t; -*-

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

;; OAuth 2.0 device-flow helpers shared across gptel providers:
;;
;;   - `gptel-oauth-device-auth-prompt'  clipboard + browser/SSH UX
;;   - `gptel-oauth-base64url-decode'    Base64URL → string
;;   - `gptel-oauth-jwt-payload'         decode a JWT payload to a plist
;;
;; Backend-agnostic primitives (persistence, expiry checks, backend
;; resolution, URL encoding, form-POST) live in `gptel-auth-common.el'.

;;; Code:

(require 'browse-url)
(require 'gptel-auth-common)

(declare-function gptel--json-read-string "gptel-request")


;;;; ---- Device-flow UX ----------------------------------------------------

(defun gptel-oauth-device-auth-prompt (user-code verification-uri)
  "Guide the user through an OAuth device-flow authorization step.

USER-CODE is the short code the user must enter on the provider's
website.  VERIFICATION-URI is the URL to open.

The function:
  1. Copies USER-CODE to the system clipboard (best-effort).
  2. In an SSH session: displays the URI and code, then blocks on
     `read-from-minibuffer' until the user presses ENTER.
  3. In a local session: prompts the user to press ENTER, opens
     VERIFICATION-URI in the default browser, then blocks again.

Returns nil; callers should start polling after this returns."
  (ignore-errors (gui-set-selection 'CLIPBOARD user-code))
  (if (gptel-auth-ssh-session-p)
      (progn
        (message "Device Code: %s (copied to clipboard)" user-code)
        (read-from-minibuffer
         (format "Code %s is copied.  Visit %s in your local browser, \
enter the code, and authorize.  Press ENTER after authorizing. "
                 user-code verification-uri)))
    (read-from-minibuffer
     (format "Your one-time code %s is copied.  \
Press ENTER to open the authorization page.  \
If your browser does not open, visit %s"
             user-code verification-uri))
    (browse-url verification-uri)
    (read-from-minibuffer "Press ENTER after authorizing in your browser. ")))


;;;; ---- JWT helpers -------------------------------------------------------

(defun gptel-oauth-base64url-decode (str)
  "Decode Base64URL string STR to a UTF-8 string, adding padding if necessary."
  (let* ((str (replace-regexp-in-string "-" "+" str))
         (str (replace-regexp-in-string "_" "/" str))
         (pad (% (length str) 4)))
    (when (> pad 0)
      (setq str (concat str (make-string (- 4 pad) ?=))))
    (decode-coding-string (base64-decode-string str) 'utf-8 t)))

(defun gptel-oauth-jwt-payload (jwt-string)
  "Parse the payload section of JWT-STRING and return it as a plist.
Returns nil if parsing fails."
  (condition-case nil
      (let* ((parts   (split-string jwt-string "\\."))
             (payload (nth 1 parts)))
        (when payload
          (require 'gptel-request)
          (gptel--json-read-string
           (gptel-oauth-base64url-decode payload))))
    (error nil)))


(provide 'gptel-oauth)
;;; gptel-oauth.el ends here
