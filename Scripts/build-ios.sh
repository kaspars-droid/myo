#!/bin/bash
# Archives the iOS app and exports an IPA signed for TestFlight.
#
#   ./scripts/build-ios.sh              archive and export ./build/myo.ipa
#   ./scripts/build-ios.sh --upload     also send it to App Store Connect
#
# Uploading needs an App Store Connect API key, stored once as three values
# below. A key is made at appstoreconnect.apple.com → Users and Access →
# Integrations → App Store Connect API, and the .p8 it hands over is only
# downloadable that once. Put it in ~/.appstoreconnect/private_keys/ where
# xcodebuild looks for it by key id.
#
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="BFE454ZWZZ"
SCHEME="myo"
PROJECT="myo/myo.xcodeproj"
OUT="build"
UPLOAD=0
[ "${1:-}" = "--upload" ] && UPLOAD=1

# Xcode's IPA step shells out to rsync with flags only Apple's own build of it
# takes. A Homebrew rsync earlier in PATH answers "syntax or usage error" and
# the export fails at the very last step, so the system one is put first.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

rm -rf "$OUT"
mkdir -p "$OUT"

# App Store Connect refuses a build whose number it has already seen, and the
# number is easy to forget to raise. The commit count answers that on its own:
# it only ever goes up, and it says which commit a build came from.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Archiving $SCHEME  (build $BUILD)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
	-destination 'generic/platform=iOS' \
	-archivePath "$OUT/myo.xcarchive" \
	-allowProvisioningUpdates \
	CURRENT_PROJECT_VERSION="$BUILD" \
	archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>		<string>app-store-connect</string>
	<key>teamID</key>		<string>$TEAM_ID</string>
	<key>uploadSymbols</key>	<true/>
	<key>signingStyle</key>		<string>automatic</string>
	<key>destination</key>		<string>export</string>
</dict>
</plist>
PLIST

echo "==> Exporting IPA"
xcodebuild -exportArchive \
	-archivePath "$OUT/myo.xcarchive" \
	-exportPath "$OUT" \
	-exportOptionsPlist "$OUT/ExportOptions.plist" \
	-allowProvisioningUpdates

# The archive itself is signed for development; the distribution signature is
# put on during export. So it is the IPA that has to be looked at, not the
# archive, or this reports the wrong certificate.
echo "==> Signed with:"
rm -rf "$OUT/verify"
mkdir -p "$OUT/verify"
(cd "$OUT/verify" && unzip -q "../myo.ipa")
codesign -dvvv "$OUT/verify/Payload/myo.app" 2>&1 \
	| grep -E "Authority=Apple Distribution|TeamIdentifier|^Identifier="
rm -rf "$OUT/verify"

if [ "$UPLOAD" = "1" ]; then
	: "${ASC_KEY_ID:?set ASC_KEY_ID (the API key id, e.g. ABC123DEF4)}"
	: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (the issuer uuid from the same page)}"

	echo "==> Uploading to App Store Connect"
	# The app record must already exist there for this bundle id; upload does
	# not create one.
	xcrun altool --upload-app \
		--type ios \
		--file "$OUT/myo.ipa" \
		--apiKey "$ASC_KEY_ID" \
		--apiIssuer "$ASC_ISSUER_ID"

	echo "==> Uploaded. It appears in TestFlight once Apple finishes processing."
fi

echo
echo "==> $OUT/myo.ipa"
