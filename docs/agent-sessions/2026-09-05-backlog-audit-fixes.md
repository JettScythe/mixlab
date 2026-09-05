# Backlog audit fixes

Date: 2026-09-05 | Branch: `agent/backlog-audit-fixes` | Model: anthropic/claude-opus-5

## Goal

Work the 15-item backlog in `docs/agent_backlog.md`, produced by an earlier
read-only audit. Priority order was migrations and import-merge
idempotency, then density and achieved-value coverage, then calculation
and inventory arithmetic, then unhandled error paths, then dead code.

User decisions taken before editing:

- **Scope:** all five batches in one branch, not deferred.
- **Item #10 model:** stock-on-hand valuation. Fix the defect that an
  outstanding deficit gets re-priced; do not adopt a conservation
  identity that would move historical mix costs.
- **Item #6:** fix the density fallback in `calculateMix` *and* coerce at
  the source in `Ingredient.fromJson`.

## Files Changed

```
 lib/cost_basis.dart               |  53 +--
 lib/models/calculate_mix.dart     |  14 +-
 lib/models/enums.dart             |  11 +
 lib/models/ingredient.dart        |  56 ++-
 lib/models/ledger.dart            |  17 +-
 lib/models/mix.dart               |  13 +-
 lib/models/recipe.dart            |   8 +-
 lib/models/settings.dart          |  21 +-
 lib/models/units.dart             |   9 -
 lib/pages/calculator_page.dart    |   6 +-
 lib/pages/inventory_page.dart     |  14 +-
 lib/pages/step_mode_page.dart     |   4 +-
 lib/pages/stock_history_page.dart |  13 +-
 lib/state.dart                    | 115 +++++-
 lib/sync_merge.dart               | 106 +++++-
 test/calc_test.dart               | 768 ++++++++++++++++++++++++++++++++++++++
 16 files changed, 1117 insertions(+), 111 deletions(-)
```

## Commands Run

```bash
git status --porcelain            # blocked once: docs/agent_backlog.md untracked
git checkout -b agent/backlog-audit-fixes
flutter analyze                   # after each batch
flutter test                      # after each batch
flutter test --plain-name "<test>" # revert-verification, see below
dart format .
```

## Outcome

Tests: **pass** (180, up from 148) | Lint: **pass** (`No issues found!`) |
Build: not run — see Notes.

### Revert verification

Each behavioural fix was reverted individually and its test re-run, to
confirm the test actually discriminates rather than passing regardless.
All seven failed as expected, then the fix was restored from a backup
copy and the full suite re-run green.

| Fix reverted | Test | Result |
|---|---|---|
| `value` uses `lastRate` | deficit re-pricing | fails |
| drop `alreadyOpened` guard | interrupted v9 | fails, `Expected: <1> Actual: <2>` |
| drop `declinedDeletes` | declined delete | fails |
| restore `: 1.0` fallback | zero-density flavor | fails |
| restore `? … : 0.0` in `withGrams` | weighed line deducts | fails |
| drop ledger id guards | same plan twice | fails |
| drop pre-v9 opening balances | pre-ledger merge | fails |

## Notes

### Assumptions made

- **No schema bump.** Nothing in this change alters the persisted shape.
  Flagged to the user and accepted: `Ingredient.fromJson` now writes a
  repaired density back on the next save, so a v11 store touched by this
  build differs in *content* from one touched by the previous build. That
  is a repair of invalid data (`density <= 0` was never valid), not a
  format change. If that judgement is ever revisited, the fix is a bump
  plus a forward migration that rewrites the same field.

- **`fromJson` density repair uses default densities.** No `Settings` is
  in scope at that call site. The repair is still carrier-aware and
  strictly better than 0 or 1.0, but a user with customised PG/VG
  densities gets stock figures for repaired records. Threading `Settings`
  through `fromJson` would touch every call site including
  `restoreFromBackup` and `buildMergePlan`; deliberately not done here.

- **Item #15 deviation.** The backlog listed `adjustReasonRemoves` as dead
  code to delete. It is now *called* from the two sites in
  `stock_history_page.dart` that had inlined its reason list verbatim.
  Deleting it would have left the duplicate behind, which was the actual
  divergence hazard the audit flagged.

- **`_openingBalancesFor` in `sync_merge.dart` mirrors the v9 migration in
  `state.dart`, ids included.** The duplication is intentional and
  commented: the same data brought forward by either route must produce
  identical records, or a peer upgrading after a merge would double its
  stock. Extracting a shared helper is the obvious follow-up but would
  couple the merge path to `AppState`'s private migration internals.

### Unresolved / follow-ups

- The `Settings`-aware density repair described above.
- `flutter build` was not run. AGENTS.md lists analyze / test / format as
  the pre-commit gate and does not name a build command; CI covers the
  three desktop targets. No platform directories were touched.
- Two pre-existing test-suite behaviours are unchanged and still print
  stack traces to stdout during the run (deliberate: they exercise the
  corrupt-JSON and schema-too-new recovery paths). Not noise introduced
  by this branch.

### Not addressed, by design

Items the audit explicitly excluded as ROADMAP-deferred remain untouched:
ingredient duplication on cross-install merge, FIFO as a *feature*,
recipe-stores-its-bases, UUID ids, widget/golden tests, the `drift`
migration, and breakpoint consistency.
