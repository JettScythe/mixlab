# Roadmap

Current release: `v0.1.0-beta.3` — schema v4, desktop only (macOS,
Windows, Linux), unsigned builds.

This is a personal project shipped in the open. Priorities reflect what
is actually annoying while mixing, not what would look impressive. Items
move up when real use proves they matter.

## Principles

- **Correctness over features.** A calculator that is quietly wrong is
  worse than one that is missing something. Anything affecting grams,
  nicotine, or stock gets a test before it gets UI.
- **Local first.** No accounts, no telemetry, no network dependency.
  Data is a file you own and can export at any time.
- **Honest about gaps.** The README comparison table lists what MixLab
  does not do. That list stays accurate.
- **Destructive actions are always undoable** or always confirmed.

## v0.2 — Mixing model completeness

The current engine assumes percentages are by volume, every concentrate
counts as flavor, and nicotine is measured in mg/mL. That covers most
DIY, not all of it.

- [x] **Percent by weight.** Per-recipe toggle stored on `Recipe`.
      Volume and weight percentages differ by up to ~20% on VG-heavy
      mixes, so the mode must be explicit and visible, never inferred.
      The README currently claims "weight-first" while percentages are
      volume-based — this closes that gap.
- [ ] **Max-VG mode.** No PG beyond what concentrates carry in. A large
      share of mixers work this way and it is currently inexpressible.
- [x] **Additive and thinner ingredient kinds.** Sucralose, WS-23, EM
      and distilled water behave like flavors but should not count
      toward the flavor percentage.
- [ ] **Nicotine salts and mg/g bases.** Requires a strength-unit field
      on `Ingredient` and a branch in the nicotine volume calculation.
- [ ] **Multiple nicotine bases in one mix**, for blending strengths.

## v0.3 — Cost accuracy

Cost per bottle is currently systematically low because it only counts
liquid.

- [ ] **Hardware costs.** Bottle, cap, and label as configurable
      per-batch line items.
- [ ] **Shipping amortization** spread across a purchase, so restocking
      reflects what an order actually cost.
- [ ] **Event-sourced stock.** Derive `stockMl` from purchases, mixes
      and manual adjustments rather than storing a mutable number. Makes
      cost history reconstructable and every adjustment auditable.
- [ ] **FIFO cost basis** as an alternative to weighted average.
- [ ] **Shopping list.** Low-stock ingredients plus what a selected
      recipe would need, with the shortfall per item.
- [ ] **"What can I make?"** — recipes fully mixable from current stock.

## v0.4 — Recipes in and out

The biggest reach item. MixLab has no recipe community and does not need
one, but it should interoperate with the places that do.

- [ ] **Paste import from ELR and AllTheFlavors.** Line-oriented, so a
      text parser gets most of the way. Brand matching against inventory
      is already tractable thanks to the `brand` field.
- [ ] **URL import** for the same sites, if the paste parser proves out.
- [ ] **Single-recipe export** as shareable plain text.
- [ ] **CSV export** of inventory, recipes and mix history for
      spreadsheet users.
- [ ] **Recipe tags and favorites**, once the library outgrows search.
- [ ] **Recipe stores its bases.** Currently a recipe records target
      nicotine and ratio but not *which* nic base or PG/VG source, so
      loading one silently uses whatever is selected.

## v0.5 — Mobile

Deferred, not abandoned. The layouts already respond below 700px and
`shared_preferences` works on both platforms, so this is mostly
packaging.

- [ ] **Android APK in CI.** Release signing via repository secrets,
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
- [ ] **Backup transfer between devices.** Export on desktop, import on
      phone. No sync is planned — that would mean a server.

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
- [ ] **Keyboard navigation** in the picker — arrow keys through
      results, not just type-and-Enter.
- [ ] **`intl` currency formatting.** Currently an ISO code appended
      after the number, which is wrong for most locales.
- [ ] **Theme toggle** and persisted window size and position.
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
- Importing another install's backup duplicates ingredients, because
  merging is by id with no name-based deduplication.

## Not planned

- **Accounts, sync, or a hosted recipe database.** That means a server,
  a privacy policy, and an ongoing cost. ELR and AllTheFlavors already
  do this well; MixLab is the local tool you mix with.
- **Telemetry of any kind.**
- **Nicotine sourcing, vendor links, or purchasing.**

## Contributing

Issues and pull requests are welcome. Anything touching the mixing math,
stock deduction, or the storage schema needs test coverage — see
`test/calc_test.dart` for the existing patterns, and bump
`AppState.currentSchema` with a migration if the stored shape changes.
