---
id: CODE_LAYER-001
type: code-layer-finding
severity: high
source: project/audits/2026-09-05_code_layer_audit.md
---

AWS HTTP transport classifies received responses too early

**Problem:** `Aws.Http.request` and `Aws.Http.signed_request` convert non-2xx
HTTP responses into `Error (Http_error (status, body))`. That makes a received
HTTP response look like a transport/setup failure and forces service adapters to
undo the abstraction. `s3-eio` and `dynamodb-eio` already carry
`reclassify_transport_result` shims so their service-specific error classifiers
can see the response.

**Goal:** Make `aws-eio`'s HTTP layer own request construction, signing,
network I/O, protocol failures, and shared retry policy. Callers above it own
the meaning of the final HTTP status/body.

**Desired contract:**

- `Ok (status, headers, body)` means the peer produced a usable HTTP response,
  regardless of status code.
- `Error _` means there was no usable HTTP response, or the request could not be
  built/signed/sent.
- Retryable statuses can still be retried inside `Aws.Http`; only the final
  received response should be returned to the caller.

**Acceptance criteria:**

- `Aws.Http.request` and `Aws.Http.signed_request` return
  `Ok (status, headers, body)` for received HTTP responses regardless of final
  status.
- `Error (Http_error (status, body))` is no longer used for ordinary received
  non-2xx responses from these functions.
- `s3-eio` and `dynamodb-eio` delete their `reclassify_transport_result` helpers.
- S3 404 and DynamoDB service errors still map to their typed package errors.
- Credential-bootstrap callers of `Aws.Http.request` explicitly classify
  non-2xx STS/IMDS/ECS responses after receiving `Ok`.
- Focused tests pass in `aws-eio`, `s3-eio`, and `dynamodb-eio`.

**Implementation notes:**

- Update the `Aws.Http.request` and `Aws.Http.signed_request` `.mli`
  documentation together so the two functions expose the same response/error
  abstraction.
- Keep existing retry behavior for 429/5xx/known retryable AWS error responses.
- Do not add a compatibility wrapper unless a released external consumer needs
  migration support; these foundation packages are under our control, so break
  callers together.
