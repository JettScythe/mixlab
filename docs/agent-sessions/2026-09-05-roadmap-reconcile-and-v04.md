# Roadmap reconciliation and three v0.4 items

Date: 2026-09-05 | Branch: `agent/roadmap-reconcile-and-v04` | Model: anthropic/claude-opus-5

## Goal

Follow-up to PR #2. The user asked me to plan the next work myself; I
anchored to `ROADMAP.md` rather than my own taste, on the grounds that a
backlog I wrote *and* prioritise has nothing external checking it.

Three items, agreed as one PR:

1. Reconcile `ROADMAP.md` and `README.md` against what the code actually
   does.
2. Name-based deduplication on merge — the last "Known issue" in the sync
   path.
3. Recipe stores its bases (v0.4) **and** single-recipe plain-text export
   (v0.4). The user asked for all three items; #3 had been posed as an
   either/or, so both were built.

## Files Changed

```
 README.md                          |  63 ++++-
 ROADMAP.md                         |  52 ++--
 lib/models/ingredient.dart         |   6 +-
 lib/models/recipe.dart             |  23 ++
 lib/pages/calculator_page.dart     |  32 +++
 lib/pages/merge_preview_page.dart  |  26 ++
 lib/pages/recipe_detail_page.dart  |   7 +
 lib/pages/recipe_editor_page.dart  |  83 +++++-
 lib/pages/recipes_page.dart        |  16 ++
 lib/pages/settings_page.dart       |  12 +-
 lib/recipe_import.dart             |  74 +++++
 lib/state.dart                     |  70 ++++-
 lib/sync_merge.dart                | 116 +++++++-
 lib/widgets/ingredient_picker.dart |   7 +-
 lib/widgets/recipe_text_dialog.dart|  79 +++++ (new)
 test/calc_test.dart                | 557 +++++++++++++++++++++++++++++++++++++
 16 files changed, 1172 insertions(+), 53 deletions(-)
```

## Commands Run

```bash
git fetch origin && git checkout main && git pull --ff-only
git checkout -b agent/roadmap-reconcile-and-v04
flutter analyze                      # after each item
flutter test                         # after each item
flutter test --plain-name "<test>"   # revert-verification
dart format .
```

A subagent verified ten specific documentation claims against the code
before any of it was rewritten, so the reconciliation is evidence-based
rather than impressionistic.

## Outcome

Tests: **pass** (207, up from 191) | Lint: **pass** | Build: not run —
see Notes.

### Revert verification

| Fix reverted | Test | Result |
|---|---|---|
| `baseFor` ignores the pinned id | 3 base tests | fails |
| `_applyIngredientAliases` disabled | 7 dedup tests | fails |
| by-weight line dropped from text export | by-weight round trip | fails |
| `onPressed: () => _restore` restored | — | see below |

The dead-button fix has no test: it is a widget callback, and the repo's
`AGENTS.md` says UI-only changes may not need one. Confirmed by
inspection — `onPressed: () => _restore` evaluates the tear-off and
discards it, so the button was inert. The correct form is one line above
it on the Merge button.

## Notes

### Schema

Bumped to **v12** for the recipe base ids. The migration is a version bump
with no transform, which is correct here: a pre-v12 recipe has no such
keys, `Recipe.fromJson` reads absent as null, and null already means "use
whatever is selected" — the exact behaviour those recipes had. The bump
exists so an older build cannot silently drop the new ids on its next
write.

### Design decisions worth challenging

- **Merge dedup only considers ids absent locally.** An id present on both
  sides is the same record by definition, so a rename stays a rename
  rather than being second-guessed into a merge with a different bottle.
- **One local record absorbs at most one remote id.** Two remote
  duplicates of the same bottle would otherwise both alias onto it and
  collide; the second now arrives as its own record.
- **Ledger event ids are not rewritten**, only their `ingredientId`. The
  event id identifies the restock, not the bottle — rewriting it would
  either collide two devices' independent purchases or break the
  idempotency established in PR #2.
- **`_updateLoadedRecipe` only writes base ids if the recipe already had
  them.** Updating from the calculator should not quietly start pinning
  bases the user never chose to pin; the recipe editor is where that
  decision belongs.
- **A missing or wrong-kind base falls back rather than returning null.**
  Mixing with the wrong base is visible and recoverable; silently mixing
  0 mg is neither. Both the editor and the calculator warn.

### Documentation findings

The reconciliation turned up more drift than expected. The README's own
prose contradicted its own tables — the "Where MixLab loses" paragraph
claimed no in-place recipe editing, no by-weight percentages, no salts
and no additive handling, while four rows above it said "Yes" to all
four. It also described import as "merged by id" while the adjacent
button replaced everything. The stock ledger, reasoned adjustments, FIFO
and the device merge were undocumented entirely.

`ROADMAP.md` listed FIFO, paste import and picker keyboard navigation as
unbuilt, and had sync under "Not planned" while a reviewable merge
shipped. That entry was rewritten rather than deleted: no *server* is
planned, and that distinction is the point.

Added one item that the audit surfaced as genuinely incomplete: `intl`
currency formatting was checked off, but `moneyPerMl` and several inline
labels still append the ISO code, so both styles appear on one screen.

### Unresolved / follow-ups

- `flutter build` not run, same reasoning as the previous session: not in
  the AGENTS.md gate, CI covers the three desktop targets, no platform
  directories touched.
- The remaining merge gap, now stated accurately in Known issues: two
  installs spelling the same bottle differently ("TFA Strawberry Ripe" vs
  "TPA Strawberry (Ripe)") still merge as two. Fixing that means applying
  the importer's brand-alias normalisation to the dedup key — plausible,
  but it starts guessing, and guessing wrong silently merges two
  different bottles' stock.
- Text export is copy-to-clipboard only. `share_plus` is already on the
  roadmap for iOS and would be the natural home for a real share sheet.
- No widget test covers the new "Share as text" dialog or the base
  pickers in the recipe editor. Consistent with the repo's existing
  test strategy, but the dead Restore button is exactly the class of bug
  a smoke test would have caught — `ROADMAP.md` already lists that under
  Ongoing—Engineering.
