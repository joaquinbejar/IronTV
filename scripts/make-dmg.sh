#!/bin/bash
# Build, verify and package a distributable DMG from a fresh Release build.
# Usage: scripts/make-dmg.sh
#        IRONTV_NOTARIZE=0 scripts/make-dmg.sh   # skip Developer ID + notarization
# Output: dist/IronTV-<version>.dmg (absolute path echoed on the last line)
#
# The flow guarantees the DMG contains exactly the build it produced:
# project regenerated from project.yml, build isolated in a temporary
# derived-data directory, and the packaged app asserted against the source
# of truth (versions, architectures, frameworks, entitlements, signature,
# Gatekeeper, notarization) before success is reported.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

DERIVED=""
STAGING=""
cleanup() {
    if [[ -n "$DERIVED" ]]; then rm -rf "$DERIVED"; fi
    if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
}
trap cleanup EXIT

# --- Preflight (offline, before the multi-minute build) ---------------------

command -v xcodegen >/dev/null 2>&1 \
    || die "xcodegen not found. Install it with: brew install xcodegen"

# The .xcodeproj is generated and gitignored; regenerate so the release can
# never lag project.yml.
echo "Regenerating Xcode project from project.yml…"
(cd "$REPO" && xcodegen generate) || die "xcodegen generate failed — fix project.yml before releasing."

# project.yml is the source of truth for versions; xcodegen has just written
# them into Sources/Info.plist, so read the expectation from there.
EXPECTED_VERSION=$(plutil -extract CFBundleShortVersionString raw "$REPO/Sources/Info.plist") \
    || die "Cannot read CFBundleShortVersionString from generated Sources/Info.plist."
EXPECTED_BUILD=$(plutil -extract CFBundleVersion raw "$REPO/Sources/Info.plist") \
    || die "Cannot read CFBundleVersion from generated Sources/Info.plist."
echo "Expected app version: $EXPECTED_VERSION ($EXPECTED_BUILD)"

# Announce the signing outcome early so a missing Developer ID surfaces now,
# not after the build. The decisive check still inspects the built app.
NOTARY_PROFILE="irontv-notary"
DEVELOPER_ID_AVAILABLE=false
if [[ "${IRONTV_NOTARIZE:-1}" == "0" ]]; then
    echo "IRONTV_NOTARIZE=0 — deliberately building an un-notarized DMG (local use)."
elif security find-identity -v -p codesigning 2>/dev/null | grep -F "Developer ID Application" >/dev/null; then
    DEVELOPER_ID_AVAILABLE=true
    echo "Developer ID Application identity found — will notarize with keychain profile '$NOTARY_PROFILE'."
else
    echo "WARNING: no Developer ID Application identity in the keychain." >&2
    echo "         The DMG will NOT be notarized (fine for local use)." >&2
    echo "         For a distributable build, install the 'Developer ID Application' certificate for team 5NP3LPSUMR." >&2
fi

# --- Build into a fresh, explicit derived-data directory --------------------

DERIVED=$(mktemp -d -t irontv-deriveddata)
WORK="$DERIVED/irontv-verify"
mkdir -p "$WORK"
ARCHIVE="$DERIVED/IronTV.xcarchive"

echo "Archiving Release (derived data: $DERIVED)…"
# -allowProvisioningUpdates: the keychain-access-groups entitlement is
# restricted, so the app needs an embedded provisioning profile.
# No `clean` needed: the derived-data directory is brand new.
xcodebuild archive -project "$REPO/IronTV.xcodeproj" -scheme IronTV -configuration Release \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates -quiet

# The app path is derived from the archive we just produced — never searched
# for in the global DerivedData, where another checkout or Xcode could win.
if [[ "$DEVELOPER_ID_AVAILABLE" == true ]]; then
    # A plain build/archive signs with Apple Development, which can never be
    # notarized. Export re-signs with Developer ID under automatic signing —
    # the supported way to get a notarizable app without manual profiles.
    cat > "$WORK/export-options.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>5NP3LPSUMR</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF
    echo "Exporting with Developer ID signing…"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$WORK/export-options.plist" \
        -exportPath "$DERIVED/export" -allowProvisioningUpdates \
        || die "Developer ID export failed. If the error above says 'No Accounts', open Xcode → Settings → Accounts and sign in with the Apple ID for team 5NP3LPSUMR (the export mints the Developer ID provisioning profile through that account), then re-run. For a local un-notarized build instead, re-run with IRONTV_NOTARIZE=0."
    APP="$DERIVED/export/IronTV.app"
else
    APP="$ARCHIVE/Products/Applications/IronTV.app"
fi
[[ -d "$APP" ]] || die "Built app not found at $APP."

# --- Verify the built app matches the requested configuration ---------------

echo "Verifying built app…"

ACTUAL_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
ACTUAL_BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" && "$ACTUAL_BUILD" == "$EXPECTED_BUILD" ]] \
    || die "Version mismatch: packaged app is $ACTUAL_VERSION ($ACTUAL_BUILD), project.yml says $EXPECTED_VERSION ($EXPECTED_BUILD)."

APP_ARCHS=$(lipo -archs "$APP/Contents/MacOS/IronTV")
[[ " $APP_ARCHS " == *" arm64"* && " $APP_ARCHS " == *"x86_64"* ]] \
    || die "App binary is missing an architecture slice (found: $APP_ARCHS, need arm64 and x86_64)."

# The app links VLCKitSPM, so at least one embedded framework is expected;
# every one must be universal and correctly signed.
FRAMEWORK_COUNT=0
for FRAMEWORK in "$APP/Contents/Frameworks"/*.framework; do
    [[ -d "$FRAMEWORK" ]] || continue
    FRAMEWORK_COUNT=$((FRAMEWORK_COUNT + 1))
    NAME=$(basename "$FRAMEWORK" .framework)
    BINARY=""
    for CANDIDATE in "$FRAMEWORK/$NAME" "$FRAMEWORK/Versions/A/$NAME"; do
        if [[ -f "$CANDIDATE" ]]; then BINARY="$CANDIDATE"; break; fi
    done
    [[ -n "$BINARY" ]] || die "Embedded framework $NAME has no binary."
    FW_ARCHS=$(lipo -archs "$BINARY")
    [[ " $FW_ARCHS " == *" arm64"* && " $FW_ARCHS " == *"x86_64"* ]] \
        || die "Embedded framework $NAME is missing an architecture slice (found: $FW_ARCHS)."
    codesign --verify --strict "$FRAMEWORK" \
        || die "Embedded framework $NAME fails signature verification."
done
[[ "$FRAMEWORK_COUNT" -ge 1 ]] || die "No embedded frameworks found — VLCKitSPM did not embed."

codesign --verify --deep --strict "$APP" \
    || die "App fails deep signature verification."

# Assert the signed entitlements carry what the app needs at runtime.
ENTITLEMENTS="$WORK/entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null \
    || die "Cannot read signed entitlements."
plutil -convert xml1 "$ENTITLEMENTS"
entitlement_is_true() {
    /usr/bin/awk -v key="<key>$1</key>" \
        'index($0, key) { getline; if (index($0, "<true/>")) found = 1 } END { exit !found }' \
        "$ENTITLEMENTS"
}
entitlement_is_true "com.apple.security.app-sandbox" \
    || die "Signed entitlements missing app-sandbox=true (Mac App Store requirement)."
entitlement_is_true "com.apple.security.network.client" \
    || die "Signed entitlements missing network.client=true (IPTV connections would fail)."
grep -q -F "com.taunais.irontv</string>" "$ENTITLEMENTS" \
    || die "Signed entitlements missing the com.taunais.irontv keychain access group."
grep -q -F "<key>com.apple.developer.ubiquity-kvstore-identifier</key>" "$ENTITLEMENTS" \
    || die "Signed entitlements missing the iCloud KVS identifier."

# Note: no `grep -q` on the codesign pipe — with pipefail, an early exit
# SIGPIPEs codesign and randomly fails the check.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)
WILL_NOTARIZE=false
if [[ "$IDENTITY" == "Developer ID"* ]]; then
    WILL_NOTARIZE=true
elif [[ "$DEVELOPER_ID_AVAILABLE" == true ]]; then
    die "Developer ID signing was requested but the app is signed with '${IDENTITY:-ad-hoc/unsigned}'."
fi

echo "App verified: $ACTUAL_VERSION ($ACTUAL_BUILD), archs [$APP_ARCHS], $FRAMEWORK_COUNT framework(s), identity '${IDENTITY:-ad-hoc/unsigned}'."

# --- Package ----------------------------------------------------------------

DIST="$REPO/dist"
STAGING=$(mktemp -d -t irontv-staging)
mkdir -p "$DIST"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Notarized DMGs open cleanly everywhere; only un-notarized builds need the
# quarantine workaround shipped alongside.
[[ "$WILL_NOTARIZE" == true ]] || cat > "$STAGING/READ ME - Installation.txt" <<'EOF'
IronTV — Installation

1. Drag IronTV.app into the Applications folder.

2. macOS will refuse to open the app ("IronTV.app can't be opened")
   because this build is not notarized by Apple yet.

   Fix: open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/IronTV.app

   Then open IronTV normally.

   Alternative: System Settings > Privacy & Security > "Open Anyway"
   (if the option appears after trying to open the app).
EOF

DMG="$DIST/IronTV-$ACTUAL_VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "IronTV" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

# Sign the DMG with the same identity as the app (Developer ID when available).
if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict "$DMG" || die "DMG fails signature verification."
fi

# --- Notarize and gate on Gatekeeper (Developer ID builds only) -------------

if [[ "$WILL_NOTARIZE" == true ]]; then
    echo "Notarizing (this can take a few minutes)…"
    NOTARY_LOG="$WORK/notary.log"
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$NOTARY_LOG"; then
        echo "" >&2
        echo "Notarization submission failed." >&2
        echo "  - If the error above says the keychain profile was not found, create it with:" >&2
        echo "      xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your-apple-id> --team-id 5NP3LPSUMR" >&2
        echo "  - If it looks like a transient Apple service error, re-run this script." >&2
        die "DMG was created but is NOT notarized: $DMG"
    fi
    # notarytool can exit 0 on an Invalid submission — gate on the status.
    grep -q -F "status: Accepted" "$NOTARY_LOG" \
        || die "Notarization was not accepted (see log above): $DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG" || die "Stapled ticket fails validation."
    spctl -a -t open --context context:primary-signature "$DMG" \
        || die "Gatekeeper rejected the notarized DMG."
    NOTARIZED="yes (stapled, Gatekeeper-accepted)"
else
    echo "WARNING: DMG NOT notarized (app not signed with Developer ID)." >&2
    NOTARIZED="no"
fi

# --- Report -----------------------------------------------------------------

echo ""
echo "Release verified:"
echo "  Version:       $ACTUAL_VERSION ($ACTUAL_BUILD)"
echo "  Architectures: $APP_ARCHS"
echo "  Identity:      ${IDENTITY:-ad-hoc/unsigned}"
echo "  Notarized:     $NOTARIZED"
echo "Created: $DMG"
