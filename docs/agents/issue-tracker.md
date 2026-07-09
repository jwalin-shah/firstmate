# Issue Tracker (GitHub)

Firstmate uses GitHub Issues for tracking bugs, feature requests, and
enhancements. This document describes the conventions for working with the
issue tracker.

## Issue templates

Bug reports and feature requests should include enough detail for a crewmate
to reproduce and fix without asking follow-up questions.

### Bug report

```
### Description
What went wrong, in one sentence.

### Steps to reproduce
1. ...
2. ...
3. ...

### Expected behavior
What should have happened.

### Actual behavior
What actually happened, including any error messages.

### Environment
- OS: [e.g. macOS 15.4, Ubuntu 24.04]
- firstmate version: [commit hash or tag]
- Harness: [e.g. claude, codex, grok]
```

### Feature request

```
### Problem
What problem does this solve, in one or two sentences.

### Proposed solution
What should firstmate do differently.

### Alternatives considered
Other approaches and why they do not work as well.
```

## Labels

Firstmate uses a lightweight label convention. See
[docs/agents/triage-labels.md](triage-labels.md) for the full label catalog
and triage process.

## Lifecycle

1. **New** -- issue is filed with a clear description.
2. **Triaged** -- a label is applied, priority and effort estimated.
3. **Assigned** -- a crewmate or secondmate is dispatched to work on it.
   For firstmate self-work: dispatch through the normal ship lifecycle
   (branch `fm/<id>`, no-mistakes pipeline, PR, merge).
4. **In progress** -- the crewmate is working; the issue receives a
   tracking comment with the task id.
5. **Closed** -- the fix lands on `main` (the PR is merged), or the
   issue is resolved as wontfix/duplicate.

## Linking to work

When a crewmate ships a fix for an issue, the PR description should
include `Closes #<number>` so GitHub auto-closes the issue on merge.

For scout investigations that relate to an issue, the report path
(`data/<id>/report.md`) should be linked in a comment on the issue.

## Repository

Issues are tracked in the [firstmate GitHub repository](https://github.com/kunchenguid/firstmate/issues).
