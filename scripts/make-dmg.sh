#!/bin/bash
# Build a distributable DMG from the Release build.
# Usage: scripts/make-dmg.sh
# Output: dist/IronTV-<version>.dmg
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Clean build so a stale incremental Release can't ship an old Info.plist.
echo "Building Release…"
# -allowProvisioningUpdates: the keychain-access-groups entitlement is
# restricted, so the app needs an embedded provisioning profile.
xcodebuild -project "$REPO/IronTV.xcodeproj" -scheme IronTV -configuration Release \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
    -allowProvisioningUpdates clean build -quiet

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/IronTV-*/Build/Products/Release/IronTV.app 2>/dev/null | head -1)
if [[ -z "${APP:-}" ]]; then
    echo "Release build not found after building." >&2
    exit 1
fi

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
DIST="$REPO/dist"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$DIST"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Notarized DMGs open cleanly everywhere; only un-notarized builds need the
# quarantine workaround shipped alongside. Gate on the signing identity only —
# probing the notary service here (network call) proved flaky. Note: no
# `grep -q` on the codesign pipe — with pipefail, grep's early exit SIGPIPEs
# codesign and randomly fails the check.
NOTARY_PROFILE="irontv-notary"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)
WILL_NOTARIZE=false
if [[ "$IDENTITY" == "Developer ID"* ]]; then
    WILL_NOTARIZE=true
fi

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

DMG="$DIST/IronTV-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "IronTV" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

# Sign the DMG with the same identity as the app (Developer ID when available).
if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

echo "Created: $DMG"
echo "App signature: $(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 || echo 'ad-hoc/unsigned')"

# Notarize + staple when possible; otherwise ship un-notarized (local use).
if [[ "$WILL_NOTARIZE" == true ]]; then
    echo "Notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Notarized and stapled."
else
    echo "WARNING: DMG NOT notarized (missing Developer ID identity or notary profile '$NOTARY_PROFILE')." >&2
fi
