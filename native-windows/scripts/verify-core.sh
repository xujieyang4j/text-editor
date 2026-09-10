#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -L)"
native_root="$(cd "$script_dir/.." && pwd -L)"
repo_root="$(cd "$native_root/.." && pwd -L)"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet SDK 8 is required to test the Windows native Core project." >&2
  exit 127
fi

cd "$repo_root"
npm run check:native-windows
artifacts_path="$(mktemp -d "${TMPDIR:-/tmp}/lumen-native-windows-verify.XXXXXX")"
cleanup() {
  rm -rf -- "$artifacts_path"
}
trap cleanup EXIT INT TERM
dotnet test "$native_root/tests/LumenEditor.Windows.Core.Tests/LumenEditor.Windows.Core.Tests.csproj" \
  --configuration Release --artifacts-path "$artifacts_path" \
  -p:TreatWarningsAsErrors=true -p:CopyLocalLockFileAssemblies=true
dotnet build "$native_root/src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj" \
  --configuration Release --artifacts-path "$artifacts_path" -p:TreatWarningsAsErrors=true
if [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]]; then
  worker_publish="$artifacts_path/worker-publish"
  dotnet publish "$native_root/src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj" \
    --configuration Release --runtime linux-x64 --self-contained true \
    --artifacts-path "$artifacts_path/worker-smoke-artifacts" \
    -p:PublishSingleFile=true -p:CopyLocalLockFileAssemblies=true \
    -p:TreatWarningsAsErrors=true --output "$worker_publish"
  node "$native_root/scripts/test-worker-process.mjs" \
    "$worker_publish/LumenEditor.Windows.Worker" \
    "$repo_root/native-macos/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"
fi
if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* && "$(uname -s)" != CYGWIN* ]]; then
  dotnet build "$native_root/src/LumenEditor.Windows.App/LumenEditor.Windows.App.csproj" \
    --configuration Release --artifacts-path "$artifacts_path" \
    -p:TreatWarningsAsErrors=true -p:EnableWindowsTargeting=true -p:LumenXamlStubBuild=true
fi
