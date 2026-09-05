# Roadmap

Current release: desktop only (macOS,
Windows, Linux), unsigned builds.

This is a personal project shipped in the open. Priorities reflect what
is actually annoying while mixing, not what would look impressive. Items
move up when real use proves they matter.

Completed milestones are removed once their release ships, rather than
accumulating as checked boxes forever. Items checked off here are done on
`main` but not yet in a tagged build. See [Releases](../../releases) for
what actually shipped when.

## Principles

- **Correctness over features.** A calculator that is quietly wrong is
  worse than one that is missing something. Anything affecting grams,
  nicotine, or stock gets a test before it gets UI.
- **Local first.** No accounts, no telemetry, no network dependency.
  Data is a file you own and can export at any time.
- **Honest about gaps.** The README comparison table lists what MixLab
  does not do. That list stays accurate.
- **Destructive actions are always undoable** or always confirmed.


## v0.4 — Recipes in and out

The biggest reach item. MixLab has no recipe community and does not need
one, but it should interoperate with the places that do.

- [x] **Paste import** from e-liquid-recipes.com, AllTheFlavors,
      spreadsheet columns and forum posts. Vendor shorthands are
      normalised, unmatched lines are shown rather than dropped.
- [x] **FIFO cost basis** as an alternative to moving average, selectable
      in Settings and applied retroactively to the whole ledger.
- [x] **Single-recipe export** as shareable plain text, in the same
      dialect the paste importer reads.
- [x] **Recipe stores its bases.** A recipe can name the nicotine, PG and
      VG bottles it is mixed from instead of silently using whatever is
      selected. Leaving them unset keeps the old behaviour.
- [ ] **URL import** for the same sites, if the paste parser proves out.
- [ ] **CSV export** of inventory, recipes and mix history for
      spreadsheet users.
- [ ] **Recipe tags and favorites**, once the library outgrows search.

## v0.5 — Mobile

Deferred, not abandoned. The layouts already respond below 700px and
`shared_preferences` works on both platforms, so this is mostly
packaging.

- [x] **Android APK in CI.** Release signing via repository secrets,
      `--split-per-abi` for size, artifacts attached to releases.
      No ongoing cost, no expiry, sideload install. This is the easy
      one and will likely land first.
- [ ] **Android polish.** Verify the single-column calculator, the
      weigh-along at phone font scales, and Storage Access Framework
      export.
- [ ] **iOS personal builds.** Free provisioning works but profiles
      expire after 7 days, so it means rebuilding weekly. Needs a real
      bundle identifier and a signing team.
- [ ] **iOS export path.** `file_selector` has no save panel on iOS;
      the code falls back to clipboard. `share_plus` is the idiomatic
      fix.
- [x] **Backup transfer between devices.** Export on one, review and merge
      on the other. Records reconcile by id, then by brand and name;
      deletions propagate via tombstones. Still no server, and no
      background sync — you move the file yourself.
- [ ] **Multiple nicotine bases in one mix.** Blending two strengths means
  `calculateMix` taking a list and solving a small system for the mix.
  Meaningful work for something most mixers never do — a single base
  covers the normal case, and mg/g support closed the gap that actually
  mattered.


## v1.0 — Distribution

What separates "works on my machine" from "someone else can install it
without instructions."

- [ ] **macOS signing and notarization.** Requires Apple Developer
      Program membership (USD 99/year). Removes the misleading
      "damaged and can't be opened" block.
- [ ] **Windows code signing.** OV or EV certificate. Even signed, an
      OV cert accrues SmartScreen reputation slowly.
- [ ] **Installers.** MSIX or Inno Setup for Windows, DMG for macOS,
      AppImage or Flatpak for Linux.
- [ ] **In-app update check** against the GitHub releases API. Read
      only, no auto-download.

Signing is gated on whether anyone besides me is actually using this.
Until then, unsigned plus clear instructions is the right trade.

## Ongoing — Engineering

Not user-visible, but each one prevents a class of future bug.

- [ ] **Migrate storage to `drift`.** Everything currently lives in one
      JSON blob rewritten in full on every mutation. The mix log will
      outgrow that, and date/ingredient queries want SQL.
- [ ] **State management.** The root `ListenableBuilder` rebuilds all
      five pages on every keystroke. `provider` or `riverpod` when it
      starts to matter.
- [ ] **Immutable models with `copyWith`.** `logMix` currently mutates
      shared `Ingredient` instances, which is a foot-gun.
- [ ] **UUIDs instead of timestamp ids**, so merging backups from two
      installs cannot collide.
- [ ] **Widget and golden tests.** All current tests are model/state.
      A smoke test that pumps the app and visits every tab would catch
      layout exceptions that unit tests cannot see.
- [ ] **`very_good_analysis`** in place of stock `flutter_lints`.
- [ ] **Pin the Flutter version in CI** so local and CI cannot drift.

## Ongoing — UX

- [x] **Inline ingredient creation** from the flavor picker, so adding
      a recipe does not require abandoning it for the Inventory tab.
- [x] **Keyboard navigation** in the picker — arrow keys through results,
      Enter to take the highlighted one.
- [x] **`intl` currency formatting.** Totals go through
      `NumberFormat.simpleCurrency`, falling back to a plain suffix for
      codes `intl` does not know.
- [ ] **Per-mL and inline prices through `intl` too.** `moneyPerMl` and
      several hand-built labels still append the ISO code after the
      number, so the two styles sit side by side on the same screen.
- [x] **Theme toggle** and persisted window size and position.
- [ ] **Consistent breakpoints.** Navigation switches at 700px, the
      calculator at 980px, the editor at 900px. 700–980 wastes space.
- [ ] **Accessibility pass.** Semantics labels, tap target sizes,
      testing at large system font scales.
- [ ] **Per-flavor recommended percentage** and usage notes.
- [ ] **Steep reminders.** Local notifications at shake and taste
      milestones. Desktop support for this is uneven.
- [ ] **Nicotine expiry tracking.** It genuinely degrades; purchase
      dates are already recorded.
- [ ] **First-run guidance.** The seeded flavors have zero stock and
      zero cost, which makes cost figures read as `0.00` until the user
      fills them in. That is confusing without explanation.

## Known issues

- Seeded recipe percentages are commonly circulated versions and are
  **not authoritative**. Verify against original sources.
- Several entries in the brand shorthand map are unverified.
- The web build compiles but is untested. Browser storage limits make it
  a poor fit for an unbounded mix log; it may be dropped.
- Windows and Linux builds are produced by CI but have not been run by a
  human on real hardware.
- Merging matches ingredients by id, then by brand and name. Two installs
  that spell the same bottle differently — "TFA Strawberry Ripe" against
  "TPA Strawberry (Ripe)" — still merge as two ingredients.

## Not planned

- **Accounts, a sync server, or a hosted recipe database.** That means a
  server, a privacy policy, and an ongoing cost. Moving a backup between
  your own devices is supported and always will be; nothing phones home
  to do it. ELR and AllTheFlavors already do the community part well;
  MixLab is the local tool you mix with.
- **Telemetry of any kind.**
- **Nicotine sourcing, vendor links, or purchasing.**

## Contributing

Issues and pull requests are welcome. Anything touching the mixing math,
stock deduction, or the storage schema needs test coverage — see
`test/calc_test.dart` for the existing patterns, and bump
`AppState.currentSchema` with a migration if the stored shape changes.
