#!/bin/bash
# Builds a notarized ClangNotch release at ~/Desktop/ClangNotch.dmg (or $OUT).
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain (Apple Developer Program;
#     Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)
#   - notarytool credentials stored under the profile "clangnotch" (or $NOTARY_PROFILE):
#       xcrun notarytool store-credentials clangnotch --apple-id <Apple ID> --team-id <team ID>
#
# The version comes from the project (MARKETING_VERSION / CURRENT_PROJECT_VERSION); bump it
# before running. The app and the disk image are each notarized and stapled, so the app
# opens without a warning even offline and the in-app updater accepts it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${NOTARY_PROFILE:-clangnotch}"
OUT="${OUT:-$HOME/Desktop/ClangNotch.dmg}"

identity_line=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' | head -1 || true)
if [ -z "$identity_line" ]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    exit 1
fi
identity=$(sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' <<<"$identity_line")
# By hash: two certificates with one name (a renewal) make the name ambiguous to codesign.
identity_hash=$(awk '{print $2}' <<<"$identity_line")
team=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$identity")
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials under \"$PROFILE\". Run once in a terminal:" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id $team" >&2
    exit 1
fi
echo "Signing as: $identity"

for check in "$ROOT"/tests/*.py; do
    python3 "$check" >/dev/null || { echo "Check failed: $check" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The status says how it went: notarytool can exit 0 for a rejected submission, and
# non-zero for one whose log is still worth reading.
notarize() {
    local result status id
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) || true
    status=$(plutil -extract status raw - <<<"$result" 2>/dev/null) || true
    if [ "$status" != "Accepted" ]; then
        echo "Notarizing $(basename "$1") came back \"$status\":" >&2
        echo "$result" >&2
        id=$(plutil -extract id raw - <<<"$result" 2>/dev/null) || true
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
    echo "Notarized: $(basename "$1")"
}

xcodebuild -project "$ROOT/ClangNotch.xcodeproj" -scheme ClangNotch -configuration Release \
    -archivePath "$work/ClangNotch.xcarchive" DEVELOPMENT_TEAM="$team" \
    -allowProvisioningUpdates -quiet archive

cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
# Re-signs with the Developer ID, a secure timestamp and no get-task-allow.
xcodebuild -exportArchive -archivePath "$work/ClangNotch.xcarchive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates -quiet
app="$work/export/ClangNotch.app"

ditto -c -k --keepParent "$app" "$work/ClangNotch.zip"
notarize "$work/ClangNotch.zip"
xcrun stapler staple -q "$app"

# Made in the work folder and moved out only once it passes, so a failed run never leaves
# an unnotarized image under the release's name.
image="$work/ClangNotch.dmg"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/ClangNotch.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname ClangNotch -srcfolder "$work/dmg" -format UDZO "$image" -quiet
codesign --sign "$identity_hash" --timestamp "$image"
notarize "$image"
xcrun stapler staple -q "$image"

spctl --assess --type execute -vv "$app"
spctl --assess --type open --context context:primary-signature -vv "$image"
mv -f "$image" "$OUT"
version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)
build=$(defaults read "$app/Contents/Info.plist" CFBundleVersion)
echo "Ready: $OUT ($version, build $build)"
