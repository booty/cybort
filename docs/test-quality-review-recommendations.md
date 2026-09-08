# Test-quality review recommendations

Review scope: the current `main` branch (`a19e899`), read-only inspection of
the test suite and relevant project records. No tests, linters, builds, source
changes, test changes, configuration changes, or git-state changes were made.

## Concrete recommendations

1. **Remove the duplicate installation smoke test.**

   `test/cli_test.rb:74-85` and `test/system/cli_system_test.rb:537-546`
   both call `Cybort::CLI.start(["init", path], ...)`, assert status `0`, and
   assert that `cybort.toml` and `cybort.sqlite3` are created. Keep the system
   test as the single user-visible installation check and remove the duplicate
   from `CliTest`. This removes identical filesystem setup without reducing
   behavioral coverage.

2. **Move credential printable-boundary coverage behind the public loader.**

   `test/gmail_credentials_test.rb:175-183` calls the `printable?` helper
   directly. The public `GmailCredentials.load` cases at
   `test/gmail_credentials_test.rb:65-98` already
   exercise invalid encoding, missing values, blank values, controls, and
   per-field byte limits. Remove the direct helper test, or fold only any
   missing boundary case into the existing `load` table. This keeps the
   credential contract observable at its file-loading boundary instead of
   coupling the suite to an internal helper name and signature.

3. **Drop the reflection-only registry assertion.**

   `test/adapter_registry_test.rb:57-62` includes
   `assert registry.respond_to?(:validate_configuration!)`. The same test file
   invokes `validate_configuration!` repeatedly, so this assertion only tests
   Ruby method reflection rather than registry behavior. Keep the meaningful
   no-executable-dependency assertion and remove the `respond_to?` check.

## Optional polish

- `test/persistence_test.rb:432-517` repeats the same database setup,
  replacement write, injected failure, and rollback assertions three times
  for fetch-history, upsert, and state-update failures. Extract a helper that
  accepts the failure injection and retain the three named test methods. This
  reduces fixture/assertion drift without hiding which transaction phase
  failed.

- `test/dependency_checker_test.rb:66-91` has two tests with identical setup
  and expectations whose only difference is the accepted `gws --version`
  output format. A small table of labeled stdout variants can share the setup
  while retaining both format cases and their failure labels.

- `test/gmail_credentials_test.rb:109-134` globally replaces `File.open`, and
  `test/adapters/reddit_rss_test.rb:232-254` temporarily replaces
  `Cybort::Item.new`. Both protect legitimate resource/deadline boundaries,
  so they should not simply be deleted; when those production APIs are next
  changed, prefer a narrow injected opener/item factory to avoid global
  monkeypatching and make cleanup automatic.

No other high-confidence test removals or combinations were identified. The
many adapter, persistence, concurrency, sanitization, and Reddit RSS boundary
tests generally protect distinct contracts even where their fixtures look
similar.
