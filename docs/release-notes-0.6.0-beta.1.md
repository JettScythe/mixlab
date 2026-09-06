# v0.6.0-beta.1 — draft

**Not published.** This is a local draft. No tag exists and none will be
created without explicit approval. `pubspec.yaml` reads `0.6.0-beta.1+10`
on the release branch; the tag `v0.6.0-beta.1` is what would trigger the
publish workflow.

Compare: `v0.5.0-beta.1...v0.6.0-beta.1`

---

**Pre-release — unsigned builds.**

macOS: extract and double-click. When macOS blocks it, go to
System Settings → Privacy & Security and click "Open Anyway".
Older macOS: `xattr -dr com.apple.quarantine mixlab.app`
Windows: SmartScreen will warn — "More info" then "Run anyway".
Linux: `tar -xzf mixlab-linux.tar.gz && ./bundle/mixlab`

**Export a backup from Settings before upgrading.** This release moves the
storage schema from v10 to v12, and once a v12 store is written, v0.5.0
and earlier will refuse to open it.

---

## Recipes remember which bottles they were mixed from

A recipe recorded `3 mg/mL` and a PG/VG target, but not *which* nicotine,
PG and VG delivered them. Loading one used whatever happened to be
selected at the time.

That is not cosmetic. A 100 mg/mL PG base and a 250 mg/mL VG base need
different volumes for the same target — 3 mL against 1.2 mL — and pull the
finished ratio in opposite directions. Under Max VG the same recipe lands
at 97% or 100% VG depending purely on which base was current when you
opened it.

Recipes can now name their nicotine, PG and VG in the recipe editor.
Leaving them unset means "no preference" and behaves exactly as before.
If a named bottle has since been deleted, the calculator falls back to
your current selection **and says so** rather than substituting silently.

## Two devices can share an inventory without duplicating it

Merging previously matched only on id, so two installs that each typed in
the same bottle ended up with two entries and their stock split across
both. Ingredients the other device knew under a different id are now
matched on brand and name, and everything that referenced them — recipes,
mix history, purchases, adjustments — is repointed at your copy.

A name match is only accepted when both records agree on kind, nicotine
strength and carrier. A shared label is not a shared bottle: merging feeds
the incoming record into last-write-wins, so fusing two different products
would quietly redefine what is in yours. When a match is refused, the
merge preview says how many and why, so a duplicate-looking entry is never
unexplained.

## Recipes can be copied out as plain text

Any recipe copies to the clipboard in the same format the paste importer
reads, so what MixLab shares, MixLab can read back — and it drops into a
forum post or a message unchanged. Notes and the base note are marked as
comments so re-importing cannot turn "add 1% sucralose if you like" into a
phantom ingredient.

## Fixes

- **"Restore (replace all)" in Settings did nothing.** The button was
  wired to a callback that was evaluated and discarded. Merge was
  unaffected.
- **Stock could double after an interrupted upgrade.** The v9 migration
  wrote opening balances before stamping the schema version, so a crash
  between the two re-ran it and appended a second opening balance.
- **Applying the same merge plan twice doubled stock.** Purchases and
  adjustments were appended with no id check, and no later replay could
  undo it.
- **A declined deletion still told other devices to delete.** The
  tombstone was folded even when you said no, and then blocked the record
  from ever syncing back.
- **Merging from an older device lost its inventory.** A pre-v9 peer's
  stock arrived reading zero; a pre-v2 peer's brands stayed glued to the
  name.
- **A missing density fell back to a shared 1.0 g/mL** — about 26% light
  on VG-carried stock. It now falls back to the ingredient's own kind and
  carrier.
- **An overpour with a zero density deducted nothing** and dropped out of
  the achieved nicotine and ratio.
- **A later purchase could re-price an outstanding deficit**, valuing
  liquid bought at 0.10 as though it cost 0.30 and inventing cost that was
  never spent.
- **The restock dialog always previewed a moving average**, showing FIFO
  users a figure the app would not use.
- **Corrupt data crashed instead of degrading.** Four enum reads threw on
  a bad index; three ledger mutators crashed on a stale id.
- **Recipe text export mangled fractional ratios.** A 62.5% VG target
  exported and read back as 5%, and float noise like
  `33.400000000000006` reached text you would paste to someone.
- **A recipe flavor whose bottle had been deleted exported as a bare
  "8%"** and re-imported as nothing.
- **Duplicating a recipe dropped its base pins**, so the copy mixed
  differently from the original.

## Documentation

The README contradicted itself: the "Where MixLab loses" section claimed
no in-place recipe editing, no by-weight percentages, no salts and no
additive handling, while four rows of its own comparison table said "Yes"
to all four. It also described import as merging by id while the button
next to that text replaced everything. The stock ledger, reasoned
adjustments, FIFO and device merge were undocumented. ROADMAP listed
three shipped features as unbuilt.

## Compatibility and data

- **Schema v10 → v12.** Both bumps are version-only; no stored data is
  transformed and no field is discarded. Every pre-v12 recipe reads as
  "no base preference", which is exactly how it behaved before.
- **Downgrading is refused, not attempted.** A v0.5.0 build asked to open
  a v12 store reports that the data is newer and stops, rather than
  writing back and dropping the fields it does not know.
- **Backups and merges from older builds are still readable.** Payloads
  from v1 onward are brought forward on import, opening balances included.
- **Importing the same file twice is still a no-op**, including across
  the new name-matching path.

## Known limitations

- Windows and Linux builds are produced by CI but have not been run by a
  human on real hardware. macOS and Android have.
- All builds are unsigned.
- Two installs that spell a bottle differently — "TFA Strawberry Ripe"
  against "TPA Strawberry (Ripe)" — still merge as two ingredients.
- A name match is refused when carrier or strength disagree, so one
  install annotating a concentrate's carrier while the other leaves it at
  zero keeps two entries. The preview explains this.
- Recipe text export writes the VG/PG ratio as whole numbers; the pasted
  dialect cannot express a fractional ratio, so 62.5% shares as 63/37.
  The stored target is unchanged.
- The web build compiles but is untested.
- Seeded recipe percentages are commonly circulated versions and are not
  authoritative.
