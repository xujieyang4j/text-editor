#!/usr/bin/env bash
set -euo pipefail

# Run this script with bash; its array-free implementation also keeps the
# release invocation portable across the older Bash shipped with macOS.

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$native_root/.." && pwd)"
version="${VERSION:?VERSION is required}"
architecture="${ARCHITECTURE:?ARCHITECTURE must be arm64 or x64}"
build_number="${BUILD_NUMBER:?BUILD_NUMBER is required}"
output="${OUTPUT_DIR:-$repo_root/release/$version}"
parser_bundle="$native_root/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"

verify_boolean_entitlement_allowlist() {
  local target="$1"
  local label="$2"
  shift 2
  local entitlements

  entitlements="$(codesign --display --entitlements :- "$target" 2>/dev/null)"
  python3 -c '
import plistlib
import sys

label = sys.argv[1]
expected = set(sys.argv[2:])
try:
    payload = plistlib.loads(sys.stdin.buffer.read())
except Exception as error:
    sys.stderr.write(f"Could not parse {label} entitlements: {error}\n")
    raise SystemExit(1)
if type(payload) is not dict:
    sys.stderr.write(f"Expected {label} entitlements to be a dictionary.\n")
    raise SystemExit(1)
actual = set(payload)
if actual != expected:
    missing = ", ".join(sorted(expected - actual)) or "none"
    unexpected = ", ".join(sorted(actual - expected)) or "none"
    sys.stderr.write(
        f"Unexpected {label} entitlement keys; missing: {missing}; "
        f"unexpected: {unexpected}.\n"
    )
    raise SystemExit(1)
invalid = sorted(key for key in expected if payload[key] is not True)
if invalid:
    joined = ", ".join(invalid)
    sys.stderr.write(
        f"Expected boolean true for {label} entitlements: {joined}.\n"
    )
    raise SystemExit(1)
' "$label" "$@" <<<"$entitlements"
}

run_packaged_parser_smoke() {
  local executable="$1"
  python3 "$script_dir/run-packaged-parser-smoke.py" "$executable"
}

verify_bundle_resources() {
  local localization

  test -s "$contents/Resources/AppIcon.icns"
  cmp -s "$icon" "$contents/Resources/AppIcon.icns"
  test -s "$contents/Resources/CodeMirrorParserBundle.js"
  cmp -s "$parser_bundle" "$contents/Resources/CodeMirrorParserBundle.js"
  for localization in en.lproj zh_CN.lproj; do
    test -s "$contents/Resources/$localization/InfoPlist.strings"
    cmp -s \
      "$native_root/Packaging/$localization/InfoPlist.strings" \
      "$contents/Resources/$localization/InfoPlist.strings"
  done
}

case "$architecture" in
  arm64) swift_arch=arm64 ;;
  x64) swift_arch=x86_64 ;;
  *) echo "ARCHITECTURE must be arm64 or x64" >&2; exit 2 ;;
esac

case "$build_number" in
  ''|*[!0-9]*) echo "BUILD_NUMBER must contain only decimal digits" >&2; exit 2 ;;
esac

identity="${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required}"
signing_keychain="${CSC_KEYCHAIN:?CSC_KEYCHAIN is required}"
test -f "$signing_keychain"

plist_version="$(plutil -extract CFBundleShortVersionString raw -o - "$native_root/Packaging/Info.plist")"
if [[ "$plist_version" != "$version" ]]; then
  echo "Info.plist version $plist_version does not match release version $version." >&2
  exit 1
fi

# Fail before any product build or bundle copy if the committed parser resource
# no longer matches its source and locked JavaScript dependencies.
(cd "$repo_root" && npm run check:native-parser)

cd "$native_root"
swift build -c release --arch "$swift_arch" --product LumenEditor
swift build -c release --arch "$swift_arch" --product LumenPluginWorker
swift build -c release --arch "$swift_arch" --product LumenParserWorker
binary_dir="$(swift build -c release --arch "$swift_arch" --show-bin-path)"
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/lumen-native-release.XXXXXX")"
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

app="$staging/Lumen Editor Native.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$output"
cp "$binary_dir/LumenEditor" "$contents/MacOS/LumenEditor"
cp "$binary_dir/LumenPluginWorker" "$contents/MacOS/LumenPluginWorker"
cp "$binary_dir/LumenParserWorker" "$contents/MacOS/LumenParserWorker"
cp "$native_root/Packaging/Info.plist" "$contents/Info.plist"
"$script_dir/copy-bundle-localization-resources.sh" "$contents/Resources"
test -s "$parser_bundle"
cp "$parser_bundle" "$contents/Resources/CodeMirrorParserBundle.js"
cmp -s "$parser_bundle" "$contents/Resources/CodeMirrorParserBundle.js"
plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
test "$(plutil -extract CFBundleVersion raw -o - "$contents/Info.plist")" = "$build_number"
icon="$repo_root/build/icon.icns"
test -s "$icon"
iconutil -c iconset "$icon" -o "$staging/AppIcon.iconset"
test -s "$staging/AppIcon.iconset/icon_512x512@2x.png"
cp "$icon" "$contents/Resources/AppIcon.icns"

verify_architecture() {
  local binary="$1"
  local architectures
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "$swift_arch" ]]; then
    echo "Expected $binary to contain only $swift_arch, found: $architectures" >&2
    exit 1
  fi
}

verify_architecture "$contents/MacOS/LumenEditor"
verify_architecture "$contents/MacOS/LumenPluginWorker"
verify_architecture "$contents/MacOS/LumenParserWorker"

codesign --force --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" \
  --entitlements "$native_root/Packaging/LumenPluginWorker.entitlements" \
  "$contents/MacOS/LumenPluginWorker"
codesign --force --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" \
  --entitlements "$native_root/Packaging/LumenParserWorker.entitlements" \
  "$contents/MacOS/LumenParserWorker"
codesign --force --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" \
  --entitlements "$native_root/Packaging/LumenEditor.entitlements" "$app"
codesign --verify --strict --verbose=2 "$contents/MacOS/LumenPluginWorker"
worker_signing="$(codesign --display --verbose=4 \
  "$contents/MacOS/LumenPluginWorker" 2>&1)"
grep -Fq "Authority=$identity" <<<"$worker_signing"
grep -q 'flags=.*runtime' <<<"$worker_signing"
verify_boolean_entitlement_allowlist \
  "$contents/MacOS/LumenPluginWorker" "LumenPluginWorker" \
  com.apple.security.app-sandbox com.apple.security.inherit
codesign --verify --strict --verbose=2 "$contents/MacOS/LumenParserWorker"
parser_signing="$(codesign --display --verbose=4 \
  "$contents/MacOS/LumenParserWorker" 2>&1)"
grep -Fq "Authority=$identity" <<<"$parser_signing"
grep -q 'flags=.*runtime' <<<"$parser_signing"
verify_boolean_entitlement_allowlist \
  "$contents/MacOS/LumenParserWorker" "LumenParserWorker" \
  com.apple.security.app-sandbox com.apple.security.inherit
codesign --verify --deep --strict --verbose=2 "$app"
app_signing="$(codesign --display --verbose=4 "$app" 2>&1)"
grep -Fq "Authority=$identity" <<<"$app_signing"
grep -q 'flags=.*runtime' <<<"$app_signing"
verify_boolean_entitlement_allowlist \
  "$app" "Lumen Editor Native.app" \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.network.client
verify_bundle_resources
run_packaged_parser_smoke "$contents/MacOS/LumenEditor"

notary_input="$staging/native-app-notary.zip"
ditto -c -k --keepParent "$app" "$notary_input"
xcrun notarytool submit "$notary_input" \
  --apple-id "${APPLE_ID:?APPLE_ID is required}" \
  --password "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}" \
  --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}" --wait
xcrun stapler staple "$app"

prefix="text-editor-xujieyang-$version-native-macos-$architecture"
dmg="$output/$prefix.dmg"
zip="$output/$prefix.zip"
hdiutil create -quiet -volname "Lumen Editor Native" -srcfolder "$app" \
  -format UDZO -ov "$dmg"
xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$dmg"
ditto -c -k --keepParent "$app" "$zip"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
test -x "$contents/MacOS/LumenPluginWorker"
test -x "$contents/MacOS/LumenParserWorker"
verify_bundle_resources
test -s "$dmg"
test -s "$zip"
