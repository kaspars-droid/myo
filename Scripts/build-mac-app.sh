#!/bin/bash
# Assembles Myo Calc.app from the package.
#
# SwiftPM builds an executable, not an app bundle, so the bundle is put
# together here: the binary, an Info.plist, and an ad hoc signature. There is
# no Xcode project for the Mac app and it does not need one.
#
#   Scripts/build-mac-app.sh            release build (default)
#   Scripts/build-mac-app.sh debug      faster, for trying something out

set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/Myo Calc.app"

# Homebrew can leave xcode-select pointing at the Command Line Tools, which
# have no XCTest and no iOS SDKs. Xcode itself is what this needs.
if [ -d /Applications/Xcode.app ]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$root"
swift build -c "$configuration" --product ReckonMac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/ReckonMac" "$app/Contents/MacOS/Myo Calc"
cp "$root/Scripts/Myo-Info.plist" "$app/Contents/Info.plist"

# The app's icon, and the one a .myocalc sheet wears in the Finder. Drawn by
# Scripts/make-icon.swift; run that after changing the mark.
cp "$root/Scripts/Icons/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Scripts/Icons/Document.icns" "$app/Contents/Resources/Document.icns"

# Ad hoc: enough to run on this machine, not enough to hand to anyone else.
codesign --force --sign - "$app"

printf '\nBuilt %s\n' "$app"
printf 'Open it with: open "%s"\n' "$app"
