# Scripting 30 final handoff

Completed the existing scripting62 corrections from `6f682e0`:

- Added `__len` and operand-aware operation diagnostics so unknown-global
  names survive length and right-hand arithmetic operations.
- Added strict-mode end-of-chunk validation, including declaration-free and
  post-declaration reads, while preserving default unused-binding behavior
  and resetting strict taint for each chunk.
- Added focused extractor regressions for these cases.

Validation and the existing PR handoff are recorded with the final commit.
