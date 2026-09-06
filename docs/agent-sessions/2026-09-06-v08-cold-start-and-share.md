# Cold start, starter library, share-sheet export

Date: 2026-09-06 | Branch: `agent/v08-cold-start-and-share` |
Model: anthropic/claude-opus-5

## Goal

Plan, implement and release the next upgrade after real-device (Pixel)
feedback on v0.7: weigh-along works at phone font scales; CSV export
fell back to clipboard-only on Android. Scope approved: cold start with
no recipe seeds, ingredient seeds at zero stock, bundled starter recipe
library, share_plus for mobile export. URL import deferred to next
release (user decision).

## What happened

Scout mapped the seeding guard (per-key, so existing installs are
untouched by changing seed code), confirmed no assets system existed,
and flagged two tests asserting seed behavior plus `hardReset`.

First specialist review returned SHIP WITH FOLLOW-UP with a fix-before-
tag list; the headline catch: **Nana Cream's note line parsed back as a
phantom 2% ingredient** named after an entire English sentence — the
starter asset didn't use the `# ` comment convention `recipeToText`
invents for exactly this. Also: share_plus ignores `XFile.fromData`'s
name on IO platforms (needs `fileNameOverrides` or the user shares a
uuid-named file); the round-trip test was tautological; the first-run
calculator shows a red "Not enough stock" panel (all stock zero) —
follow-up; and Windows/Linux now build a new `jni` FFI plugin, so those
CI jobs had to be green before any tag.

All fix-before-tag items addressed; medium/low findings (share result
handling, byVolume forcing on starter imports, dead code removal,
mounted guard) fixed in the same pass. A4's never-re-seed invariant
test added.

## Files changed

```
 README.md                              |   4 +-
 ROADMAP.md                             |  10 ++-
 assets/starter-recipes.txt             |  new, 33 lines
 lib/models/recipe.dart                 |   6 ++
 lib/pages/import_page.dart             |  19 +++-
 lib/pages/recipes_page.dart            |  32 ++++-
 lib/pages/settings_page.dart           |  57 ++++++---
 lib/recipe_import.dart                 |   7 +-
 lib/state.dart                         | 121 ++++++--------
 lib/widgets/starter_library.dart       | new, 92 lines
 pubspec.yaml                           |   6 +-
 test/calc_test.dart                    | 119 +++++++++++-----
 test/widget_test.dart                  |  27 +++-
 linux/flutter/generated_plugin_*       |  jni FFI plugin (pub get output)
 windows/flutter/generated_plugin*      |  jni FFI plugin (pub get output)
 macos/Flutter/GeneratedPluginRegistrant| pub get output
```

## Commands run

```
git checkout -b agent/v08-cold-start-and-share
flutter pub add share_plus:^13.3.0
flutter analyze               # clean
flutter test                  # 240 pass (was 238)
dart format                   # no changes
flutter build macos --release # succeeded, 48.2 MB
gh pr create                  # PR #6
gh pr checks 6                # test + four build targets pass
```

## Outcome

Tests: pass (240) | Lint: pass | Build: pass (macOS local; all four
targets on CI via PR #6, including the new jni plugin surface)

- PR open: https://github.com/JettScythe/mixlab/pull/6
- Version `0.6.0-beta.1+10` → `0.8.0-beta.1+12` (corrects the v0.7
  build-number drift; build 11 skipped harmlessly)
- No schema change — seeding behavior is not persisted shape.

## Notes

- User decisions: cold start approved; URL import deferred (network +
  README amendment needs its own care); share_plus dependency approved.
- Reviewer's A1 finding stands unfixed: on a fresh install the calculator
  shows the red "Not enough stock" panel, since default 30 mL needs stock
  nobody has. A better first-run empty state on the calculator is a
  genuine follow-up; the roadmap box was ticked for the guidance that
  exists (starter library + zero-stock clarity), not for that panel.
- Follow-ups: factoryReset test; starter-picker-to-import end-to-end
  widget test; sharePositionOrigin for iPad popovers.

**Session export:** not performed; manual step is ctrl+p → export in the
OpenCode TUI.
