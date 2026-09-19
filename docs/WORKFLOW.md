# Cybort Agent Workflow

This playbook keeps recurring handoffs short and consistent. It complements
`AGENTS.md`; it does not replace the task's explicit user instructions.

## Default sequence

For an explicitly authorized implementation task:

1. Inspect the relevant code, tests, README section, ADRs, and learnings.
2. Classify the work as bounded or architectural and state the intended scope.
3. Have one implementation agent work in the shared `main` worktree. Do not
   launch another writer until it is idle.
4. Delegate test execution and noisy output analysis to Luna. An implementation
   Luna may also run its own tests when explicitly authorized.
5. Review the completed diff. Use Astra for architectural, concurrency,
   security, or data-loss risk; use Sol for a final code review when requested
   or warranted.
6. Implement only accepted review findings, then verify the resulting diff.
7. Commit and push at the user-requested checkpoint.

For low-risk documentation or one-line changes, skip expensive reviewers and
use a concise primary review. Do not run RuboCop when the user excludes it.

## Agent handoff templates

### Luna implementation

```text
Implement <bounded objective> on the current main worktree.
Modify only <scope>. Preserve <invariants>. Do not commit or push.
Run focused tests, then the full suite if appropriate; do not run RuboCop.
Return only: commands, pass/fail, first actionable failure, likely cause
(labeled inference), and next step.
```

### Luna test/log analysis

```text
Run <command> read-only and summarize only the bounded result.
Return: command, pass/fail, failing tests or relevant log entries, first
actionable error, likely cause (labeled inference), and recommended next step.
Do not modify files or git state.
```

### Astra or Sol review

```text
Review the current diff against <baseline> read-only. Do not run RuboCop or
modify files. Report only concrete actionable findings with severity, file/line,
rationale, and recommended fix. State explicitly when no issue remains.
```

## Review and autonomy rules

- The primary agent explicitly records each finding as accepted, rejected, or
  deferred. Do not blindly implement a technically unsound suggestion.
- One review pass is normally enough. Request another review only when a fix
  changes the same high-risk boundary or the reviewer asks for re-review.
- If a reviewer hits a usage limit, continue with a bounded primary review and
  record the fallback; do not wait indefinitely for a model slot.
- “Proceed,” “go ahead,” or explicit end-to-end authorization means continue
  through the named phases without repeated approval prompts. Stop only for a
  genuine blocker or a materially ambiguous choice.
- Reviewers are read-only. Writers are sequential in the shared worktree.

## Commit checkpoint

Before each requested commit:

1. Confirm `git status --short` contains only task changes.
2. Run `git diff --check`.
3. Confirm the delegated verification summary and inspect the final diff.
4. Commit one coherent task boundary with a descriptive message.
5. Push the requested branch and report the commit ID.
