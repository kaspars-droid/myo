# Reckon

A line based calculator: text on the left, answers on the right. The engine is
shared between a Mac app and an iOS app, and sheets are plain text so they move
between the two as ordinary files.

Placeholder name, and nothing to do with Numi's code, which is closed source.
This is written from scratch.

## Layout

| Target | What it is |
| --- | --- |
| `ReckonCore` | Lexer, parser, evaluator, sheet model. No UI, no platform code. |
| `ReckonUI` | The SwiftUI sheet editor, shared by both apps. |
| `ReckonMac` | macOS app. |
| `reckon` | Command line front end, useful for testing and scripting. |

```bash
swift test                       # 18 tests
swift build -c release           # builds every target
.build/release/reckon "120 + 10%"
.build/release/reckon sheet.txt
```

## What the engine understands

```
# everything after a hash is hidden from the math, and drawn in orange
10 + 5   # including a note at the end of a working line

// double slashes work the same way

rate = 0.21          variables, including multi word names
car repair = 350
net * rate

2 + 3 * 4            precedence, parentheses, ^ (right associative)
0.1 + 0.2            decimal arithmetic, so money adds up exactly
10 ÷ 4               typographic operators too

20% of 300           percentages
120 + 10%            percent of the left hand side
sqrt(16)             sqrt abs round floor ceil min max pow log ln

10
20
sum                  sum, total, avg of the block above
prev                 the line before
line 2               a line by number
```

A blank line ends a block, so one sheet can hold several tallies. A subtotal
also ends its block, so totalling again lower down does not fold the earlier
total back in and count those numbers twice.

## Figures with words beside them

A line can say what its figure is for, on either side of it:

```
35eur oil change
oil change 35eur
10 + 5 apples
35eur oil change = € 35     a result Numi left in the file is ignored
```

Only whole words are stepped over. A line with more arithmetic in it than the
calculator can finish, such as `2 apples and 3 oranges` or `bananas * 3`, stays
prose rather than being salvaged from the middle and quietly losing half of
itself.

Anything that does not parse is left alone as prose. A sheet is mostly prose,
and that is the point.

A comment or a line of prose is stepped over rather than treated as a divider,
so annotating a column does not cut the column in half. Only a blank line
separates one tally from the next.

## Editing

The sheet is one text view, not a field per line, so everything a text editor
does works here: selecting across lines, select all, undo, tab, return,
backspace joining a line to the one above.

That decides how the results are laid out. The text view measures where each
logical line sits and hands those positions back, and each result is placed
against its own line. A line that wraps over several rows keeps its answer
level with where the line starts.

Numi's answers are re-attached to whatever lines still read the same after an
edit. Without that, one keystroke would strip the answers off every other line
and rewrite the whole file.

## The bar along the bottom

Everything in the result column is added up and shown at the foot of the
window. Totals already written into the sheet with `sum` are left out of it, so
nothing is counted twice, and each currency gets its own line.

## Money

```
€35      €  35      35€      35eur      35 EUR      100 CHF
```

Symbol or ISO code, before or after the amount, attached or spaced. Amounts are
formatted to the cent, with the sign in front of the symbol (`-€7.00`).

Arithmetic carries the currency: `€10 * 3` is €30, `€120 + 10%` is €132, and a
plain number takes on the currency beside it, so `€40 + 2` is €42. Dividing two
amounts of the same currency gives a plain ratio: `€30 / €10` is 3.

There are no exchange rates, so mixing currencies is refused rather than
guessed: `€10 + $10` reports *Cannot mix EUR and USD without an exchange rate*.
Operations with no meaning for money, such as `sqrt(€16)` or `€2 ^ 2`, are
refused too. `abs`, `round`, `floor`, `ceil`, `min` and `max` keep the currency.

## What it does not understand yet

A label after an amount (`35eur oil change`), units, dates, and natural language
phrasing such as `5% on $30` or `6% off 40 EUR`.

## Status

- Core compiles and passes its tests on macOS, and typechecks against both the
  iOS simulator and iOS device SDKs.
- `ReckonUI` typechecks for iOS.
- The Mac app builds, launches, and opens a window.
- There is no Xcode project yet, so there is no iOS `.app` target. SwiftPM
  cannot produce one. No simulator runtime is installed on this machine either,
  so the iOS build has been compiled but never run.

## Opening a sheet

Myo reads `.numi` files. Only `.numi` files appear in the sheet list, so a
folder can hold notes and other text without them showing up as sheets.

### Numi's answers

Numi writes its answer onto the end of each line, joined by a `=` padded with
non-breaking spaces rather than ordinary ones. That padding is what makes the
answer safe to detect: an `=` typed by hand declares a variable and has plain
spaces around it, so the two can never be confused. In the author's own sheets
all 140 of the `=` signs are Numi's, not one is typed.

So the answer is taken off the line and held to one side. The line you edit is
just what you wrote, the result column shows this engine's own answer, and the
stored one goes back to the file untouched. Editing a line drops its stored
answer, because an answer to text that has since changed is a lie.

Reading keeps every byte. That is checked against every sheet in the author's own Numi
folder:

```bash
reckon your-sheet.numi --roundtrip    # prints "identical" or "CHANGED"
```

## In the menu bar

Myo lives in the menu bar as a `Σ` and nowhere else: no Dock icon, no
application menu. Clicking it drops the sheet down, with the name across the
middle and the new-sheet and switch-sheet buttons on the right.

Right clicking the icon offers **Quit Myo**. Left clicking drops the sheet
down.

Since there is no application menu, the sheet menu inside the panel carries
what would normally live there: **Open in a Window**, for when a sheet wants
more room, and **Quit Myo** again.

The menu bar item is a plain `NSStatusItem` rather than SwiftUI's
`MenuBarExtra`. `MenuBarExtra` has no answer for a right click, and it insets
its panel, which leaves a lighter frame showing around the sheet.

## Several sheets

Two buttons sit at the top right. `+` starts a new sheet, and the three lines
open the list of sheets to switch between. Both swap the sheet **in the window
you are in**; the app is one window, not one window per file.

A sheet is a file, and the library is a folder you pick: **Select Folder…**,
in the same menu or with `cmd O`. Every `.numi` file in that folder joins the
list, and nothing else does.
Nothing is imported, indexed or copied into an app container, so the folder
keeps working in Numi and keeps syncing through whatever drive it is on.

Opening a sheet from somewhere else, by double clicking it in the Finder,
moves the library to that sheet's folder, on the grounds that this is clearly
where you are working now. The folder and the open sheet are both remembered
for next launch.

In the list a sheet is called by its **first line**, not its file name, with any
`#` taken off the front: a sheet starting `# Q1 invoices` is listed as
"Q1 invoices". The file on disk is never renamed.

`+` writes a new `Untitled.numi` into that folder, and it is called Untitled
until its first line says otherwise. With no folder chosen yet it asks for one
first.

An empty sheet is scratch. Switching away from one throws it out instead of
leaving a trail of blank files, so pressing `+` twice does not leave a stray
Untitled behind. A discarded sheet goes to the **trash**, not the void: the app
is guessing that you are finished with it, and a guess about someone else's
document should be recoverable. A sheet with anything in it is never touched.

Sheets are written back 600ms after you stop typing, and never written at all
unless something changed. The sheet you had open reopens next launch.

The folder is re-read whenever the panel is opened, and whenever the app is
brought to the front. A menu bar app sits there for days, so "opening it" means
opening the panel, and by then the phone or another Mac may have moved the
folder on. A pending edit of your own is written back before the re-read, so
nothing you typed is lost to it. Nothing watches the folder while the panel is
shut.

## Sync

Sheets are plain UTF-8 text. That is the whole sync design: put them in iCloud
Drive, Dropbox, or Google Drive and both apps open the same files. Numi's own
documents are plain text too, so they can be opened directly.

Syncing with Numi's *internal* store is not possible. Its iCloud container is
bound to its developer's team identifier, which Apple does not let another app
read.
