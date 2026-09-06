# v0.7.0-beta.1 — draft

**Local draft.** No tag exists; `pubspec.yaml` reads `0.7.0-beta.1+11` on
the release branch. Tagging `v0.7.0-beta.1` triggers the publish workflow.

Compare: `v0.6.0-beta.1...v0.7.0-beta.1`

---

**Pre-release — unsigned builds.**

macOS: extract and double-click. When macOS blocks it, go to
System Settings → Privacy & Security and click "Open Anyway".
Older macOS: `xattr -dr com.apple.quarantine mixlab.app`
Windows: SmartScreen will warn — "More info" then "Run anyway".
Linux: `tar -xzf mixlab-linux.tar.gz && ./bundle/mixlab`

**Export a backup from Settings before upgrading.** This release moves the
storage schema from v12 to v13, and once a v13 store is written, v0.6.0
will refuse to open it.

---

## Recipe tags and favorites

The library was searchable but not organizable: everything sat in one
unsorted-except-manually pile, and finding a recipe meant remembering its
name.

Recipes can now be **starred** — the star sits on each card, and favorites
float to the top of every sort — and given **free-form tags** in the
editor (`fruits, desserts, all-day…`). Tags appear as chips on the card,
filter the library from a picker, and match search. Both sync across
devices: pin on one, find it pinned on the other.

Tags normalise themselves — trimmed, lowercased, deduplicated — so `Fruit`
and `fruit` are one label and a stray space can never make a tag
unsearchable.

## CSV export

Settings gains **"Export CSV"**: one file, three tables — inventory,
recipes, and mix history — for spreadsheet users. Numbers come out
unrounded, stock figures are replayed from the ledger exactly as the
inventory screen shows them, and money columns say which currency they
carry. Quoting is minimal but correct: embedded commas, quotes and line
breaks survive, and a recipe named `=1+1` stays text rather than
becoming a formula in Excel.

This is a one-way report for people who want their data in a spreadsheet.
The JSON backup remains the only format that imports back.

## Per-mL prices formatted like everything else

Per-mL figures keep their three decimals but now group thousands and match
the rest of the app's number formatting — `1,234.500 USD/mL` rather than
an ungrouped string. The recipe-detail footnote shows the locale's
currency symbol instead of appending the ISO code.

## Compatibility and data

- **Schema v12 → v13, version-only.** Both new fields are absent on
  pre-v13 data and read as unpinned/untagged — exactly the old behaviour —
  so no transform is needed and no field is discarded.
- **Downgrading is refused, not attempted**, as before: a v0.6.0 build
  reports a newer store and stops.
- **Backups and merges from older builds remain readable**, and importing
  the same file twice is still a no-op.
- The merge diff reports a pin change and names the incoming tags, so
  organisation changes propagate instead of vanishing.

## Known limitations

- Unchanged from v0.6.0-beta.1: unsigned builds; Windows and Linux
  produced by CI but not human-tested; web build untested; spelling
  variants of a bottle still merge as two; text export writes the VG/PG
  ratio as whole numbers.
- Tags are matched exactly in the filter picker; the search box remains
  the tool for partial matches.
- CSV export is one-way by design. It is not an import path.
