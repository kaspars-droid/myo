#!/bin/bash
# Turns the built app into one that can be handed to someone else.
#
# Scripts/build-mac-app.sh signs ad hoc, which is enough to run here and
# nothing more. This re-signs with Developer ID, which is what lets another
# machine open it at all, and notarises, which is what stops Gatekeeper
# warning about it first.
#
#   Scripts/release-mac.sh              build and sign
#   Scripts/release-mac.sh --notarize   also send it to Apple and staple
#
# Notarising uses an App Store Connect API key, the same one the phone build
# uploads with, so there is one credential to keep rather than two:
#
#   ASC_KEY_ID=... ASC_ISSUER_ID=... Scripts/release-mac.sh --notarize
#
# with the key itself at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

TEAM_ID="BFE454ZWZZ"
SIGN_ID="Developer ID Application: Arturs Cirsis ($TEAM_ID)"
APP="$root/Myo Calc.app"
ZIP="$root/Myo Calc.zip"

NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

# The bundle itself is assembled by the script that already does that, rather
# than a second copy of the same steps here.
Scripts/build-mac-app.sh release

# The version the app reports, taken from the tag so a release and its build
# agree without the number being written down in two places. The build number
# is the commit count, which only ever goes up.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
	"$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" \
	"$APP/Contents/Info.plist"

echo "==> Signing $VERSION ($BUILD) as $SIGN_ID"
# The hardened runtime is what notarisation requires; --timestamp is what keeps
# the signature valid after the certificate itself expires.
codesign --force --deep \
	--sign "$SIGN_ID" \
	--options runtime \
	--timestamp \
	"$APP"

codesign --verify --strict "$APP"

if [ "$NOTARIZE" = "1" ]; then
	: "${ASC_KEY_ID:?set ASC_KEY_ID (the API key id, e.g. ABC123DEF4)}"
	: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (the issuer uuid from the same page)}"
	KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
	[ -f "$KEY" ] || { echo "no key at $KEY" >&2; exit 1; }

	echo "==> Notarising"
	rm -f "$ZIP"
	ditto -c -k --keepParent "$APP" "$ZIP"

	xcrun notarytool submit "$ZIP" \
		--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
		--wait

	# Stapling writes the ticket into the bundle, so it opens on a machine
	# that cannot reach Apple to ask.
	xcrun stapler staple "$APP"

	# Zipped again, because the copy inside the first zip has no ticket.
	rm -f "$ZIP"
	ditto -c -k --keepParent "$APP" "$ZIP"
	echo "==> $ZIP is the one to hand out"
fi

echo
spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true
