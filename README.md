# MixLab
[![build](https://github.com/JettScythe/mixlab/actions/workflows/build.yaml/badge.svg)](https://github.com/JettScythe/mixlab/actions)
A weight-first e-liquid calculator with inventory, cost tracking, and a
guided weigh-along mode. Cross-platform desktop and mobile, built with
Flutter. All data stays on your machine.

The schema is young and the builds
are unsigned. Export a backup before upgrading.

## Why another one
![Weigh-along mode](docs/screenshots/weigh-along.png)
Most e-liquid calculators are volume-first tools with weights bolted on:
they compute mL, then multiply by a density constant at the end. That
falls apart in two places. A 100 mg/mL nicotine base in VG is roughly
1.26 g/mL, not the 1.036 a PG assumption gives you — a ~20% weight error
on the single most safety-relevant ingredient. And once you overpour a
flavor by 0.05 g, every downstream number in a static table is wrong,
with nothing telling you so.

MixLab treats the scale as the source of truth. Densities follow each
ingredient's actual carrier, the weigh-along mode shows cumulative
targets that shift when you overpour, and the mix log records what you
actually weighed rather than what was planned.

Stock works the same way. Every purchase, mix and correction is a ledger
entry, so what you have on hand is derived from what actually happened
and any entry can be undone without guessing at what it changed.



## Comparison

Rough positioning first:

| Tool | Form | Cost | Best at |
| --- | --- | --- | --- |
| MixLab | Native desktop + mobile | Free, open source | Weight-first mixing, local stash and cost tracking |
| eJuice Me Up | Windows desktop | Free | The classic; simple, offline, no longer maintained |
| e-liquid-recipes.com | Web | Free with paid tier | Huge shared recipe database and community |
| AllTheFlavors | Web | Free | Recipe discovery and flavor notes |
| Steam Engine | Web | Free | Precise calculation, coil and wicking tools |
| Spreadsheet | Whatever you build | Free | Total control, zero guardrails |

### Mixing

| Capability | MixLab | eJuice Me Up | ELR | ATF | Steam Engine |
| --- | --- | --- | --- | --- | --- |
| Weight output in grams | Yes | Yes | Yes | Yes | Yes |
| Per-ingredient density | Yes | Partial | Yes | Partial | Yes |
| Carrier-aware density (VG nic base, VG-carried flavors) | Yes | No | Partial | No | Partial |
| Achieved PG/VG shown vs target | Yes | No | Partial | No | Yes |
| Achieved nicotine recalculated after weighing | Yes | No | No | No | No |
| Batch volume preserved when concentrates overrun the ratio | Yes | No | Varies | Varies | Varies |
| Percent by weight instead of volume | Yes | No | Yes | No | Yes |
| Max-VG mode | Yes | Yes | Yes | Yes | Yes |
| Nicotine salts and mg/g bases | Yes | No | Yes | Partial | Yes |
| Additives excluded from flavor percentage | Yes | No | Yes | Yes | No |

### At the scale

| Capability | MixLab | eJuice Me Up | ELR | ATF | Steam Engine |
| --- | --- | --- | --- | --- | --- |
| Step-by-step weigh-along | Yes | No | No | No | No |
| Cumulative targets that adjust after an overpour | Yes | No | No | No | No |
| Scale resolution awareness with warnings | Yes | No | No | No | No |
| Screen kept awake while mixing | Yes | n/a | No | No | No |
| Logs real weighed amounts, not planned ones | Yes | No | No | No | No |

### Inventory and cost

| Capability | MixLab | eJuice Me Up | ELR | ATF | Steam Engine |
| --- | --- | --- | --- | --- | --- |
| Ingredient stash with stock levels | Yes | Partial | Yes | Yes | No |
| Automatic deduction when a mix is logged | Yes | No | Yes | No | No |
| Exact undo restoring the amounts deducted | Yes | No | No | No | No |
| Full stock ledger with a running balance | Yes | No | No | No | No |
| Adjustments with a reason (spill, evaporation, gift) | Yes | No | No | No | No |
| Cost per bottle and per reference volume | Yes | Yes | Yes | No | No |
| Choice of moving-average or FIFO cost basis | Yes | No | No | No | No |
| Restock log with shipping folded into the basis | Yes | No | No | No | No |
| Low-stock flags and filter | Yes | No | Yes | No | No |
| Shortfall check before you start mixing | Yes | No | Partial | No | No |
| Bottle, cap and shipping costs | Yes | No | Partial | No | No |
| Shows what you can mix from current stock | Yes | No | Partial | No | No |


### Recipes and history

| Capability | MixLab | eJuice Me Up | ELR | ATF | Steam Engine |
| --- | --- | --- | --- | --- | --- |
| Save and reload recipes | Yes | Yes | Yes | Yes | No |
| Seeded with DIY classics | Yes | No | n/a | n/a | No |
| Shared public recipe database | No | No | Yes | Yes | No |
| Import by pasting from ELR or AllTheFlavors | Yes | No | n/a | n/a | No |
| Export a recipe as shareable plain text | Yes | No | Yes | Yes | No |
| Recipe remembers which nic base and PG/VG it uses | Yes | No | No | No | No |
| Edit a saved recipe in place | Yes | Yes | Yes | Yes | n/a |
| Mix history with steep dates | Yes | No | Partial | No | No |
| Tasting notes and ratings | Yes | No | Yes | Yes | No |

### Platform and data

| Capability | MixLab | eJuice Me Up | ELR | ATF | Steam Engine |
| --- | --- | --- | --- | --- | --- |
| macOS | Yes | No | Browser | Browser | Browser |
| Windows | Yes | Yes | Browser | Browser | Browser |
| Linux | Yes | Wine | Browser | Browser | Browser |
| iOS and Android | Yes | No | Browser | Browser | Browser |
| Works fully offline | Yes | Yes | No | No | No |
| No account required | Yes | Yes | No | No | Yes |
| Data stored locally only | Yes | Yes | No | No | n/a |
| Full JSON export and import | Yes | Partial | Partial | Partial | n/a |
| Reviewable merge between two devices | Yes | No | n/a | n/a | n/a |
| Versioned schema with migrations | Yes | No | n/a | n/a | n/a |
| Open source | Yes | No | No | No | No |

Where MixLab loses: there is no recipe community, no library to browse,
and no way to discover what other people are mixing. That is the whole
reason ELR and AllTheFlavors exist, and MixLab does not try to replace
them — build a recipe there, paste it in here, mix it by weight. The two
work fine together.

It is also younger and less proven than eJuice Me Up, which has been
quietly correct for a decade.

## Features in detail

- Weight-first calculation with per-ingredient density derived from kind
  and carrier VG percentage
- Percentages by volume or by weight, and a max-VG mode
- Inventory with brand-aware search, stock levels, low-stock filtering
  and duplicate prevention
- Event-sourced stock: every purchase, mix and adjustment is a ledger
  entry, so stock is derived rather than edited in place and any entry
  can be undone
- Stock adjustments carry a reason — spill, evaporation, gift, disposal —
  so the ledger explains itself later
- Cost per mL, per bottle and per reference volume, with a choice of
  moving-average or FIFO basis that applies retroactively
- Pre-mix feasibility check listing exact shortfalls, and a "what can I
  make right now" capacity figure per recipe
- Weigh-along mode with cumulative targets, tare toggle, back-stepping
  and a commit step that logs real weights
- Mix history with steep-day counts, achieved nicotine and VG%, and
  exact undo that reverses the ledger entry
- Recipes that record which nicotine base and PG/VG they are mixed from
- Paste-import from ELR, AllTheFlavors, spreadsheets and forum posts;
  export any recipe back out as plain text
- JSON export, plus a reviewable merge that combines another device's
  backup with this one — every change can be declined individually
- Recovery screen if stored data ever fails to load, with a raw-data
  dump so nothing is lost


## Screenshots

| Calculator | Recipe editor |
| --- | --- |
| ![Calculator](docs/screenshots/calc-wide.png) | ![Recipe editor](docs/screenshots/recipe-edit.png) |

| Inventory | Mix history |
| --- | --- |
| ![Inventory](docs/screenshots/ingredients.png) | ![History](docs/screenshots/history.png) |
## Install

Download from [Releases](../../releases). Builds are unsigned, so each
platform will complain once.

macOS: extract, then double-click `mixlab.app`. macOS will block it
because the build is unsigned — open **System Settings → Privacy &
Security**, scroll to the message about mixlab, and click **Open
Anyway**. You only need to do this once.


Android: download `app-arm64-v8a-release.apk` and tap it. Android will
ask permission to install from an unknown source — allow it once.

```bash
tar -xzf mixlab-macos.tar.gz
open mixlab.app
```

On older macOS versions the block is a dead end with no override. In
that case, clear the quarantine flag manually:

```bash
xattr -dr com.apple.quarantine mixlab.app
```
Windows: unzip, run `mixlab.exe`. SmartScreen shows a warning —
"More info" then "Run anyway". Keep the whole folder together; the exe
needs its sibling DLLs and `data/`.

Linux:

```bash
tar -xzf mixlab-linux.tar.gz
./bundle/mixlab
```

## Build from source

Requires the Flutter SDK on the stable channel.

```bash
git clone https://github.com/jettscythe/mixlab.git
cd mixlab
flutter pub get
flutter run -d macos    # or windows, linux, chrome, or a device id
```

Platform toolchains: Xcode for macOS, Visual Studio 2022 with the
Desktop C++ workload for Windows, and on Debian-based Linux:

```bash
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev
```

Desktop apps cannot be cross-compiled — each target builds on its own OS.
CI covers all three.

```bash
flutter test
flutter analyze
dart format .
```

## Your data

Stored locally via `shared_preferences`, in the OS-standard location for
each platform. No network calls, no telemetry, no account.

Export from Settings before upgrading between betas. There are two ways
back in:

- **Merge** reviews another file against what is already here and
  combines them. Records match by id, then by brand and name, so the same
  bottle typed into two installs stays one ingredient. Every proposed
  change can be declined before anything is written.
- **Restore** discards everything local and replaces it with the file.

Both are safe to repeat — the same file twice changes nothing the second
time. Moving a backup between your own devices is the supported way to
run MixLab on more than one machine; there is no server and nothing syncs
in the background.

The schema is versioned with forward migrations. Loading data from a
newer build than the one you are running will refuse rather than
corrupt.

## Roadmap 

Planned work and known gaps: [ROADMAP.md](ROADMAP.md).

## Safety

Nicotine concentrate is genuinely hazardous. Wear nitrile gloves and eye
protection, work in a ventilated space, and store it away from children
and pets. This software is a calculator, not a safety device — verify
its output before you mix anything you intend to inhale.


## License

MIT. See [LICENSE](LICENSE).

