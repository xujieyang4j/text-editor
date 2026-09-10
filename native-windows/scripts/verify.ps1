$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $nativeRoot

Push-Location $repoRoot
try {
  npm run check:native-windows
  dotnet test "$nativeRoot/tests/LumenEditor.Windows.Core.Tests/LumenEditor.Windows.Core.Tests.csproj" --configuration Release -p:TreatWarningsAsErrors=true
  $workerPublish = Join-Path ([IO.Path]::GetTempPath()) "lumen-native-worker-verify-$([Guid]::NewGuid().ToString('N'))"
  dotnet publish "$nativeRoot/src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj" `
    --configuration Release --runtime win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:CopyLocalLockFileAssemblies=true `
    -p:TreatWarningsAsErrors=true -o $workerPublish
  dotnet build "$nativeRoot/src/LumenEditor.Windows.App/LumenEditor.Windows.App.csproj" `
    --configuration Release --runtime win-x64 -p:Platform=x64 -p:PlatformTarget=x64 `
    -p:TreatWarningsAsErrors=true "-p:LumenWorkerPublishDir=$workerPublish"
  & "$PSScriptRoot/test-plugin-worker.ps1"
  & "$PSScriptRoot/test-parser-worker.ps1"
} finally {
  if ($workerPublish -and (Test-Path -LiteralPath $workerPublish)) {
    Remove-Item -LiteralPath $workerPublish -Recurse -Force
  }
  Pop-Location
}
