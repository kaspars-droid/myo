#!/bin/bash
# Packages Myo Calc.app as a .pkg the Mac App Store will accept.
#
# This is not Scripts/release-mac.sh with a different flag on the end. That
# one signs with Developer ID and notarises, which is what lets a person
# download the app and open it. The App Store takes neither: it wants the app
# sandboxed, signed with the distribution certificate, carrying a provisioning
# profile inside the bundle, and wrapped in an installer package.
#
#   Scripts/appstore-mac.sh    build ./Myo Calc.pkg
#
# The .pkg is then handed to Transporter, or to
#   xcrun altool --upload-app --type macos --file "Myo Calc.pkg" ...
#
# The provisioning profile is the one piece that cannot be made here. Download
# a Mac App Store profile for lv.cirsis.myo from the developer site and leave
# it at Scripts/Myo_Mac_App_Store.provisionprofile.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

TEAM_ID="BFE454ZWZZ"
APP="$root/Myo Calc.app"
PKG="$root/Myo Calc.pkg"
ENTITLEMENTS="$root/Scripts/Myo.entitlements"
PROFILE="$root/Scripts/Myo_Mac_App_Store.provisionprofile"

# The two certificates are looked up by team rather than written down, because
# the name on them is the account holder's and this should not care whose it
# is. Said plainly and early: each of these otherwise fails much later, in a
# way that reads as something else entirely.
identity() {
	security find-identity -v | grep -F "$1" | grep -F "($TEAM_ID)" \
		| head -1 | sed 's/.*"\(.*\)"/\1/'
}

# `|| true` because a grep that finds nothing exits non-zero, and set -e would
# take that as the script failing rather than as the answer being "none" —
# which is the case this is here to report.
APP_SIGN="$(identity "Apple Distribution:" || true)"
PKG_SIGN="$(identity "3rd Party Mac Developer Installer:" || true)"

[ -n "$APP_SIGN" ] || {
	echo "no Apple Distribution certificate for team $TEAM_ID" >&2
	echo "Xcode > Settings > Accounts > Manage Certificates > +" >&2
	exit 1
}
[ -n "$PKG_SIGN" ] || {
	echo "no Mac Installer Distribution certificate for team $TEAM_ID" >&2
	echo "Xcode > Settings > Accounts > Manage Certificates > +" >&2
	exit 1
}
[ -f "$PROFILE" ] || { echo "no provisioning profile at $PROFILE" >&2; exit 1; }

Scripts/build-mac-app.sh release

# The same two numbers the other scripts use, from the same two places, so a
# Mac build and a phone build of one release agree about what they are.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
	"$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" \
	"$APP/Contents/Info.plist"

# The profile goes inside the bundle under a fixed name. The App Store rejects
# the app if it is missing, and the name is not one it will guess at.
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Signing $VERSION ($BUILD) as $APP_SIGN"
# --deep is deliberately absent: it re-signs nested code with the outer
# entitlements, which is wrong, and Apple has said not to use it for years.
# There is nothing nested in this bundle to sign anyway.
codesign --force \
	--sign "$APP_SIGN" \
	--entitlements "$ENTITLEMENTS" \
	--options runtime \
	--timestamp \
	"$APP"

codesign --verify --strict --verbose=2 "$APP"

echo "==> Building $PKG"
rm -f "$PKG"
# The installer certificate signs the package, not the app. They are two
# different certificates with similar names, and swapping them produces an
# upload that is rejected after it has already been accepted.
productbuild \
	--component "$APP" /Applications \
	--sign "$PKG_SIGN" \
	"$PKG"

echo
echo "==> $PKG"
echo "    Upload it with Transporter, or:"
echo "    xcrun altool --upload-app --type macos --file \"$PKG\" \\"
echo "        --apiKey \"\$ASC_KEY_ID\" --apiIssuer \"\$ASC_ISSUER_ID\""
