;;; gptel-chatgpt-codex.el --- ChatGPT Codex support for gptel  -*- lexical-binding: t; -*-

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

;; This file adds support for OpenAI's ChatGPT Plus/Pro Codex endpoint to
;; gptel.  It uses OAuth device-flow authentication and inherits from
;; `gptel-openai-responses' for request/response handling.
;;
;; Usage:
;;
;;   (require 'gptel-chatgpt-codex)
;;   (gptel-make-openai-chatgpt "ChatGPT-Codex")
;;   ;; Then: M-x gptel-openai-chatgpt-login
;;
;; After logging in, ChatGPT Codex models can be used like any other gptel
;; backend.  Tokens are refreshed automatically at request time.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'url-http)
(require 'browse-url)
(require 'gptel-request)
(require 'gptel-openai-responses)

;; Forward declarations
(defvar gptel-backend)
(defvar gptel--known-backends)
(declare-function gptel--process-models "gptel-request")
(declare-function gptel--json-encode "gptel-request")
(declare-function gptel--json-read "gptel-request")
(declare-function gptel--json-read-string "gptel-request")


;;; ---- Constants and customizations ----

(defconst gptel--openai-chatgpt-issuer "https://auth.openai.com"
  "Base URL for OpenAI authentication endpoints.")

(defconst gptel--openai-chatgpt-client-id "app_EMoamEEZ73f0CkXaXp7hrann"
  "OAuth client ID for ChatGPT Codex device flow.")

(defconst gptel--openai-chatgpt-safety-margin 60
  "Seconds before token expiry to trigger a refresh.")

(defconst gptel--openai-chatgpt-polling-safety-margin 3
  "Extra seconds to wait between device-auth polling requests.")

(defconst gptel--openai-chatgpt-polling-timeout 300
  "Maximum seconds to wait during device-auth polling before giving up.")

(defcustom gptel-openai-chatgpt-token-file
  (expand-file-name ".cache/chatgpt-codex/token" user-emacs-directory)
  "File where the ChatGPT OAuth token is stored."
  :type 'string
  :group 'gptel)

;; Model metadata is approximate; revise after manual traces.
(defcustom gptel--openai-chatgpt-models
  '((gpt-5\.4
     :description "GPT-5.4 via ChatGPT Codex"
     :capabilities (responses-api tool-use media json url)
     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp")
     :context-window 128
     :input-cost 0
     :output-cost 0
     :cutoff-date "2025-03")
    (gpt-5\.3-codex
     :description "GPT-5.3 Codex via ChatGPT subscription"
     :capabilities (responses-api tool-use media json url)
     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp")
     :context-window 128
     :input-cost 0
     :output-cost 0
     :cutoff-date "2025-03"))
  "Available models for ChatGPT Codex backend.

Each entry is (SYMBOL . PLIST) where PLIST contains model metadata."
  :type '(alist :key-type symbol :value-type plist)
  :group 'gptel)


;;; ---- Backend struct ----

(cl-defstruct (gptel-openai-chatgpt
               (:include gptel-openai-responses)
               (:copier nil)
               (:constructor gptel--make-openai-chatgpt))
  "A ChatGPT Codex backend for gptel."
  token)


;;; ---- Persistence helpers ----

(defun gptel--openai-chatgpt-save-token (token)
  "Save TOKEN plist to `gptel-openai-chatgpt-token-file'."
  (let ((print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory gptel-openai-chatgpt-token-file) t)
    (write-region (prin1-to-string token) nil
                  gptel-openai-chatgpt-token-file nil :silent)
    token))

(defun gptel--openai-chatgpt-restore-token ()
  "Restore token plist from `gptel-openai-chatgpt-token-file'."
  (when (file-exists-p gptel-openai-chatgpt-token-file)
    (let ((coding-system-for-read 'utf-8-auto-dos))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally gptel-openai-chatgpt-token-file)
        (goto-char (point-min))
        (condition-case nil
            (read (current-buffer))
          (error nil))))))


;;; ---- JWT / account-id helpers ----

(defun gptel--openai-chatgpt-base64url-decode (str)
  "Decode Base64URL string STR, adding padding if necessary."
  (let* ((str (replace-regexp-in-string "-" "+" str))
         (str (replace-regexp-in-string "_" "/" str))
         (pad (% (length str) 4)))
    (when (> pad 0)
      (setq str (concat str (make-string (- 4 pad) ?=))))
    (decode-coding-string (base64-decode-string str) 'utf-8 t)))

(defun gptel--openai-chatgpt-jwt-payload (jwt-string)
  "Parse the payload of JWT-STRING and return it as a plist.
Returns nil if parsing fails."
  (condition-case nil
      (let* ((parts (split-string jwt-string "\\."))
             (payload (nth 1 parts)))
        (when payload
          (gptel--json-read-string
           (gptel--openai-chatgpt-base64url-decode payload))))
    (error nil)))

(defun gptel--openai-chatgpt-extract-account-id-from-claims (claims)
  "Extract account ID from JWT CLAIMS plist.
Checks multiple claim locations in order."
  (when claims
    (or (plist-get claims :chatgpt_account_id)
        (when-let* ((auth-ns (plist-get claims (intern ":https://api.openai.com/auth"))))
          (plist-get auth-ns :chatgpt_account_id))
        (when-let* ((orgs (plist-get claims :organizations)))
          (when (and (vectorp orgs) (> (length orgs) 0))
            (plist-get (aref orgs 0) :id))))))

(defun gptel--openai-chatgpt-extract-account-id (token-plist)
  "Extract account ID from TOKEN-PLIST by parsing JWT claims.
Checks :id_token first, then :access_token."
  (or (when-let* ((id-token (plist-get token-plist :id_token)))
        (gptel--openai-chatgpt-extract-account-id-from-claims
         (gptel--openai-chatgpt-jwt-payload id-token)))
      (when-let* ((access-token (plist-get token-plist :access_token)))
        (gptel--openai-chatgpt-extract-account-id-from-claims
         (gptel--openai-chatgpt-jwt-payload access-token)))))


;;; ---- URL encoding helper ----

(defun gptel--openai-chatgpt-url-encode-params (params)
  "Encode PARAMS alist as application/x-www-form-urlencoded string.
PARAMS is an alist of (KEY . VALUE) string pairs."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair))
                       "="
                       (url-hexify-string (cdr pair))))
             params "&"))


;;; ---- Low-level HTTP helper ----

(defun gptel--openai-chatgpt-request (url &optional data content-type extra-headers)
  "POST to URL with DATA and return (:status N :body PLIST :raw STRING).

CONTENT-TYPE defaults to \"application/json\".  When CONTENT-TYPE is
\"application/x-www-form-urlencoded\", DATA should be an already-encoded string.
When CONTENT-TYPE is \"application/json\", DATA should be a plist.
EXTRA-HEADERS is an alist of additional headers."
  (let* ((content-type (or content-type "application/json"))
         (url-request-method "POST")
         (url-request-data
          (encode-coding-string
           (cond
            ((string-prefix-p "application/json" content-type)
             (gptel--json-encode data))
            (t data))
           'utf-8))
         (url-request-extra-headers
          `(("Content-Type" . ,content-type)
            ("Accept" . "application/json")
            ,@extra-headers))
         (url-mime-accept-string "application/json")
         (buf (url-retrieve-synchronously url 'silent)))
    (unwind-protect
        (if (not (buffer-live-p buf))
            (list :status nil :body nil :raw "")
          (with-current-buffer buf
            (let ((status (bound-and-true-p url-http-response-status))
                  (raw-body "")
                  (parsed nil))
              (when (bound-and-true-p url-http-end-of-headers)
                (goto-char url-http-end-of-headers)
                (setq raw-body (buffer-substring-no-properties (point) (point-max)))
                (condition-case nil
                    (progn
                      (goto-char url-http-end-of-headers)
                      (setq parsed (gptel--json-read)))
                  (error nil)))
              (list :status status :body parsed :raw raw-body))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


;;; ---- Device flow helpers ----

(defun gptel--openai-chatgpt-start-device-auth ()
  "Start the device authorization flow.
Returns a plist with :device_auth_id, :user_code, and :interval."
  (let* ((url (concat gptel--openai-chatgpt-issuer
                      "/api/accounts/deviceauth/usercode"))
         (result (gptel--openai-chatgpt-request
                  url
                  `(:client_id ,gptel--openai-chatgpt-client-id))))
    (unless (eq (plist-get result :status) 200)
      (user-error "Failed to initiate device authorization (HTTP %s): %s"
                  (plist-get result :status)
                  (plist-get result :raw)))
    (let ((body (plist-get result :body)))
      (unless (and (plist-get body :device_auth_id)
                   (plist-get body :user_code))
        (user-error "Unexpected device auth response: %s" (plist-get result :raw)))
      body)))

(defun gptel--openai-chatgpt-poll-device-auth (device-auth-id user-code interval)
  "Poll for device authorization completion.
DEVICE-AUTH-ID and USER-CODE identify the pending auth.
INTERVAL is the base polling interval in seconds.
Returns a plist with :authorization_code and :code_verifier on success."
  (let* ((url (concat gptel--openai-chatgpt-issuer
                      "/api/accounts/deviceauth/token"))
         (poll-interval (max (or interval 5) 1))
         (wait-seconds (+ poll-interval gptel--openai-chatgpt-polling-safety-margin))
         (deadline (+ (float-time) gptel--openai-chatgpt-polling-timeout))
         (done nil)
         (auth-result nil))
    (while (not done)
      (when (> (float-time) deadline)
        (user-error "Device authorization timed out after %d seconds"
                    gptel--openai-chatgpt-polling-timeout))
      (let* ((result (gptel--openai-chatgpt-request
                      url
                      `(:device_auth_id ,device-auth-id
                        :user_code ,user-code)))
             (status (plist-get result :status)))
        (cond
         ((eq status 200)
          (setq auth-result (plist-get result :body)
                done t))
         ((memq status '(403 404))
          ;; Authorization still pending — wait and retry
          (unless (sit-for wait-seconds)
            (user-error "Device authorization cancelled by user")))
         (t
          (user-error "Device authorization failed (HTTP %s): %s"
                      status (plist-get result :raw))))))
    auth-result))

(defun gptel--openai-chatgpt-exchange-authorization-code (code code-verifier)
  "Exchange authorization CODE and CODE-VERIFIER for OAuth tokens.
Returns the token response plist."
  (let* ((url (concat gptel--openai-chatgpt-issuer "/oauth/token"))
         (body (gptel--openai-chatgpt-url-encode-params
                `(("grant_type" . "authorization_code")
                  ("code" . ,code)
                  ("redirect_uri" . "https://auth.openai.com/deviceauth/callback")
                  ("client_id" . ,gptel--openai-chatgpt-client-id)
                  ("code_verifier" . ,code-verifier))))
         (result (gptel--openai-chatgpt-request
                  url body "application/x-www-form-urlencoded")))
    (unless (eq (plist-get result :status) 200)
      (user-error "Token exchange failed (HTTP %s): %s"
                  (plist-get result :status)
                  (plist-get result :raw)))
    (plist-get result :body)))


;;; ---- Refresh helper ----

(defun gptel--openai-chatgpt-refresh-token (backend)
  "Refresh the OAuth token for BACKEND.
Updates the backend token slot and saves to disk."
  (let* ((old-token (gptel-openai-chatgpt-token backend))
         (refresh-tok (plist-get old-token :refresh_token)))
    (unless refresh-tok
      (user-error "No refresh token available.  Please run M-x gptel-openai-chatgpt-login"))
    (let* ((url (concat gptel--openai-chatgpt-issuer "/oauth/token"))
           (body (gptel--openai-chatgpt-url-encode-params
                  `(("grant_type" . "refresh_token")
                    ("refresh_token" . ,refresh-tok)
                    ("client_id" . ,gptel--openai-chatgpt-client-id))))
           (result (gptel--openai-chatgpt-request
                    url body "application/x-www-form-urlencoded")))
      (unless (eq (plist-get result :status) 200)
        (user-error "Token refresh failed (HTTP %s): %s"
                    (plist-get result :status)
                    (plist-get result :raw)))
      (let* ((new-tokens (plist-get result :body))
             (expires-in (or (plist-get new-tokens :expires_in) 3600))
             (merged
              (list :access_token (plist-get new-tokens :access_token)
                    :refresh_token (or (plist-get new-tokens :refresh_token) refresh-tok)
                    :id_token (or (plist-get new-tokens :id_token)
                                  (plist-get old-token :id_token))
                    :expires_in expires-in
                    :expires_at (+ (float-time) expires-in)
                    :account_id (or (gptel--openai-chatgpt-extract-account-id new-tokens)
                                    (plist-get old-token :account_id)))))
        (gptel--openai-chatgpt-save-token merged)
        (setf (gptel-openai-chatgpt-token backend) merged)
        merged))))


;;; ---- Token ensure helper ----

(defun gptel--openai-chatgpt-ensure-token (backend)
  "Ensure BACKEND has a valid token, refreshing if needed.
Returns the token plist.  Signals `user-error' if no token exists."
  (let ((token (or (gptel-openai-chatgpt-token backend)
                   (let ((restored (gptel--openai-chatgpt-restore-token)))
                     (when restored
                       (setf (gptel-openai-chatgpt-token backend) restored))
                     restored))))
    (unless token
      (user-error "Not logged in to ChatGPT.  Please run M-x gptel-openai-chatgpt-login"))
    (when (< (or (plist-get token :expires_at) 0)
             (+ (float-time) gptel--openai-chatgpt-safety-margin))
      (setq token (gptel--openai-chatgpt-refresh-token backend)))
    token))


;;; ---- Header function ----

(defun gptel--openai-chatgpt-header ()
  "Return headers for ChatGPT OAuth requests.
Uses the dynamically bound `gptel-backend'."
  (let* ((token (gptel--openai-chatgpt-ensure-token gptel-backend))
         (headers
          `(("Authorization" . ,(concat "Bearer " (plist-get token :access_token)))
            ("originator" . "gptel"))))
    (when-let* ((account-id (plist-get token :account_id)))
      (push (cons "ChatGPT-Account-Id" account-id) headers))
    headers))


;;; ---- Login command ----

(defun gptel--openai-chatgpt-resolve-backend ()
  "Find the active ChatGPT backend instance.
Checks current `gptel-backend' first, then `gptel--known-backends'."
  (cond
   ((and (boundp 'gptel-backend)
         gptel-backend
         (gptel-openai-chatgpt-p gptel-backend))
    gptel-backend)
   ((cl-find-if #'gptel-openai-chatgpt-p
                (mapcar #'cdr gptel--known-backends)))
   (t (user-error "No ChatGPT backend found.  \
Please set one up with `gptel-make-openai-chatgpt' first"))))

;;;###autoload
(defun gptel-openai-chatgpt-login ()
  "Login to ChatGPT Codex via OAuth device flow.

This will prompt you to authorize in a browser and store the token.

In SSH sessions, the URL and code will be displayed for manual entry
instead of attempting to open a browser automatically."
  (interactive)
  (let* ((backend (gptel--openai-chatgpt-resolve-backend))
         (in-ssh (or (getenv "SSH_CLIENT")
                     (getenv "SSH_CONNECTION")
                     (getenv "SSH_TTY"))))
    ;; Step 1: Start device auth
    (pcase-let (((map :device_auth_id :user_code :interval)
                 (gptel--openai-chatgpt-start-device-auth)))
      ;; Step 2: Copy code to clipboard
      (ignore-errors (gui-set-selection 'CLIPBOARD user_code))
      ;; Step 3-5: Prompt user
      (if in-ssh
          (progn
            (message "ChatGPT Device Code: %s (copied to clipboard)" user_code)
            (read-from-minibuffer
             (format "Code %s is copied.  Visit https://auth.openai.com/codex/device \
in your local browser, enter the code, and authorize.  Press ENTER after authorizing. "
                     user_code)))
        (read-from-minibuffer
         (format "Your one-time code %s is copied.  \
Press ENTER to open the authorization page.  \
If your browser does not open, visit https://auth.openai.com/codex/device"
                 user_code))
        (browse-url "https://auth.openai.com/codex/device")
        (read-from-minibuffer "Press ENTER after authorizing in your browser. "))
      ;; Step 6: Poll
      (message "Waiting for authorization...")
      (pcase-let (((map :authorization_code :code_verifier)
                   (gptel--openai-chatgpt-poll-device-auth
                    device_auth_id user_code
                    (if (stringp interval) (string-to-number interval) (or interval 5)))))
        ;; Step 7: Exchange
        (let* ((tokens (gptel--openai-chatgpt-exchange-authorization-code
                        authorization_code code_verifier))
               (expires-in (or (plist-get tokens :expires_in) 3600))
               (full-token
                (list :access_token (plist-get tokens :access_token)
                      :refresh_token (plist-get tokens :refresh_token)
                      :id_token (plist-get tokens :id_token)
                      :expires_in expires-in
                      :expires_at (+ (float-time) expires-in)
                      :account_id (gptel--openai-chatgpt-extract-account-id tokens))))
          ;; Step 8-10: Save and store
          (gptel--openai-chatgpt-save-token full-token)
          (setf (gptel-openai-chatgpt-token backend) full-token)
          ;; Step 11: Success
          (message "Successfully logged in to ChatGPT Codex."))))))


;;; ---- Public constructor ----

;;;###autoload
(cl-defun gptel-make-openai-chatgpt
    (name &key curl-args request-params
          (models gptel--openai-chatgpt-models)
          (header #'gptel--openai-chatgpt-header)
          (host "chatgpt.com")
          (protocol "https")
          (endpoint "/backend-api/codex/responses")
          (stream t))
  "Register a ChatGPT Codex backend for gptel with NAME.

Keyword arguments:

CURL-ARGS (optional) is a list of additional curl arguments.

HEADER (optional) is a function that returns request headers.
Defaults to `gptel--openai-chatgpt-header'.

HOST is the API host, defaults to \"chatgpt.com\".

MODELS is a list of available models.

PROTOCOL is the connection protocol, defaults to \"https\".

ENDPOINT is the API endpoint, defaults to
\"/backend-api/codex/responses\".

REQUEST-PARAMS (optional) is a plist of additional request parameters.

STREAM (optional) enables streaming, defaults to t."
  (declare (indent 1))
  (let* ((url (concat protocol "://" host endpoint))
         (backend (gptel--make-openai-chatgpt
                   :name name
                   :host host
                   :header header
                   :models (gptel--process-models models)
                   :protocol protocol
                   :endpoint endpoint
                   :stream stream
                   :request-params request-params
                   :curl-args curl-args
                   :url url)))
    (setf (alist-get name gptel--known-backends nil nil #'equal) backend)
    backend))

(provide 'gptel-chatgpt-codex)

;;; gptel-chatgpt-codex.el ends here
