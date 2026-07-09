# Triage Labels

Label conventions and the triage process used across the firstmate project.

## Issue labels

| Label          | Color   | Purpose                                  |
| -------------- | ------- | ---------------------------------------- |
| `bug`          | `d73a4a` | Something is broken.                     |
| `enhancement`  | `a2eeef` | New feature or improvement.             |
| `documentation`| `0075ca` | Docs-only change.                       |
| `good first issue` | `7057ff` | Suitable for new contributors.      |
| `help wanted`  | `008672` | Extra attention or contribution needed.  |
| `question`     | `d876e3` | Discussion or clarification request.     |

## Priority labels

| Label   | Color   | Meaning                                     |
| ------- | ------- | ------------------------------------------- |
| `P0`    | `b60205` | Must fix immediately; blocks the fleet.     |
| `P1`    | `d93f0b` | Should fix in the current milestone.        |
| `P2`    | `fbca04` | Nice to have; not blocking anything.        |
| `P3`    | `0e8a16` | Backlog; no urgency.                        |

## Effort labels

| Label   | Meaning                      |
| ------- | ---------------------------- |
| `S`     | Small (under a few hours).   |
| `M`     | Medium (a day or so).        |
| `L`     | Large (multiple days).       |
| `XL`    | Very large (needs scouting). |

## Triage process

1. **Read the issue.** Understand the problem or request.
2. **Apply type label.** Is it a `bug`, `enhancement`, `documentation`, or
   `question`?
3. **Apply priority.** How urgent is this relative to the rest of the
   backlog?
4. **Estimate effort.** Apply `S`, `M`, `L`, or `XL`.
5. **Mark for contribution** if appropriate (`good first issue`,
   `help wanted`).

Issues without a type label are considered untriaged. Issues without
priority are treated as P3 (backlog).

## For crewmates

When you ship a fix, verify the issue has the correct labels.
If the issue was missing labels, apply them before closing.
A triaged issue should have at minimum one type label and one priority label.
