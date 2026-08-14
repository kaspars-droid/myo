# Myo

A line based calculator for macOS and iOS: text on the left, answers on the
right. One engine, two apps, and sheets that are plain text files — so they
sync through whatever drive holds them, open in any editor, and stay readable
without this app.

`Reckon` is the package name inside; `Myo` is the app. A sheet is a `.myocalc`
file, Myo's own: `.myo` alone belongs to an accounting package, close enough to
what this does to end up on the same machine.

## Layout

| Target | What it is |
| --- | --- |
| `ReckonCore` | Lexer, parser, evaluator, sheet model, local cache, folder watcher. No UI, no platform code. |
| `ReckonUI` | The sheet editor and result column, shared by both apps. |
| `ReckonMac` | The macOS app: a menu bar item with a panel. |
| `reckon` | Command line front end, useful for testing and scripting. |
| `myo/` | The iOS app. An Xcode project that links the same package. |

```bash
swift test                       # 87 tests
swift build -c release           # builds every target
.build/release/reckon "120 + 10%"
.build/release/reckon sheet.myocalc
.build/release/reckon sheet.myocalc --stats      # how much of it evaluates
.build/release/reckon sheet.myocalc --roundtrip  # would saving change a byte?
```

SwiftPM builds an executable, not an app bundle, so the macOS app is assembled
by a script rather than by Xcode:

```bash
Scripts/build-mac-app.sh          # produces Myo.app
open Myo.app
```

It signs ad hoc, which is enough to run on the machine that built it and not
enough to hand to anyone else. Handing it to someone else is a second script:

```bash
Scripts/release-mac.sh              # re-signs with Developer ID
Scripts/release-mac.sh --notarize   # and sends it to Apple, and staples
```

Developer ID is what lets another machine open the app at all; notarising is
what stops Gatekeeper warning about it first, and stapling writes the ticket
into the bundle so it opens on a machine that cannot reach Apple to ask. It
leaves `Myo.zip`, which is the thing to send.

The iOS app is an ordinary Xcode project in `myo/`:

```bash
Scripts/build-ios.sh              # archive and export build/myo.ipa
Scripts/build-ios.sh --upload     # and send it to App Store Connect
```

Both take the same App Store Connect API key, passed as `ASC_KEY_ID` and
`ASC_ISSUER_ID`, with the key itself at
`~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`. Uploading also needs an
app record already created there for the bundle identifier; it does not make
one. The build number comes from the commit count, because App Store Connect
refuses a number it has seen before.

The app icon is drawn rather than painted, by the same numbers as the mark in
the menu bar:

```bash
swift Scripts/make-icon.swift     # writes the 1024px icon into the catalogue
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
35eur oil change = € 35     an answer already in the file is ignored
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

Answers already in the file are re-attached to whatever lines still read the
same after an edit. Without that, one keystroke would strip them off every
other line and rewrite the whole file.

## The bar along the bottom

Everything in the result column is added up and shown at the foot of the
window. Totals already written into the sheet with `sum` are left out of it, so
nothing is counted twice, and each currency gets its own line.

## Money

```
€35      €  35      35€      35eur      35 EUR      100 CHF
```

Symbol or ISO code, before or after the amount, attached or spaced. Cents show
only when there are cents — `€35`, not `€35.00` — and the sign stays in front of
the symbol, so a negative total reads `-€7`.

Arithmetic carries the currency: `€10 * 3` is €30, `€120 + 10%` is €132, and a
plain number takes on the currency beside it, so `€40 + 2` is €42. Dividing two
amounts of the same currency gives a plain ratio: `€30 / €10` is 3.

There are no exchange rates, so mixing currencies is refused rather than
guessed: `€10 + $10` reports *Cannot mix EUR and USD without an exchange rate*.
Operations with no meaning for money, such as `sqrt(€16)` or `€2 ^ 2`, are
refused too. `abs`, `round`, `floor`, `ceil`, `min` and `max` keep the currency.

## What it does not understand yet

Units, dates, exchange rates, and natural language phrasing such as `5% on $30`
or `6% off 40 EUR`. Labels beside an amount *are* handled — see above.

## Status

Both apps work. The engine is the tested part: 87 tests covering arithmetic,
currency, comments, labelled amounts, the document model, the cache and the
folder watcher.

What is not there yet: no conflict handling anywhere — whoever writes last wins
— and on iOS no folder watching, so changes made elsewhere arrive when the app
is brought forward rather than as they happen.

## Opening a sheet

Myo reads `.myocalc` files. Only those appear in the sheet list, so a folder
can hold notes and other text without them showing up as sheets.

### An answer written into the file

Some calculators write their answer onto the end of each line, joined by a `=`
padded with non-breaking spaces rather than ordinary ones. That padding is what
makes such an answer safe to detect: an `=` typed by hand declares a variable
and has plain spaces around it, so the two can never be confused.

Where one is found, it is taken off the line and held to one side. The line you
edit is just what you wrote, the result column shows this engine's own answer,
and the stored one goes back to the file untouched. Editing a line drops its
stored answer, because an answer to text that has since changed is a lie.

Reading keeps every byte, which is what makes that safe. The command line
front end takes a path rather than an extension, so any text file can be put
through it to check:

```bash
reckon your-sheet.myocalc --roundtrip    # prints "identical" or "CHANGED"
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
in the same menu or with `cmd O`. Every `.myocalc` file in that folder joins
the list, and nothing else does.
Nothing is imported, indexed or copied into an app container, so the folder
keeps syncing through whatever drive it is on.

Opening a sheet from somewhere else, by double clicking it in the Finder,
moves the library to that sheet's folder, on the grounds that this is clearly
where you are working now. The folder and the open sheet are both remembered
for next launch.

In the list a sheet is called by its **first line**, not its file name, with any
`#` taken off the front: a sheet starting `# Q1 invoices` is listed as
"Q1 invoices". The file on disk is never renamed.

`+` writes a new `Untitled.myocalc` into that folder, and it is called Untitled
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

## On the phone

The iOS app is the same sheet and the same engine, forced to dark, with the
new-sheet and switch-sheet buttons in the navigation bar.

It keeps its own copy of the folder. Sheets in a cloud folder are fetched on
demand: opening one can be slow, and offline it may not arrive at all — so
`SheetCache` mirrors them onto the phone. Sheets open from the copy, and edits
are written to both. A placeholder that has never been downloaded is fetched
first, because a sheet with no text has no first line to be named after.

Choosing a folder replaces what was there: the list is the folder, not a pile
of everything ever opened.

**Google Drive and Dropbox do not work here**, and it is not something this app
can fix. Their File Provider extensions do not offer folder selection, so they
cannot appear in a folder picker at all. iCloud Drive and On My iPhone do.
Reaching Drive properly would mean talking to the Drive REST API — OAuth, a
Google Cloud project, a folder browser of its own.

## Sync

Sheets are plain UTF-8 text. That is the whole sync design: put them in a folder
that syncs and both apps open the same files.

Writes to a folder served by a cloud client go through `NSFileCoordinator`.
That client is another process watching for changes so it can upload them; an
uncoordinated write can be missed, or can collide with a download landing at
the same moment.

Nothing merges. **Whoever writes last wins.** Editing the same sheet on two
devices at once will lose one of the edits, silently. Worth knowing before
trusting it with anything that matters.

