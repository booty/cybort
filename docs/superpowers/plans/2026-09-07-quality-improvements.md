# Quality Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the accepted test and code-quality recommendations on `main`, with one verified commit and push for each requested step.

**Architecture:** Work in three sequential slices. First simplify tests without changing production behavior. Second address the deferred persistence/lifecycle follow-ups, including the minimum schema, CLI, and documentation changes needed for coherent behavior. Third apply the accepted code-review findings, reusing step-two changes where they overlap and adding focused validation/refactoring tests.

**Tech Stack:** Ruby 4, Minitest, SQLite, TOML configuration, Bundler/Rake, RuboCop.

**Spec:** `docs/test-quality-review-recommendations-accepted.md`, `docs/quality-followups.md`, and `docs/code-quality-review-recommendations-accepted.md`.

## Global Constraints

- Work directly on `main`; do not create a feature branch or worktree.
- Tests use local fixtures and injected clients; no external services.
- Delegate every test command and noisy test-output analysis to a `gpt-5.6-luna` subagent; the subagent is read-only.
- Preserve SQLite ownership in persistence and keep adapter threads free of SQL/schema details.
- Preserve documented exit codes, cache/failure semantics, retention semantics, and source isolation.
- Commit and push after each numbered task is verified.

---

### Task 1: Implement accepted test-quality improvements

**Files:**
- Modify: `test/cli_test.rb`, `test/gmail_credentials_test.rb`, `test/adapter_registry_test.rb`
- Optionally refactor: `test/persistence_test.rb`, `test/dependency_checker_test.rb` only where the accepted optional recommendations remain clear and behavior-preserving

- [ ] Remove duplicate installation and reflection-only assertions.
- [ ] Fold credential printable-boundary coverage into public loader coverage or remove the internal-helper test.
- [ ] Simplify repeated rollback/version-format setup without hiding distinct failure phases.
- [ ] Delegate focused/full tests to Luna; inspect the summary.
- [ ] Commit and push Task 1.

### Task 2: Implement `docs/quality-followups.md`

**Files:**
- Modify: `lib/cybort/orchestrator.rb`, `lib/cybort/persistence.rb`, `lib/cybort/schema.rb`, `lib/cybort/cli.rb`, `lib/cybort/configuration.rb`, `lib/cybort/installer.rb`, `.cybort.example.toml`, `README.md`, `docs/LEARNINGS.md`, and relevant tests
- Create or modify: migration/version support only if required by measured pruning-index work

- [ ] Establish a scoped RuboCop baseline without mass-autocorrecting legacy code.
- [ ] Avoid eager item hydration during remote-only runs while preserving cache summaries and counts.
- [ ] Measure/cover retention pruning and add the composite index only with a safe schema path.
- [ ] Add explicit hard-expiry and instance-removal semantics with isolated, recoverable CLI/persistence workflows.
- [ ] Update durable docs and tests for the chosen lifecycle behavior.
- [ ] Delegate focused/full tests to Luna; inspect the summary.
- [ ] Commit and push Task 2.

### Task 3: Implement accepted code-quality recommendations

**Files:**
- Modify: `lib/cybort/item.rb`, `lib/cybort/persistence.rb`, `lib/cybort/configuration.rb`, `lib/cybort/cli.rb`, `lib/cybort/orchestrator.rb`, and targeted adapter/client/state helpers
- Modify relevant tests and durable learning notes

- [ ] Validate item boolean/value-object boundaries and duplicate identities before persistence.
- [ ] Reuse Task 2’s planning/hydration and installation-path changes instead of duplicating them.
- [ ] Add deterministic ordering and registry-backed progress labels where low-risk.
- [ ] Extract only clearly equivalent duplicated validation/error mechanics.
- [ ] Delegate focused/full tests to Luna; inspect the summary.
- [ ] Commit and push Task 3.

---
