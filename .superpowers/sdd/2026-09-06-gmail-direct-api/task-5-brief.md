### Task 5: Verify migration, failure isolation, and generic dependencies

**Files:** Modify `test/system/cli_system_test.rb`, `test/orchestrator_test.rb`;
extend `test/support/gmail_http_fixture.rb` only if shared routing is needed.

**Interfaces:**
- Consumes the default registry and existing CLI `http_client:`,
  `command_runner:`, `dependency_checker:`, `home:` test injections.
- Produces offline integration evidence with temporary configuration/SQLite and
  fake HTTP responses, retaining all generic command-preflight coverage.

- [x] **Step 1: Port system-test helpers and add failing regressions.**
  Change `write_gmail_config` to accept an explicit credential-file path and
  optional inclusion of its TOML key; keep retention and ID parameters. Create
  chmod-0600 authorized-user files in the temporary test installation. Replace
  `FakeGwsRunner`/`gmail_runner` usages for real Gmail with HTTP fixtures. Use
  `--json` when parsing CLI JSON. `CLI.start` currently defaults to JSON for
  programmatic compatibility, while `bin/cybort` selects diagnostic output;
  pass `output_mode: :diagnostic` explicitly in human-output tests. Inspect
  each touched test before porting; no general test-output migration is needed.

  Define a sentinel dependency checker whose `resolve` raises if invoked and
  a sentinel runner whose `run` raises. Pass both to real Gmail integration
  tests; any accidental runtime tool dependency fails immediately.

  Implement this primary scenario in the current system harness:

  ```ruby
  # After helper wiring has written the same jer_gmail config and credential file:
  first = Cybort::CLI.start(["--json", "--force-fetch"], home: directory,
    out: first_output, err: StringIO.new, http_client: successful_http,
    command_runner: refusing_runner, dependency_checker: refusing_checker)
  assert_equal 0, first
  failed = Cybort::CLI.start(["--json", "--force-fetch"], home: directory,
    out: failed_output, err: StringIO.new, http_client: token_rejected_http,
    command_runner: refusing_runner, dependency_checker: refusing_checker)
  assert_equal 1, failed
  payload = JSON.parse(failed_output.string)
  mail = payload.fetch("instances").find { |entry| entry.fetch("id") == "jer_gmail" }
  assert_equal "failure", mail.fetch("status")
  assert_equal "token", mail.fetch("metadata").fetch("operation")
  assert_equal "authentication", mail.fetch("metadata").fetch("category")
  assert_equal 400, mail.fetch("metadata").fetch("status")
  assert_equal "Quarterly review", mail.fetch("items").first.fetch("title")
  ```

  For this scenario `token_rejected_http` must be a recording fake raising
  `HttpError.new(status: 400)` on the token POST; assert operation `"token"`,
  category `"authentication"`, status `400` unconditionally. Define both output
  buffers as `StringIO.new`. Use the existing file-backed Gmail fixtures for
  `successful_http`. Keep these helpers local to the test file.

  Add the following concrete scenarios, with assertions at CLI and persistence
  boundaries as relevant:

  | Test scenario | Required assertions |
  |---|---|
  | Same ID migrated from seeded existing mail | Same canonical IDs upsert; no duplicate rows or schema change |
  | Fresh cache, file absent/config key omitted | Exit 0, cached items, no file/token/list/get or preflight calls |
  | Stale/forced cache, missing file | Exit 1, credentials/missing, old items and freshness retained |
  | Gmail 403 with healthy RSS | Gmail failure, RSS committed, partial failure exit 1 |
  | Detail failure after one successful get | No partial mail persisted and no retention pruning |
  | Empty successful list | Cache freshness advances, old items remain absent retention expiry |
  | Successful fetch with retention | Existing cutoff behavior prunes old unreturned items only on success |
  | Two accounts/files | Each token POST uses its own refresh token; each Gmail header uses corresponding bearer |
  | Safe diagnostics/history | No token, credential path, query, user ID, or raw error body in error/metadata fields |
  | Human output | Static token/403/file guidance appears in newline-terminated error message |

  In the two-account case, use a mutex-protected fake mapping credentials to
  tokens and routing GETs by bearer header, rather than an order-dependent
  response queue shared across adapter threads. Mail data is intentionally
  stored in items; secrecy assertions target diagnostics/metadata, not all
  successful item JSON.

- [x] **Step 2: Delegate focused system/orchestrator tests.** Commands:
  `bundle exec ruby -Itest test/system/cli_system_test.rb` and
  `bundle exec ruby -Itest test/orchestrator_test.rb`.
  Expected: old Gmail-as-command assumptions fail until Step 3 is complete.

- [x] **Step 3: Preserve command-infrastructure tests with synthetic adapters.**
  In `orchestrator_test.rb`, replace fake adapter names/tool labels `gmail/gws`
  with `command_fixture/fixture-tool` for tests already using `PlanningAdapter`
  and an explicitly registered dependency. In system tests requiring command
  preflight, inject a custom registry whose `command_fixture` entry has a
  declared `Dependency`; do not use the default Gmail entry. Preserve the
  missing-tool, fresh-cache, forced-fetch, per-run de-duplication, grouped hints,
  and version requirement assertions. Retain existing `CommandRunner` and
  `DependencyChecker` unit tests unchanged unless a real defect is discovered.

  ```ruby
  dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
  registry = Cybort::AdapterRegistry.new
  registry.register("command_fixture", factory,
    dependencies: [dependency], validate_configuration: ->(_instance) {})
  ```

  Here `factory` is the existing test's `PlanningAdapter` factory (or the
  corresponding existing system fake); retain its constructor and returned
  `FetchResult`. Do not introduce a production synthetic connector.

- [x] **Step 4: Delegate focused tests again.** Repair only evidence-backed
  integration issues. Any runtime defect returns to its owning task's failing
  test; avoid rewriting shared orchestration just to accommodate test fakes.
- [x] **Step 5: Commit Task 5 changes** with message
  `test: cover Gmail REST migration and source isolation`.

## Review evidence

Root review approved the complete Task 5 diff after confirming the real
`HttpClient` privacy path exercises body-discard redaction and the bounded Gmail
fixture derives IDs directly from the parsed list. Focused verification remains:

- `bundle exec ruby -Itest test/system/cli_system_test.rb`: 28 runs, 249
  assertions, 0 failures, 0 errors.
- `bundle exec ruby -Itest test/orchestrator_test.rb`: 13 runs, 52 assertions,
  0 failures, 0 errors.
- `git diff --check`: clean.

No full suite or live Gmail smoke test was run for this task. The approved
commit is limited to the two test files and this task brief.
