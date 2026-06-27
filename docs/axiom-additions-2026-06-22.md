# Axiom Additions — 2026-06-22 (fm/axiom-mine-5r)

Scout reports audited:
- mac-cfg-scout-3r
- claude-cfg-scout-7m
- inbox-scout-6d
- bootstrap-scout-2c
- btw-research-add-8h
- pcr-scout-3e
- agentstack-scout-7f
- tensor-scout-9b
- test-audit-18c9
- mintmux-scout-4a

## New entries (8 total)

| AX    | Title                                                              | Source scout(s)                       |
|-------|--------------------------------------------------------------------|---------------------------------------|
| AX-019 | Worktree registry pointer can outlive treehouse dir               | mac-cfg, bootstrap, pcr, agentstack   |
| AX-020 | Harness-adapter aliases added without smoke-test verification      | claude-cfg                            |
| AX-021 | Test functions in non-`_test.go` source files are silent dead code | test-audit                            |
| AX-022 | `.go` files committed as pseudocode block transitive importers     | test-audit                            |
| AX-023 | tmux window state can outlive its meta record after crash          | mintmux                               |
| AX-024 | Squash-merge replication leaves branches "unmerged" but superseded | bootstrap, pcr                        |
| AX-025 | Per-skill symlinks break when target dir is replaced by one link   | claude-cfg, mac-cfg                   |
| AX-026 | Data-only artifact repos need `.gitignore` before 2nd commit       | btw-research                          |

## Entries not added (deferred or duplicates)

- **Inbox `hygiene/20260608` m3-pipeline stubs** (inbox-scout-6d) — this is a code-review finding (orphaned utility files), not a reusable failure pattern; covered by general code-quality rules already in flight.
- **Tensor-logic `__rmul__`/`__radd__`** (tensor-scout-9b) — already shipped as PR #76; no axiom needed since the failure mode is fixed.
- **Branch-audit fake branches / no-op scouts** (agentstack-scout-7f) — not a reusable failure pattern; scout-protocol hygiene, not a system invariant.

## Pattern coverage matrix

| Failure mode family                  | New AX | Existing AX                          |
|--------------------------------------|--------|--------------------------------------|
| State / registry staleness           | 019,023| AX-001, AX-005                       |
| Wiring without verification          | 020,021| AX-009, AX-010, AX-011               |
| Build-blocking file shape            | 022    | AX-004 (different — runtime, not parse) |
| Merge / ancestry assumptions         | 024    | —                                    |
| Symlink / filesystem indirection     | 025    | —                                    |
| Repo hygiene / growth                | 026    | —                                    |

## Verification

- 8 new entries appended to `~/m3lab/axioms/AXIOMS.md` (file: 38.2K → 50.0K)
- All 5 required fields populated (Statement, Evidence, Executable check, Redteam pattern, Static check)
- No duplicates of AX-001..AX-018 (AX-019 reserved past gap; AX-014/AX-015 absent in source so next free slot is AX-019)
- `axiom-ingestor --from-docs` attempted; current binary only supports `--from-runs`, returned `success,0,0` — the docs path is not yet implemented in the binary, but the AXIOMS.md file is the canonical record anyway.

## Notes for AXIOM ledger hygiene

- Two duplicate `AX-012` headers exist in `~/m3lab/axioms/AXIOMS.md` (one at line ~333, one at line ~451). Pre-existing; out of scope for this task.
- AX-014 / AX-015 are absent from the canonical file (gap in numbering). Next free slot is AX-019.
