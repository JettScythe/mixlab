# Recipe tags/favorites, CSV export, intl per-mL pricing

Date: 2026-09-06 | Branch: `agent/v07-recipe-tags-and-csv` |
Model: anthropic/claude-opus-5

## Goal

Plan, implement and release the next upgrade after v0.6.0-beta.1. Scope
approved by the user: finish the ROADMAP v0.4 line — recipe tags and
favorites, CSV export — plus the intl per-mL pricing item flagged during
the v0.6 review.

## What happened

Scout mapped the three surfaces (Recipe model, export plumbing, money
helpers) and returned four landmines, all of which materialised:

1. Schema bump owed — `_write` re-stamps at currentSchema, so new Recipe
   fields would be stripped by an older build without the bump to v13.
2. `_recipeDiff` is field-by-field; new fields need a case or changes
   never sync.
3. `duplicateRecipe` copies fields explicitly; new fields must be added.
4. `moneyPerMl` bypassed intl entirely.

## First specialist review: BLOCK

The first draft had three user-visible defects, all caught by review
before any release:

- **Editor dropped `favorite` on save.** `_build` never passed it, so any
  edit unpinned the recipe, the loss synced as intentional, and the dirty
  check (self-referential snapshot) never prompted.
- **Tags accumulated whitespace per save.** `join(', ')` seeded, `split(',')`
  read back, nothing normalised — the drift compounded each save, synced
  each time, and search never matched uppercase input. Fixed by
  normalising in the Recipe constructor, which every path uses.
- **The tag filter could not be cleared**: a null `PopupMenuItem` value
  means "dismissed" and never reaches `onSelected`. Switched to a `''`
  sentinel.

Plus: unstable favorite sort above ~32 items (List.sort is not stable —
folded into one comparator), asymmetric `_tagsEqual` on duplicate tags
(compare as sets), tag-filter chip overflow on phone layout (wrapped),
`hasTag` over-matching in the filter (exact match; substring stays in
search), CSV `#` headers documented as human-readable rather than
spreadsheet comments, dead `tags` column on inventory rows, and
CSV-formula injection (`=1+1` now quoted).

The reviewer also killed a non-discriminating test (`contains('100')`
passed against a fixture where 100 was the bottle size) and a test
certifying `setTags`, which no production code called.

## Files changed

```
 lib/csv_export.dart               | new, 152 lines
 lib/models/recipe.dart            |  47 +++++--
 lib/models/units.dart             |  27 ++++--
 lib/pages/recipe_detail_page.dart |   5 +-
 lib/pages/recipe_editor_page.dart |  23 +++-
 lib/pages/recipes_page.dart       | 109 +++++++++++--
 lib/pages/settings_page.dart      |  68 ++++++++--
 lib/state.dart                    |  11 ++-
 lib/sync_merge.dart               |  15 ++
 pubspec.yaml                      |   2 +-
 test/calc_test.dart               | 213 ++++++++++++++--
```

## Commands run

```
git checkout -b agent/v07-recipe-tags-and-csv
flutter analyze               # clean
flutter test                  # 237 pass (was 229)
dart format                   # no changes
flutter build macos --release # succeeded, 47.7 MB
gh pr create                  # PR #5
gh pr checks 5                # test + four build targets pass
```

## Outcome

Tests: pass (237) | Lint: pass | Build: pass (macOS local; all four
targets on CI via PR #5)

- PR open: https://github.com/JettScythe/mixlab/pull/5
- Version `0.6.0-beta.1+10` → `0.7.0-beta.1+11`
- Release notes drafted at `docs/release-notes-0.7.0-beta.1.md`

## Notes

- Specialist review round 1 returned BLOCK with three blockers (editor
  dropping favorite on save; whitespace-compounding tags; unclearable
  tag filter) plus two high findings. All fixed; tests added for each.
- `moneyPerMl` deliberately keeps the ISO code rather than the locale
  symbol: `$0.123` reads like a typo next to `$1.03` totals. Only the
  grouping changed.
- CSV `#` block headers are documented as human-facing; spreadsheets see
  them as one-field rows. Accepted trade for one file instead of three.
- Follow-ups, not blockers: filter Row still overflows on very narrow
  phones (pre-existing, made slightly worse by the star; the new chips
  themselves are wrapped); the CSV save flow is untested UI.

**Session export:** not performed; no export capability available. Manual
step: `ctrl+p` → export in the OpenCode TUI.
