#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$native_root/.." && pwd)"
parser_bundle="$native_root/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"

# Keep direct local verification equivalent to CI and packaging entry points:
# reject a stale generated parser resource before compiling any Swift target.
(cd "$repo_root" && npm run check:native-parser)

cd "$native_root"
swift package describe >/dev/null
swift build --product LumenPluginWorker
swift build --product LumenParserWorker
binary_dir="$(swift build --show-bin-path)"
test -x "$binary_dir/LumenPluginWorker"
test -x "$binary_dir/LumenParserWorker"
LUMEN_PLUGIN_WORKER_EXECUTABLE="$binary_dir/LumenPluginWorker" \
LUMEN_PARSER_WORKER_EXECUTABLE="$binary_dir/LumenParserWorker" \
LUMEN_REQUIRE_WORKERS=1 swift test
swift build -c release -Xswiftc -warnings-as-errors
test -s "$parser_bundle"
test -s Packaging/en.lproj/InfoPlist.strings
test -s Packaging/zh_CN.lproj/InfoPlist.strings

if command -v plutil >/dev/null 2>&1; then
  plutil -lint Packaging/Info.plist
  plutil -lint Packaging/LumenEditor.entitlements
  plutil -lint Packaging/LumenPluginWorker.entitlements
  plutil -lint Packaging/LumenParserWorker.entitlements
  plutil -lint Packaging/en.lproj/InfoPlist.strings
  plutil -lint Packaging/zh_CN.lproj/InfoPlist.strings
fi

resource_check="$(mktemp -d "${TMPDIR:-/tmp}/lumen-native-resources.XXXXXX")"
trap 'rm -rf -- "$resource_check"' EXIT
"$script_dir/copy-bundle-localization-resources.sh" "$resource_check/Resources"
cmp -s \
  Packaging/en.lproj/InfoPlist.strings \
  "$resource_check/Resources/en.lproj/InfoPlist.strings"
cmp -s \
  Packaging/zh_CN.lproj/InfoPlist.strings \
  "$resource_check/Resources/zh_CN.lproj/InfoPlist.strings"

icon="$native_root/../build/icon.icns"
test -s "$icon"
iconutil -c iconset "$icon" -o "$resource_check/AppIcon.iconset"
test -s "$resource_check/AppIcon.iconset/icon_512x512@2x.png"
