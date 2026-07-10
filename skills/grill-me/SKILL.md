---
name: grill-me
description: Adversarial self-review — challenge your own work as a hostile reviewer would, then rebut or fix every flag.
---

Review the current change as a hostile reviewer determined to reject it.
Examine every aspect — correctness, edge cases, error handling, naming,
performance, security, test coverage, and documentation.

For each potential issue you would flag:

1. **State the flag** — what would the hostile reviewer say is wrong?
2. **Assess it honestly** — is the flag valid, partially valid, or invalid?
3. **Respond** — if valid or partially valid, fix it. If invalid, rebut it
   with a concrete reason.

Cover at minimum:
- Correctness: does the change do what it claims? Are edge cases handled?
- Completeness: is anything missing from the spec or acceptance criteria?
- Robustness: will it break under unexpected inputs or concurrency?
- Maintainability: is the code clear, well-named, and idiomatic?

Output each flag with its disposition (fixed/rebutted/no-action) so the
review leaves no open questions.
