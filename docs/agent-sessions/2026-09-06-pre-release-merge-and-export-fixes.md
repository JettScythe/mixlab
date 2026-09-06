# Pre-release: merge PR #3, fix its defects, prepare v0.6.0-beta.1

Date: 2026-09-06 | Branch: `agent/pre-release-merge-and-export-fixes` |
Model: anthropic/claude-opus-5

## Goal

Prepare MixLab for its next release: inspect and merge the open PR, assess
release readiness against the last published release, resolve genuine
blockers, verify, and draft release notes. No tag, no publish.

## What happened

**PR #3** (`feat: recipe bases, name-based merge dedup, recipe text
export`) was the only open PR. All six CI checks green, no reviews, no
conflicts, mergeable, targeting `main`.

It touched schema migration, device merge and nicotine handling, so it
went to specialist review before merging rather than after. The review
found nine defects — two of them nicotine-math outcomes, which AGENTS.md
designates ask-first:

1. Name dedup matched on brand + name only, then applied last-write-wins.
   A local 250 mg/mL base fused with a remote 100 mg/mL base of the same
   name and was redefined to 100. Measured delivery: 7.5 mg/mL against a
   3 mg target, warnings empty. The same path converted a nicotine base
   into a flavor.
2. `_applyIngredientAliases` did not rewrite the `nicId`/`pgId`/`vgId`
   that the same PR added, so a merged recipe arrived pinned to an id the
   device never stored and `baseFor` fell back silently.
3. `claimed` did not guard against a remote id equal to a local id, so a
   name duplicate could alias onto a record arriving by id — two plan
   items with one id, resolved in list order rather than by timestamp.
4. Fractional VG targets were corrupted by the text export round trip
   (62.5 → 5) and shipped float noise into user-facing text.
5. A deleted ingredient rendered as a bare `8%` and re-imported as
   nothing.
6. Notes were re-parsed as ingredients on re-import.
7. `_recipeDiff` had no case for the pins or `targetVgPercent`, so a
   repin never propagated.
8. `duplicateRecipe` dropped the pins.
9. Seeded stock inflated across two fresh installs.

Everything was in unreleased code, so the user chose to merge #3 as-is and
fix on a follow-up branch — nothing ships between the two. The user
approved fixing all six, including the ask-first dedup change.

PR #3 merged (commit `dfd8c80`, merge commit strategy, no branch
deletion). Local `main` fast-forwarded.

Fixes were made on `agent/pre-release-merge-and-export-fixes`, then sent
back to specialist for review of the completed diff. That second review
found five more issues, four of which were real:

- `_sameBottle` re-derived remote fields from raw JSON with different
  defaults than `Ingredient.fromJson` uses. A pre-v7 export with
  `nicUnit` stripped was measured one way to permit the fuse and another
  way to perform it, and a `density: 0` payload blocked a legitimate
  dedup. Rewritten to compare parsed `Ingredient`s.
- A refused alias was indistinguishable from an ordinary add. Added
  `MergePlan.refusedByName` and a preview explanation.
- The pin diff rendered as bare `nicotine base` — the one recipe field
  that changes the dose, with nothing to judge it by. Now names the
  bottle and its strength.
- `# Mustard Milk` is a Markdown heading, and the comment skip silently
  lost it as the recipe title. Title position is now excepted.
- An explicit re-pick after the missing-base warning was discarded by the
  "preserve a dangling pin" logic, which could not tell a deliberate
  choice from an untouched selector. Tracked explicitly.

Also added `carrierVg` and `nicIsSalt` to `_ingredientDiff`: carrier
became identity-critical for dedup in the same commit, and an edit reading
as "no visible difference" would never sync.

## Files changed

```
 ROADMAP.md                                   |   9 +
 docs/release-notes-0.6.0-beta.1.md           | new
 lib/pages/calculator_page.dart               |  77 +++--
 lib/pages/merge_preview_page.dart            |  28 ++
 lib/recipe_import.dart                       |  47 ++-
 lib/state.dart                               |  11 +-
 lib/sync_merge.dart                          | 140 ++++++++-
 pubspec.yaml                                 |   2 +-
 test/calc_test.dart                          | 467 +++++++++++++++++++++
```

## Commands run

```
gh pr view/checks/diff 3      # review
gh pr merge 3 --merge         # merged, dfd8c80
git checkout main && git pull --ff-only
git checkout -b agent/pre-release-merge-and-export-fixes
flutter analyze               # clean
flutter test                  # 229 pass (was 207 at #3, 191 before it)
dart format                   # no changes
flutter build macos --release # succeeded, 47.7 MB
gh pr create                  # PR #4
gh pr checks 4                # test + all four build targets pass
```

Each behavioural change was verified by reverting it individually and
confirming its test fails. Thirteen such checks, all discriminating.

## Outcome

Tests: pass (229) | Lint: pass | Build: pass (macOS local; macOS, Windows,
Linux, Android on CI via PR #4)

- PR #3 merged: https://github.com/JettScythe/mixlab/pull/3
- PR #4 open with the fixes: https://github.com/JettScythe/mixlab/pull/4
- Version bumped `0.5.0-beta.1+9` → `0.6.0-beta.1+10`
- Release notes drafted at `docs/release-notes-0.6.0-beta.1.md`

## Notes

**No tag was created and nothing was published.** The release workflow
fires only on `refs/tags/v*`; the `release` job reports `skipping` on
PR #4, as expected. Publishing awaits explicit approval of the exact
version.

**Schema.** v10 at the last release, v12 now. Both bumps are version-only
with no transform, which is correct: `Recipe.fromJson` defaults the three
pin ids to null, and null is exactly the pre-v12 `firstOfKind` behaviour.
Downgrade is refused rather than attempted. No bump is owed by this
branch's changes.

**Assumption made.** The carrier gate applies to all ingredient kinds, not
just nicotine. For concentrates it is arguably heavy-handed — one install
annotating a carrier while the other leaves it at zero now keeps two
entries. Chosen because a visible refusal is better than a silent fuse,
and because a kind-dependent rule is a second thing to get wrong. Flagged
in the PR body and in ROADMAP's known issues.

**Deliberately not done.** `_ingredientDiff` still omits several fields;
`_fmtNumber` still emits float noise for `batchMl` and `targetNic` (the
ratio was the case that corrupted data, and it is fixed); notes dropped on
re-import are not reported in the import UI. All are follow-ups, none are
release blockers.

**Untested.** The two calculator changes are widget callbacks — the
re-pick tracking and the merged warning — which AGENTS.md exempts. The
roadmap's "smoke test that visits every tab" would cover the class.

**Session export:** not performed. No export capability was available in
this session. To export manually, use the OpenCode session export command
from the TUI (`ctrl+p` → export).
