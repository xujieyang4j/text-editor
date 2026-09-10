#!/usr/bin/env bash
set -euo pipefail

# Rebuilding into the same destination replaces only this exact app bundle so
# removed resources cannot survive from an earlier local build.

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$native_root/.." && pwd)"
configuration="${CONFIGURATION:-release}"
destination="${1:-$native_root/dist}"

case "$configuration" in
  debug|release) ;;
  *) echo "CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac

mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
if [[ "$destination" == / ]]; then
  echo "Refusing to build directly in the filesystem root." >&2
  exit 2
fi
app_path="$destination/Lumen Editor Native.app"
contents="$app_path/Contents"
parser_bundle="$native_root/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"

# Fail before any product build or bundle copy if the committed parser resource
# no longer matches its source and locked JavaScript dependencies.
(cd "$repo_root" && npm run check:native-parser)

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

cd "$native_root"
swift build -c "$configuration" --product LumenEditor
swift build -c "$configuration" --product LumenPluginWorker
swift build -c "$configuration" --product LumenParserWorker
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
test -x "$binary_dir/LumenEditor"
test -x "$binary_dir/LumenPluginWorker"
test -x "$binary_dir/LumenParserWorker"

if [[ -e "$app_path" || -L "$app_path" ]]; then
  rm -rf -- "$app_path"
fi
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/LumenEditor" "$contents/MacOS/LumenEditor"
cp "$binary_dir/LumenPluginWorker" "$contents/MacOS/LumenPluginWorker"
cp "$binary_dir/LumenParserWorker" "$contents/MacOS/LumenParserWorker"
cp "$native_root/Packaging/Info.plist" "$contents/Info.plist"
"$script_dir/copy-bundle-localization-resources.sh" "$contents/Resources"
test -s "$parser_bundle"
cp "$parser_bundle" "$contents/Resources/CodeMirrorParserBundle.js"
cmp -s "$parser_bundle" "$contents/Resources/CodeMirrorParserBundle.js"
icon="$repo_root/build/icon.icns"
test -s "$icon"
icon_check="$(mktemp -d "${TMPDIR:-/tmp}/lumen-native-icon.XXXXXX")"
trap 'rm -rf -- "$icon_check"' EXIT
iconutil -c iconset "$icon" -o "$icon_check/AppIcon.iconset"
test -s "$icon_check/AppIcon.iconset/icon_512x512@2x.png"
cp "$icon" "$contents/Resources/AppIcon.icns"

codesign --force --sign - \
  --entitlements "$native_root/Packaging/LumenPluginWorker.entitlements" \
  "$contents/MacOS/LumenPluginWorker"
codesign --force --sign - \
  --entitlements "$native_root/Packaging/LumenParserWorker.entitlements" \
  "$contents/MacOS/LumenParserWorker"
codesign --force --sign - \
  --entitlements "$native_root/Packaging/LumenEditor.entitlements" \
  "$app_path"
codesign --verify --strict "$contents/MacOS/LumenPluginWorker"
verify_boolean_entitlement_allowlist \
  "$contents/MacOS/LumenPluginWorker" "LumenPluginWorker" \
  com.apple.security.app-sandbox com.apple.security.inherit
codesign --verify --strict "$contents/MacOS/LumenParserWorker"
verify_boolean_entitlement_allowlist \
  "$contents/MacOS/LumenParserWorker" "LumenParserWorker" \
  com.apple.security.app-sandbox com.apple.security.inherit
codesign --verify --deep --strict "$app_path"
verify_boolean_entitlement_allowlist \
  "$app_path" "Lumen Editor Native.app" \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.network.client
test -x "$contents/MacOS/LumenPluginWorker"
test -x "$contents/MacOS/LumenParserWorker"
verify_bundle_resources
run_packaged_parser_smoke "$contents/MacOS/LumenEditor"
echo "Built $app_path"
