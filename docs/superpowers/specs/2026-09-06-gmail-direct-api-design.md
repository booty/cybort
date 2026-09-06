# Gmail Direct API Connector Design

**Status:** Implemented and offline-verified; not authenticated/live-verified
(Gmail remains experimental)

**Date:** 2026-09-06

**Decision:** [ADR 0005](../../adr/0005-gmail-direct-api-and-external-oauth-bootstrap.md)

**Implementation:** [Task plan](../plans/2026-09-06-gmail-direct-api.md)

The user requested an autonomous design and implementation plan, without human
approval checkpoints. The implementation now follows this design; the separate
authenticated release gate has not been run because no authorized account was
available for this task.

## Decision and rationale

Replace the implementation behind `adapter = "gmail"` with direct Gmail REST
requests through Cybort's existing `HttpClient`. Add no gems. Use Google's
`gcloud` CLI only as an external, one-time OAuth bootstrap tool. Cybort reads an
explicit per-instance `authorized_user` JSON credential file, exchanges its
refresh token itself, then calls Gmail over HTTPS. Neither `gws` nor `gcloud`
is installed, resolved, version-checked, or executed by collection.

This is the smallest maintenance surface for the existing application: three
request shapes (token, list, get), existing JSON parsing, and an HTTP boundary
that already supports form posts, response limits, injected transports, and
monotonic deadlines. Browser authorization remains delegated to a maintained
Google tool. There is no new callback server, keychain integration, general
Google authentication framework, or credential writer in Cybort.

### Alternatives considered

| Approach | Benefit | Cost in this repository | Decision |
|---|---|---|---|
| Direct Gmail REST with existing `HttpClient` | Reuses transport, fixtures, deadlines, and error boundary; no gems | Own a small refresh request and Gmail JSON contract | Selected |
| `google-apis-gmail_v1` plus `googleauth` | Google-maintained service methods, typed responses, refresh support | Adds generated client/core/auth dependencies and another transport/configuration boundary for three operations | Viable, but more integration surface here |
| Direct REST plus `googleauth` only | Delegates refresh and credential parsing | Still needs Gmail REST code and two independently configured HTTP paths | Not enough simplification for this slice |
| Run `gcloud` during every fetch | Delegates token refresh | Retains process/auth-context coupling and executable preflight; mailbox access still needs Gmail API calls | Setup only |
| IMAP through Ruby libraries | Mature mail protocol clients | Changes query and identity semantics, MIME handling, and authentication; Google IMAP OAuth uses a [broader mail scope][imap-auth] | Not selected |
| Own desktop OAuth browser flow | Could remove all setup CLI requirements | Adds loopback listener, state/PKCE, browser UX, token persistence and recovery | Deferred |

The Ruby client is a reasonable default in a new Google-heavy application.
Cybort already has the small HTTP primitives needed here, and this change must
not grow into support for all Google APIs. The recommendation is a
repository-specific engineering judgment, not a claim that Ruby libraries are
unmaintained. See the [official Ruby client overview][ruby-client] and
[Google authentication implementation][ruby-auth].

## Scope and compatibility

- Replace `Adapters::Gmail` in place; do not introduce `gmail_v2`, keep a
  fallback to `gws`, or rewrite other adapters.
- Preserve configured instance IDs, Gmail canonical message IDs, normalization,
  cache planning, retention, and per-instance transactions. No SQLite migration.
- Keep one bounded list page and sequential metadata gets. This remains a
  sample, not a mailbox synchronization or a current-snapshot replacement.
- Keep the limit of 1–500 messages and the five-minute fetch budget. A limit of
  200 is supported but is an upper bound, not a guarantee of 200 returned items.
- Add an explicit credential-file choice per instance and an optional
  `include_spam_trash` flag. No automatic account discovery or account switching.
- Do not add sending, label changes, read/unread changes, full MIME content,
  attachments, pagination, batching, parallel gets, retries, history sync,
  dashboards, background jobs, or a new CLI command.
- Retain generic `CommandRunner`, `DependencyChecker`, and registry support.
  Their coverage moves to synthetic command adapters where it currently assumes
  that Gmail needs an executable.

## Authentication and setup

The API is Gmail, not a separate "gcloud Gmail API." Google Cloud provides the
project, OAuth client, and consent configuration. `gcloud auth login` and its
default Cloud scopes alone do not grant Gmail access. Google's ADC login
command supports a custom OAuth client and explicit non-Cloud scopes.
[Documentation][adc-login]

### User procedure to publish with the implementation

1. Select/create a personal Google Cloud project and
   [enable the Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
2. Configure [Google Auth Platform](https://console.cloud.google.com/auth/overview):
   branding, audience, and the Gmail read-only scope. For an external app in
   Testing, add the intended Gmail account as a test user.
3. Create a **Desktop app** OAuth client on the
   [Clients page](https://console.cloud.google.com/auth/clients), and download
   its JSON. This client JSON is setup input; it is not the runtime credential
   file and does not contain a user's refresh token.
4. Install the [Google Cloud CLI][gcloud-install] if absent. Run the following
   in the user's terminal after placing the downloaded client JSON at the
   example path. These commands are documentation, not actions taken by this
   design task:

   ```sh
   mkdir -p "$HOME/.cybort/google-auth/jer_gmail"
   chmod 700 "$HOME/.cybort/google-auth/jer_gmail"
   CLOUDSDK_CONFIG="$HOME/.cybort/google-auth/jer_gmail" \
     gcloud auth application-default login \
       --client-id-file="$HOME/Downloads/cybort-google-client.json" \
       --scopes=https://www.googleapis.com/auth/gmail.readonly
   chmod 600 "$HOME/.cybort/google-auth/jer_gmail/application_default_credentials.json"
   ```

5. Authorize the intended account in Google's browser consent screen. Configure
   `credentials_file` to the generated file, preserving `instances.jer_gmail`.
   Then collect normally. A future login for another mailbox uses another
   directory and instance ID.

`CLOUDSDK_CONFIG` separates bootstrap state from the user's normal Cloud CLI
directory; a named `gcloud --configuration` alone is not the credential-file
isolation contract. Verify the generated path during the live release gate.
Re-running ADC login replaces that directory's ADC file; do it only to
reauthorize that same mailbox. Cybort uses only the explicitly configured file,
never ambient ADC discovery, `GOOGLE_APPLICATION_CREDENTIALS`, metadata servers,
or a `gws` credential cache. [Cloud CLI configurations][gcloud-config]

OAuth uses `https://www.googleapis.com/auth/gmail.readonly`. The narrower
`gmail.metadata` scope cannot support the configured Gmail search query.
[Gmail list contract][gmail-list] Gmail read-only is classified as a restricted
scope; setup must explain Google's applicable consent/verification requirements
and Workspace administrator restrictions without promising universal access.
[Scope classifications][gmail-scopes]

External apps left in Testing commonly receive refresh tokens that expire
after seven days for Gmail access. Consent status, password changes, revoked
grants, and administrator policy can require reauthorization. Switching
transport cannot eliminate those Google rules. Document the Testing limitation
before presenting the setup as suitable for unattended use. Do not promise
that changing publishing status alone resolves every verification constraint.
[Token lifetime documentation][oauth-lifetime]

## Configuration contract

The implementation updates `.cybort.example.toml` as the canonical user
template. README links to it rather than copying a configuration block.

| Field | Contract |
|---|---|
| `adapter` | Existing `"gmail"` |
| `credentials_file` | Absolute path or `~/...`; required for remote fetch; no default account |
| `user_id` | Defaults to `"me"`; accepts `me` or an email-shaped string up to 320 UTF-8 bytes |
| `query` | Defaults to `""`; valid UTF-8 string, at most 4,096 bytes, no C0 controls or DEL |
| `include_spam_trash` | Boolean, default `false`; pass explicitly as `includeSpamTrash` |
| `num_items_to_fetch` | Integer 1–500, as today |
| TTL and retention fields | Existing common configuration contracts |

An email-shaped `user_id` has one `@`, nonempty parts, no whitespace, controls,
slashes, backslashes, `?`, or `#`. It does not grant mailbox delegation: Google
must still authorize access. Path segments are percent-encoded. `me` is strongly
preferred because the credential selects the account.

Static validation performs no file reads or network I/O. If provided,
`credentials_file` must be nonblank valid UTF-8, at most 4,096 bytes, without
C0 controls/DEL, and start with `/` or `~/`. No `~otheruser` or current-directory
relative paths. An absent key is permitted through static validation to keep
legacy fresh caches readable. On a remote fetch, omission becomes an explicit
`credentials/missing` source failure. A wrong supplied type/path format remains
a startup configuration error (exit 2).

An unavailable or invalid credential file is a source-readiness failure (exit
1), discovered only in a remote adapter thread. Healthy sources continue, and
fresh cache hits never open the file. For the user's `in:anywhere` query,
document `include_spam_trash = true` when Spam/Trash should be eligible; query
syntax is not a substitute for the API's separate flag. [List guide][list-guide]

## Component contracts

### `GmailCredentials`

`GmailCredentials.load(path:)` reads a file once per remote attempt and returns
a frozen object exposing only `client_id`, `client_secret`, and `refresh_token`.
Its `inspect`/`to_s` are redacted; it has no general credential serialization.

- Open read-only with `NOFOLLOW` and `NONBLOCK` on the supported macOS/POSIX
  platform. Validate the opened descriptor is a regular file owned by the
  effective user, with no group/other permission bits. Reject symlink leaves,
  directories, FIFOs, and oversized input before parsing. Parent-directory
  ownership hardening is outside this local, trusted-configuration slice.
- Read at most 16,385 bytes and reject over 16,384 bytes. Close on every path.
- Require an object with `type == "authorized_user"` and three nonblank
  printable UTF-8 strings: `client_id` ≤ 1,024 bytes, `client_secret` ≤ 4,096
  bytes, `refresh_token` ≤ 8,192 bytes.
- Ignore extra fields; never use a file-supplied token endpoint, executable,
  quota project, access token, or universe domain. The runtime supports the
  standard public Google OAuth/Gmail endpoints only.
- Map file/JSON/encoding/shape errors to fixed `GmailApiError` messages. Never
  include paths, parser text, or file content in errors or fetch metadata.

### `GmailClient`

Create a fresh client inside each remote fetch. Its public interface is:

```ruby
GmailClient.new(http_client:, monotonic_clock:,
                deadline_monotonic:) # state local to this attempt
client.authenticate(credentials:) # returns nil; keeps bearer token in memory
client.list_message_ids(user_id:, query:, limit:, include_spam_trash:) # Array<String>
client.get_message(user_id:, message_id:) # validated Hash
```

The client performs one refresh-token form POST to
`https://oauth2.googleapis.com/token`, using `grant_type=refresh_token` and the
three credential fields. It requires a JSON object, a printable access token
of at most 8,192 bytes, case-insensitive `Bearer` token type, and positive
integer `expires_in`. Track expiry against the injected monotonic clock.
Before each Gmail call, fail as `token_expired` if expiry has been reached.
Do not refresh/retry again during the same bounded attempt; a later collection
gets a new token. If `scope` is present, require a string containing
`gmail.readonly`; absence is allowed because refresh responses may omit an
unchanged scope. A credential file is not proof of its granted scope.
[Google token protocol][oauth-native]

Gmail requests use the `Authorization: Bearer` header, never query tokens.
Hosts and base paths are constants. Do not follow redirects. The client uses
`HttpClient#get` and `post_form`; it does not directly instantiate Net::HTTP.
The shared `HttpClient` intentionally discards error bodies, so classification
uses operation, numeric status, and transport category only. Do not alter the
shared exception contract just to parse Google error descriptions.

### List and detail behavior

List once at `/gmail/v1/users/{userId}/messages` with `maxResults=limit`, optional
nonblank `q`, and the boolean `includeSpamTrash`. Ignore `nextPageToken` and
`resultSizeEstimate`; this is explicitly a first-page sample. Accept missing
`messages` as empty, but reject `null`, a non-array, non-object records, or
invalid IDs in the inspected prefix. Inspect only the first `limit` records,
then deduplicate in first-seen order, preserving current behavior.

For each selected ID, GET `/gmail/v1/users/{userId}/messages/{id}` with
`format=metadata`, repeated `metadataHeaders` for Subject/From/Date/Message-ID,
and `fields=id,threadId,labelIds,snippet,internalDate,payload/headers`.
[Message retrieval contract][gmail-get]

IDs must be valid UTF-8 nonblank printable strings of at most 256 bytes; reject
`.` and `..` and percent-encode them as single path segments. Treat them as
opaque identifiers, not necessarily hexadecimal (existing fixtures use words).
The detail ID must exactly equal the requested ID. Missing optional fields are
accepted; wrong types of present optional fields fail as `invalid_shape`:
payload object, headers array of objects with string name/value, string snippet
and thread ID, array of string label IDs. `null` optional fields count as absent.
Invalid `internalDate` remains a tolerated nil timestamp as today.

### Adapter and bounds

`Adapters::Gmail` owns static configuration, file loading, the five-minute
attempt budget, and normalization. Start the monotonic deadline before loading
credentials. For each HTTP request compute
`request_deadline = min(attempt_deadline, monotonic_now + 30)` and pass it as
`deadline_monotonic`, with the remaining seconds as `timeout_seconds`. Check
deadline before and after requests and before returning success. The shared
transport enforces its streaming/body bounds; do not replace that behavior
with inactivity timeouts alone.

There are at most `2 + num_items_to_fetch` application HTTP calls: one token,
one list, and one get per selected ID. No application retries or backoff. A
rate-limit or transient failure is retried by a later user-initiated run. Token
and message response bodies remain capped at 1,048,576 bytes by `HttpClient`.
This design promises bounded work, not a throughput guarantee for 500 gets.

Keep existing mappings: ID → canonical ID; first nonblank case-insensitive
Subject → title (fallback `(no subject)`); optional snippet → body; positive
integer-string millisecond `internalDate` → UTC timestamp; optional From,
Date, Message-ID, thread ID, and label IDs → current `info` keys; `urls = []`.
Do not fetch full content to manufacture a snippet absent from metadata output.
Capture one wall-clock `fetched_at` for every item in the attempt.

Return `sync_state: {}` and `replace_existing_items: false`. Success metadata
contains only `source: "gmail_api"`, `limit`, and `message_count`. Do not persist
the credential path, queries, user IDs, token values, response bodies, or raw
headers as diagnostics. Intended normalized mail fields still belong in items.

Any token/list/detail/normalization failure fails the whole attempt with no
partial items. Even a detail 404 (message removed during the fetch) fails this
attempt. Persistence preserves prior successful items and freshness; other
sources can commit normally. Successful empty samples do not clear old rows.
Existing retention still runs on successful remote results only.

## Actionable, safe errors

Add `GmailApiError < SourceError` with immutable, allowlisted metadata:
`source: "gmail_api"`, `operation`, `category`, optional integer `status`.
Operations are `credentials`, `token`, `list`, `get`. The message is assembled
from static strings; input/remote content is never interpolated.

| Condition | Category | Static guidance |
|---|---|---|
| Missing config/file | `missing` | Configure credentials_file using README Gmail setup |
| Open/owner/mode/type rejection | `unreadable` | Check credential ownership and private file permissions |
| File JSON/schema/size rejection | `invalid_credentials` | Use authorized_user JSON, not downloaded OAuth client JSON |
| Token HTTP 400/401 | `authentication` | Reauthorize Gmail credentials |
| API HTTP 401 | `authentication` | Reauthorize Gmail credentials |
| Token expiry | `token_expired` | Run collection again; reauthorize if it persists |
| Returned scope lacks read-only scope | `scope` | Authorize gmail.readonly explicitly |
| HTTP 403 | `authorization` | Check Gmail scope, API enablement, and account/admin policy |
| HTTP 429 | `rate_limited` | Try again later |
| Other non-2xx | `http` | Gmail request failed; retry later or inspect setup |
| Transport failure | `network`, `timeout`, `response_too_large` | Fixed transport-specific message |
| Bad JSON/shape/identity | `invalid_json`, `invalid_shape`, `invalid_identity` | Unexpected Gmail response |
| Attempt budget exhausted | `deadline` | Fetch budget exhausted; try a smaller item limit |

For example: `Gmail list failed (authorization, HTTP 403). Check Gmail scope,
API enablement, and account/admin policy.` A 403 does not prove insufficient
scopes, disabled API, or rate exhaustion individually. Keep that uncertainty in
the message. Existing `Base#fetch` already propagates `safe_metadata` to the
run result; the CLI needs no new error renderer or debug mode.

## Migration, documentation, and release

Keep the same instance ID when moving the same Gmail account; add only the
credential file and optional Spam/Trash setting. Authenticate separately from
`gws`; do not read/decrypt its cache or revoke it automatically. Existing
credential-less configurations read a fresh cache and receive a clear setup
error on their next remote fetch. Switching mailboxes requires a new instance
ID so local data cannot be silently mixed. No old data is deleted during setup.

ADR 0005 supersedes ADR 0002 and explicitly carries forward its useful generic
command infrastructure. Old Gmail spec/plan records receive historical links;
their original reasoning remains readable. The direct implementation updates
the canonical template, README setup, `AGENTS.md`, and the dated Gmail
learning. README documents external OAuth bootstrap and migration; it does not
run login or manipulate prior `gws` state. The authenticated smoke test remains
a separate release gate.

Offline tests cover credential boundaries, HTTP contracts and bounds,
normalization, safe failures, cache behavior, cross-instance token isolation,
source isolation, retention, and unchanged persistence identity. They use local
fixtures/injected clients and no external services. The medium-effort,
read-only `gpt-5.6-luna` delegation sentence above was the planning-time rule
for this design record; it is retained as historical evidence. During the
later implementation task, the user explicitly authorized the primary agent
to run the full offline suite with xhigh reasoning. No tests, builds, or
linters were run merely for the planning task.

Before calling the replacement production-ready, run a separate authenticated
read-only smoke test: bootstrap the dedicated credential directory; verify
file shape/permissions without printing values; fetch one message through the
new adapter; repeat after a cache hit and a forced fetch; confirm success with
`gws` and `gcloud` absent from runtime PATH. Check the sample's read/unread labels
before and after. Record only sanitized statuses, granted scope names when
available, response field names, counts, and timing. This is a release gate,
not permission to contact a mailbox in the offline suite or this design task.
If credentials are unavailable, implementation may finish with the connector
still explicitly experimental and the live gate open.

## Sources checked 2026-09-06

[ruby-client]: https://github.com/googleapis/google-api-ruby-client/blob/main/generated/google-apis-gmail_v1/OVERVIEW.md
[ruby-auth]: https://github.com/googleapis/google-auth-library-ruby/blob/main/lib/googleauth/user_refresh.rb
[adc-login]: https://docs.cloud.google.com/sdk/gcloud/reference/auth/application-default/login
[gcloud-config]: https://docs.cloud.google.com/sdk/docs/configurations
[gcloud-install]: https://docs.cloud.google.com/sdk/docs/install-sdk
[gmail-list]: https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list
[list-guide]: https://developers.google.com/workspace/gmail/api/guides/list-messages
[gmail-get]: https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get
[gmail-scopes]: https://developers.google.com/workspace/gmail/api/auth/scopes
[oauth-native]: https://developers.google.com/identity/protocols/oauth2/native-app
[oauth-lifetime]: https://developers.google.com/identity/protocols/oauth2
[imap-auth]: https://developers.google.com/workspace/gmail/imap/xoauth2-protocol

Context7 was used to compare the Google API Ruby client. Official Google
reference pages supply the REST, OAuth, and bootstrap contracts. No dependency
was installed and no account-authenticated command was run during design.
