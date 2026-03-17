## Answers to external feeback
This document collects answers to `./02-EXTERNAL-FEEDBACK-ON-IDEATION-FEATURE_chatgpt-subscription.md`.

### Avenues

- Avenue 3 sound like a too ambitious project, massive changes to central files in gptel will likely not be accepted upstream.

### Regarding: Critical Analysis of the Reference Implementation (`codex.ts`)
1. Yes, let's do headless (like gptel-gh-login).
2. OK
3. This might be useful (extracted from a prototype implementation I was working on, but avoid duplication, and make sure e.g. gptel-gh.el isn't doing something very similar already).:
```elisp
(defun gptel--openai-chatgpt-base64url-decode (input)
  "Decode base64url INPUT and return a decoded string."
  (let* ((base64 (replace-regexp-in-string "_" "/"
                   (replace-regexp-in-string "-" "+" input)))
         (padding (mod (- 4 (mod (length base64) 4)) 4))
         (padded (concat base64 (make-string padding ?=))))
    (decode-coding-string (base64-decode-string padded) 'utf-8 t)))

(defun gptel--openai-chatgpt-jwt-payload (jwt)
  "Return decoded JWT payload string from JWT, or nil."
  (when (and (stringp jwt) (string-match-p "\\.`[^.]+\\.[^.]+\\.[^.]+\\'" jwt))
    (condition-case nil
        (gptel--openai-chatgpt-base64url-decode (cadr (split-string jwt "\\.")))
      (error nil))))

(defun gptel--openai-chatgpt-extract-account-id (token)
  "Extract ChatGPT account id from OAuth TOKEN payload."
  (let* ((payload (or (gptel--openai-chatgpt-jwt-payload (plist-get token :id_token))
                      (gptel--openai-chatgpt-jwt-payload (plist-get token :access_token)))))
    (when payload
      (or (when (string-match "\"chatgpt_account_id\"[ \t\n\r]*:[ \t\n\r]*\"\\([^\"]+\\)\"" payload)
            (match-string 1 payload))
          (when (string-match "\"organizations\"[ \t\n\r]*:[ \t\n\r]*\\[[^]]*\"id\"[ \t\n\r]*:[ \t\n\r]*\"\\([^\"]+\\)\"" payload)
            (match-string 1 payload))))))

(defun gptel--openai-chatgpt-login-prompt (user-code)
  "Return minibuffer instructions for ChatGPT device USER-CODE."
  (format
   (concat "Enter code %s at %s/codex/device. "
           "Approve it in your browser, then return to Emacs and press ENTER. "
           "If the browser opens a callback page afterward, you can ignore it and close the tab. ")
   user-code gptel--openai-chatgpt-issuer))

(defun gptel--openai-chatgpt-refresh-token (backend)
  "Refresh OAuth token for ChatGPT BACKEND."
  (let* ((token (gptel-openai-chatgpt-token backend))
         (refresh-token (plist-get token :refresh_token)))
    (unless refresh-token
      (user-error "Missing ChatGPT refresh token. Run `M-x gptel-openai-chatgpt-login'"))
    (let* ((resp (gptel--openai-chatgpt-request
                  (concat gptel--openai-chatgpt-issuer "/oauth/token")
                  `(("grant_type" . "refresh_token")
                    ("refresh_token" . ,refresh-token)
                    ("client_id" . ,gptel-openai-chatgpt-client-id))
                  nil t))
           (status (plist-get resp :status))
           (body (plist-get resp :body)))
      (unless (and (eql status 200) body)
        (user-error "Failed to refresh ChatGPT token (HTTP %s): %s"
                    status
                    (or (plist-get body :error)
                        (plist-get body :error_description)
                        (plist-get resp :raw))))
      (unless (plist-get body :refresh_token)
        (plist-put body :refresh_token refresh-token))
      (plist-put body :account_id (or (gptel--openai-chatgpt-extract-account-id body)
                                      (plist-get token :account_id)))
      (plist-put body :expires_at
                 (+ (float-time) (or (plist-get body :expires_in) 3600)
                    (- gptel--openai-chatgpt-safety-margin)))
      (setf (gptel-openai-chatgpt-token backend) body)
      (gptel--openai-chatgpt-save-token body)
      body)))

(defun gptel--openai-chatgpt-ensure-token (&optional backend)
  "Ensure ChatGPT OAuth token exists and is valid for BACKEND."
  (let* ((backend (gptel--openai-chatgpt-backend backend))
         (token (or (gptel-openai-chatgpt-token backend)
                    (gptel--openai-chatgpt-restore-token))))
    (unless token
      (if noninteractive
          (user-error "No ChatGPT token found. Run `M-x gptel-openai-chatgpt-login' first")
        (gptel-openai-chatgpt-login backend)
        (setq token (gptel-openai-chatgpt-token backend))))
    (setf (gptel-openai-chatgpt-token backend) token)
    (when (<= (or (plist-get token :expires_at) 0)
              (+ (float-time) gptel--openai-chatgpt-safety-margin))
      (setq token (gptel--openai-chatgpt-refresh-token backend)))
    token))
```

### Regarding: Decisions to Make / Questions to Answer

1. Do you recommend unifying OAuth at this point in time? Is it feasible? If we do so, I think we should aim for different files for tokens for different providers.
2. ~0.5 second freeze sounds not too bad for a rare event as token expiration mid-flight. Unless there is an elegant to avoid it altogether that doesn't require massive rewrite and/or complicated implementation.
3. read-from-minibuffer is fine (even wanted)
4. I believe the current practice is that gptel contains per-provider hard-coded lists of available models. So let's keep that tradition. The user can always fork gptel and run his/her own branch with new models added for a few days until upstream has updated the list.


### Regarding: "Final Recommendation" 

The recommendation of going with Avenue 2 sounds appealing, what is your assessment?
