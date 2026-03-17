# Revised PRD And Implementation Plan: ChatGPT Plus/Pro Codex Support for `gptel`

## Original motivation

`gptel` already supports:

- OpenAI API key based access via `gptel-openai.el`
- OpenAI Responses API via `gptel-openai-responses.el`
- GitHub Copilot subscription access via `gptel-gh.el`

The missing capability is support for OpenAI's consumer ChatGPT Plus/Pro subscription for the Codex endpoint:

- `https://chatgpt.com/backend-api/codex/responses`

This endpoint is not the classic OpenAI API:

- it uses OAuth, not an API key
- it uses the Responses API wire format, not Chat Completions
- it may require the `ChatGPT-Account-Id` header for organization-backed subscriptions

The goal is to let a `gptel` user authenticate once with their ChatGPT subscription and then use Codex-backed models in the same way they can already use GitHub Copilot today.

## Refined implementation goals

We are deliberately choosing a minimal, surgical implementation.

### Primary goals

- Add support for ChatGPT Plus/Pro OAuth login for Codex.
- Use the existing Responses API implementation instead of re-implementing request/response parsing.
- Add a new public constructor:
  - `gptel-make-openai-chatgpt`
- Allow explicit login and implicit token refresh during requests.
- Support these initial models:
  - `gpt-5.4`
  - `gpt-5.3-codex`
- Store ChatGPT OAuth tokens in their own cache files, separate from GitHub Copilot tokens.

### Secondary goals

- Keep the patch easy to review upstream.
- Avoid modifying `gptel` core request FSM or introducing a general auth framework.
- Avoid immediate refactoring of `gptel-gh.el` or `gptel-bedrock.el`.

### Explicit non-goals for this patch

- No generic OAuth abstraction shared by all providers.
- No attempt to unify ChatGPT auth with GitHub Copilot auth.
- No multi-organization account selection UI.
- No browser callback/local HTTP server flow.
- No automated tests yet if manual traces are not available.

## Chosen design

Implement a dedicated backend in a new file:

- `gptel-chatgpt-codex.el`

This backend should:

- inherit from `gptel-openai-responses`
- own only ChatGPT/Codex-specific concerns:
  - OAuth device flow
  - token persistence
  - token refresh
  - Codex-specific headers
  - Codex-specific model list
  - Codex-specific host/endpoint defaults

This avoids two bad alternatives:

- forcing ChatGPT OAuth into `gptel-openai.el`, which is the wrong protocol layer
- building a broad generic OAuth framework before the ChatGPT/Codex integration is proven

## User-facing API

After implementation, the intended user story is:

```elisp
(require 'gptel-chatgpt-codex)

(gptel-make-openai-chatgpt "ChatGPT-Codex")

;; Optional explicit one-time login:
(gptel-openai-chatgpt-login)
```

Request-time behavior should be:

- if the user has already logged in, requests work normally
- if the token is expired, it may be refreshed synchronously during request setup
- if no token exists, requests must fail immediately with a clear `user-error` instructing the user to run `M-x gptel-openai-chatgpt-login`

This is intentional.

Reason:

- `gptel` evaluates backend headers synchronously immediately before sending requests
- a full device login flow from inside the header function would freeze Emacs for too long
- implicit refresh is acceptable because it is a short single-request operation

## Storage decisions

ChatGPT tokens should be stored separately from GitHub Copilot tokens.

Proposed defaults:

- `~/.emacs.d/.cache/chatgpt-codex/token`

Optional future split if needed:

- `~/.emacs.d/.cache/chatgpt-codex/device-token`
- `~/.emacs.d/.cache/chatgpt-codex/session-token`

For the first patch, use one token file containing the OAuth token plist, including:

- `:access_token`
- `:refresh_token`
- `:id_token`
- `:expires_in`
- `:expires_at`
- `:account_id`

File writing should match existing `gptel-gh.el` behavior:

- create parent directories as needed
- serialize via `prin1-to-string`
- write UTF-8 with Unix line endings

## Protocol decisions

### Auth flow

Use the headless device flow only.

The flow should follow the reference implementation:

1. POST to:
   - `https://auth.openai.com/api/accounts/deviceauth/usercode`
2. Receive:
   - `device_auth_id`
   - `user_code`
   - `interval`
3. Prompt the user to visit:
   - `https://auth.openai.com/codex/device`
4. Poll:
   - `https://auth.openai.com/api/accounts/deviceauth/token`
5. On success, receive:
   - `authorization_code`
   - `code_verifier`
6. Exchange that code at:
   - `https://auth.openai.com/oauth/token`
7. Save resulting OAuth tokens

### Request protocol

All model requests should use the existing Responses API backend implementation.

Default request target:

- host: `chatgpt.com`
- endpoint: `/backend-api/codex/responses`

### Request headers

The backend should send:

```elisp
(defun gptel--openai-chatgpt-header ()
  "Return headers for ChatGPT OAuth requests."
  (let* ((token (gptel--openai-chatgpt-ensure-token))
         (headers
          `(("Authorization" . ,(concat "Bearer " (plist-get token :access_token)))
            ("originator" . "gptel"))))
    (when-let* ((account-id (plist-get token :account_id)))
      (push (cons "ChatGPT-Account-Id" account-id) headers))
    headers))
```

Notes:

- `Authorization` is always required
- `originator: gptel` should always be sent
- `ChatGPT-Account-Id` is conditional on token contents

## Files to create

### 1. `/work/gptel-chatgpt-codex.el`

This is the main implementation file.

It should contain:

- requires
- model definitions
- backend struct
- cache file customizations
- token persistence helpers
- account-id extraction helpers
- device flow helpers
- refresh helpers
- header builder
- login command
- constructor
- `provide`

## Files to edit

### 2. `/work/gptel-request.el`

Update documentation only.

Reason:

- the docstring section that enumerates backend constructor functions should mention the new public constructor
- this keeps user-facing documentation accurate

Specifically update the list near the `gptel-backend` documentation block to include:

- `gptel-make-openai-chatgpt`

No behavioral changes should be made here.

### 3. `/work/gptel.el`

Only edit if there is a central commentary/doc section listing supported backends and constructors.

If such a list exists and mentions constructors like `gptel-make-openai` and `gptel-make-gh-copilot`, add the new constructor.

If no clear user-facing list needs updating, skip this file.

### 4. `/work/test/` submodule or related test scaffolding

Do not modify now unless there are obvious fixtures or trace directories that should be prepared.

Current plan is to defer test additions until manual traces exist.

## Detailed implementation plan for `gptel-chatgpt-codex.el`

### 1. File header and requirements

Add standard file boilerplate and require:

- `cl-lib`
- `map`
- `browse-url`
- `gptel-request`
- `gptel-openai-responses`

Reason:

- the backend must inherit from `gptel-openai-responses`
- auth helpers need `gptel--url-retrieve`
- login needs `browse-url`

### 2. Model list

Add a constant:

- `gptel--openai-chatgpt-models`

Initial contents:

- `gpt-5.4`
- `gpt-5.3-codex`

Each model entry should follow the same property structure used elsewhere in `gptel`:

- `:description`
- `:capabilities`
- `:mime-types`
- `:context-window`
- `:input-cost`
- `:output-cost`
- `:cutoff-date`

Requirements for the initial model list:

- both models must include Responses API capability
- both models should have zero cost because the subscription includes access
- use conservative values for context window and capabilities unless verified by traces

If exact metadata is uncertain, document this in comments and prefer consistency with the rest of `gptel`.

### 3. Backend struct

Define a new struct inheriting from `gptel-openai-responses`.

Proposed shape:

```elisp
(cl-defstruct (gptel-openai-chatgpt
               (:include gptel-openai-responses)
               (:copier nil)
               (:constructor gptel--make-openai-chatgpt))
  token)
```

Reason:

- inheriting from `gptel-openai-responses` gives the correct request builder and parser
- only one backend-specific slot is needed initially: cached token plist

Do not add unnecessary slots yet.

### 4. Defcustoms and constants

Add provider-specific constants/customs:

- `gptel--openai-chatgpt-issuer`
  - `"https://auth.openai.com"`
- `gptel-openai-chatgpt-client-id`
  - `"app_EMoamEEZ73f0CkXaXp7hrann"`
- `gptel-openai-chatgpt-token-file`
  - default `~/.emacs.d/.cache/chatgpt-codex/token`
- `gptel--openai-chatgpt-safety-margin`
  - default around 30 seconds or 60 seconds
- possibly `gptel--openai-chatgpt-polling-safety-margin`
  - default a few seconds, mirroring the reference implementation behavior

Reason:

- all provider-specific values should be centralized and easy to inspect

### 5. Persistence helpers

Implement:

- `gptel--openai-chatgpt-save-token`
- `gptel--openai-chatgpt-restore-token`

Behavior should mirror `gptel--gh-save` and `gptel--gh-restore` in `gptel-gh.el`.

Requirements:

- support files created on different line endings
- preserve plist data exactly
- create parent directory before writing

### 6. JWT/account-id helpers

Implement:

- `gptel--openai-chatgpt-base64url-decode`
- `gptel--openai-chatgpt-jwt-payload`
- `gptel--openai-chatgpt-extract-account-id`

Important implementation note:

- do not use fragile raw regex parsing of JSON if `json-parse-string` or `gptel--json-read-string` can be used safely
- Base64URL decoding must restore omitted `=` padding before calling `base64-decode-string`
- after base64 decoding, decode the bytes as UTF-8 before JSON parsing
- parse JWT payload into a plist/object and check these fields in order:
  - `chatgpt_account_id`
  - `https://api.openai.com/auth.chatgpt_account_id`
  - first `organizations[].id`

Reason:

- the reference implementation supports more than one claim location
- JSON parsing is less brittle than regex extraction

Required decoder shape:

```elisp
(defun gptel--openai-chatgpt-base64url-decode (str)
  "Decode Base64URL string STR, adding padding if necessary."
  (let* ((str (replace-regexp-in-string "-" "+" str))
         (str (replace-regexp-in-string "_" "/" str))
         (pad (% (length str) 4)))
    (when (> pad 0)
      (setq str (concat str (make-string (- 4 pad) ?=))))
    (decode-coding-string (base64-decode-string str) 'utf-8 t)))
```

### 7. Low-level POST helper for form or JSON requests

`gptel--url-retrieve` always sends JSON content-type, so ChatGPT auth endpoints likely need a local helper with custom content-type support.

Implement a provider-local request helper, for example:

- `gptel--openai-chatgpt-request`

This helper must support:

- POST with JSON body
- POST with `application/x-www-form-urlencoded`
- custom headers
- synchronous response parsing
- access to HTTP status and response body

Proposed return shape:

- `(:status 200 :body <plist> :raw <string>)`

Reason:

- device flow endpoints and `/oauth/token` use different body formats
- reusing `gptel--url-retrieve` directly is too rigid for this provider

Critical implementation constraints:

- `url-retrieve-synchronously` does not signal HTTP 4xx/5xx as Lisp errors
- the helper must inspect HTTP status explicitly
- the helper must parse headers and body from the returned buffer
- the helper must kill the response buffer before returning

Recommended implementation details:

- use `url-http-response-status` when available
- use `url-http-end-of-headers` to move to the response body
- parse the body as JSON when possible
- preserve raw body text for diagnostics when JSON parsing fails

For form-encoded requests, do not manually concatenate query strings.

Requirement:

- use `url-build-query-string` for `application/x-www-form-urlencoded` POST bodies

Reason:

- refresh tokens and authorization codes must be URL-escaped safely

### 8. Device flow helpers

Implement:

- `gptel--openai-chatgpt-start-device-auth`
- `gptel--openai-chatgpt-poll-device-auth`
- `gptel--openai-chatgpt-exchange-authorization-code`
- `gptel--openai-chatgpt-login-prompt`

#### `gptel--openai-chatgpt-start-device-auth`

Responsibilities:

- POST JSON to `/api/accounts/deviceauth/usercode`
- send client id
- parse returned `device_auth_id`, `user_code`, and `interval`
- validate response shape

#### `gptel--openai-chatgpt-poll-device-auth`

Responsibilities:

- repeatedly POST JSON to `/api/accounts/deviceauth/token`
- use returned `interval`
- treat HTTP 403 and 404 as “authorization still pending”
- sleep between polls with safety margin
- fail on unexpected statuses
- return `authorization_code` and `code_verifier` once ready

#### `gptel--openai-chatgpt-exchange-authorization-code`

Responsibilities:

- POST form-encoded body to `/oauth/token`
- fields:
  - `grant_type=authorization_code`
  - `code`
  - `redirect_uri=https://auth.openai.com/deviceauth/callback`
  - `client_id=<client id>`
  - `code_verifier=<verifier>`
- parse token response

#### `gptel--openai-chatgpt-login-prompt`

Responsibilities:

- produce the exact minibuffer guidance shown to the user
- reference:
  - `https://auth.openai.com/codex/device`
- state that the user should press ENTER after authorizing

### 9. Login command

Implement the public interactive command:

- `gptel-openai-chatgpt-login`

Behavior:

1. resolve which ChatGPT backend instance to use
2. start device auth
3. copy `user_code` to clipboard when possible
4. optionally open the device URL in a browser
5. prompt with `read-from-minibuffer`
6. poll until authorization succeeds
7. exchange auth code for tokens
8. compute:
   - `:expires_at`
   - `:account_id`
9. save token
10. store token on backend instance
11. display success message

Backend resolution should mirror `gptel-gh-login`:

- if current `gptel-backend` is a ChatGPT backend, use it
- else search `gptel--known-backends`
- else raise a user error telling the user to call `gptel-make-openai-chatgpt` first

SSH handling:

- follow the same general behavior as `gptel-gh-login`
- do not rely on browser auto-open in SSH

### 10. Refresh helper

Implement:

- `gptel--openai-chatgpt-refresh-token`

Behavior:

- require a refresh token
- POST form-encoded data to `/oauth/token`
- fields:
  - `grant_type=refresh_token`
  - `refresh_token`
  - `client_id`
- preserve old refresh token if the response omits a new one
- recompute `:expires_at`
- recompute or preserve `:account_id`
- save token to disk
- update backend slot

### 11. Token ensure helper

Implement:

- `gptel--openai-chatgpt-ensure-token`

Behavior:

1. resolve the backend instance
2. load token from backend slot or disk
3. if no token exists:
   - signal a user-error with clear instructions to run `M-x gptel-openai-chatgpt-login`
4. if token is expired or within safety margin:
   - refresh synchronously
5. return valid token

Reason:

- this function will be called from the header function on every request
- it is the central place for request-time token validation and token refresh
- it must not start a full device-flow login from inside request dispatch

### 12. Header function

Implement exactly:

- `gptel--openai-chatgpt-header`

It should:

- call `gptel--openai-chatgpt-ensure-token` with the dynamically bound `gptel-backend`
- emit:
  - `Authorization`
  - `originator`
  - optional `ChatGPT-Account-Id`

Do not use `:key` based auth for this backend.

Reason:

- the auth data is more than a single string
- the provider needs conditional extra headers
- multiple ChatGPT backend instances must use their own token slot/state

Critical implementation note:

- `gptel-request.el` dynamically binds `gptel-backend` immediately before calling the backend header function
- the header function must use that dynamic binding to ensure it operates on the active backend instance

Expected shape:

```elisp
(defun gptel--openai-chatgpt-header ()
  "Return headers for ChatGPT OAuth requests."
  (let* ((token (gptel--openai-chatgpt-ensure-token gptel-backend))
         (headers
          `(("Authorization" . ,(concat "Bearer " (plist-get token :access_token)))
            ("originator" . "gptel"))))
    (when-let* ((account-id (plist-get token :account_id)))
      (push (cons "ChatGPT-Account-Id" account-id) headers))
    headers))
```

### 13. Public constructor

Implement the autoloaded public constructor:

- `gptel-make-openai-chatgpt`

Suggested signature:

```elisp
(cl-defun gptel-make-openai-chatgpt
    (name &key curl-args request-params
          (models gptel--openai-chatgpt-models)
          (header #'gptel--openai-chatgpt-header)
          (host "chatgpt.com")
          (protocol "https")
          (endpoint "/backend-api/codex/responses")
          (stream t))
```

Implementation requirements:

- construct a `gptel-openai-chatgpt` backend via `gptel--make-openai-chatgpt`
- pass:
  - name
  - host
  - header
  - processed models
  - protocol
  - endpoint
  - stream
  - request params
  - curl args
  - url
- register in `gptel--known-backends`
- return backend instance

Reason:

- the constructor should look and feel like existing backend constructors
- the defaults should already be correct for Codex

### 14. Backend URL

The backend URL can be static:

- `https://chatgpt.com/backend-api/codex/responses`

No dynamic endpoint switching is needed in this backend.

### 15. `provide`

End file with:

- `(provide 'gptel-chatgpt-codex)`

## Documentation changes in existing files

### `gptel-request.el`

Update the constructor list in the backend documentation block:

- add `gptel-make-openai-chatgpt`

If there is a sample config section that is an obvious fit, add a short example only if it remains concise.

### Optional commentary updates elsewhere

If `gptel.el` or another main commentary section enumerates supported providers, add:

- ChatGPT Codex via ChatGPT Plus/Pro OAuth

Do not add long prose unless the file already contains equivalent provider summaries.

## Implementation order

The junior developer should implement in this order:

1. Create `gptel-chatgpt-codex.el` with boilerplate, requires, constants, defcustoms, model list, struct, and constructor stub.
2. Add persistence helpers.
3. Add account-id extraction helpers.
4. Add provider-local HTTP helper for JSON/form requests.
5. Add device flow helpers.
6. Add refresh helper.
7. Add ensure-token helper.
8. Add header function.
9. Add interactive login command.
10. Wire constructor into `gptel--known-backends`.
11. Update documentation in `gptel-request.el`.
12. Byte-compile or load the file to catch syntax errors.
13. Perform manual verification.

## Manual verification checklist

After implementation, verify at minimum:

### Basic setup

- `(require 'gptel-chatgpt-codex)` loads without errors
- `(gptel-make-openai-chatgpt "ChatGPT-Codex")` registers a backend
- backend appears in `gptel--known-backends`

### Login flow

- explicit `M-x gptel-openai-chatgpt-login` works
- token file is created
- saved token contains expected keys
- account id is extracted when available

### Implicit login

- with no token file present, sending a request fails immediately with a clear error telling the user to run `M-x gptel-openai-chatgpt-login`

### Request behavior

- non-streaming request works
- streaming request works
- request sends `Authorization`
- request sends `originator: gptel`
- request sends `ChatGPT-Account-Id` only when available

### Tool behavior

- tool call request works in non-streaming mode
- tool call request works in streaming mode

### Refresh behavior

- expired token causes synchronous refresh
- refresh preserves old `refresh_token` if server omits a new one
- refresh updates saved token on disk

## Logging and trace capture plan

Once basic manual verification succeeds:

1. set:
   - `(setq gptel-log-level 'debug)`
2. capture traces for:
   - streaming, no tools
   - non-streaming, no tools
   - streaming, with tools
   - non-streaming, with tools
3. redact secrets:
   - access tokens
   - refresh tokens
   - account ids if needed
4. use those traces later to create tests in the `test/` submodule

## Risks and mitigations

### Risk: auth endpoints may require non-JSON content types

Mitigation:

- implement a provider-local HTTP helper instead of forcing `gptel--url-retrieve`

### Risk: account-id claim location varies

Mitigation:

- check all three known claim locations
- preserve previous `account_id` on refresh if the new token omits it

### Risk: synchronous refresh briefly blocks Emacs

Mitigation:

- accept this for the first patch
- keep logic simple and localized

### Risk: full device login from request path would freeze Emacs

Mitigation:

- do not implement implicit login in `gptel--openai-chatgpt-ensure-token`
- require explicit login when no token exists

### Risk: model metadata may not be exact

Mitigation:

- keep initial model list small
- use conservative metadata
- revise after manual traces

### Risk: future upstream work may prefer a shared auth abstraction

Mitigation:

- keep this backend small and self-contained so it can later be refactored or extracted

## Out-of-scope cleanup items to defer

- extracting shared token read/write helpers from `gptel-gh.el`
- building a generic OAuth module
- normalizing `response-api` vs `responses-api` capability naming across existing files
- adding organization selection UI
- supporting browser callback flow
- adding additional ChatGPT Codex models

## Definition of done

This work is complete when:

- `gptel-chatgpt-codex.el` exists and loads
- `gptel-make-openai-chatgpt` is public and usable
- `gptel-openai-chatgpt-login` is public and usable
- the backend authenticates via ChatGPT device flow
- the backend successfully sends requests to `/backend-api/codex/responses`
- both `gpt-5.4` and `gpt-5.3-codex` can be selected
- explicit login works and request-time refresh works
- manual verification succeeds for streaming, non-streaming, and tool-call scenarios
