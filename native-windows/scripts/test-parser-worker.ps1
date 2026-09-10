param(
  [string]$Configuration = 'Release',
  [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $nativeRoot 'src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj'
$publish = Join-Path ([IO.Path]::GetTempPath()) "lumen-parser-worker-smoke-$([Guid]::NewGuid().ToString('N'))"
$process = $null
try {
  dotnet publish $project --configuration $Configuration --runtime $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:CopyLocalLockFileAssemblies=true `
    -p:TreatWarningsAsErrors=true -o $publish
  if ($LASTEXITCODE -ne 0) { throw 'Parser worker smoke publish failed.' }
  $executable = Join-Path $publish 'LumenEditor.Windows.Worker.exe'
  $repoRoot = Split-Path -Parent $nativeRoot
  $bundle = Join-Path $repoRoot 'native-macos/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Parser worker executable is missing.' }
  if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) { throw 'Parser worker bundle is missing.' }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($executable)
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardInput = $true
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $process.StartInfo.ArgumentList.Add('--parser-worker')
  $process.StartInfo.ArgumentList.Add($bundle)
  if (-not $process.Start()) { throw 'Parser worker process did not start.' }
  $text = "😀 function demo(value) {`nreturn (value + 1)`n}`n"
  $request = @{
    version = 2; requestId = 'parse'; text = $text; language = 'javascript'
    tabWidth = 4; indentWidth = 2; insertSpaces = $true; newlineIndentationPositions = @(24)
  }
  $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
  $process.StandardInput.Flush()
  $line = $process.StandardOutput.ReadLine()
  if ($null -eq $line) { throw "Parser worker exited early: $($process.StandardError.ReadToEnd())" }
  $response = $line | ConvertFrom-Json
  if ($response.version -ne 2 -or $response.requestId -ne 'parse' -or $response.error) {
    throw 'Parser worker returned an invalid response envelope.'
  }
  if (-not $response.result.supported -or $response.result.parserKind -ne 'lezer') {
    throw 'Parser worker did not resolve JavaScript with Lezer.'
  }
  if (@($response.result.highlights).Count -eq 0 -or @($response.result.syntaxNodes).Count -eq 0) {
    throw 'Parser worker response did not contain parser highlights and syntax nodes.'
  }
  if (@($response.result.bracketPairs).Count -eq 0 -or @($response.result.symbols).Count -eq 0) {
    throw 'Parser worker response did not contain parser structure and symbols.'
  }
  if (@($response.result.newlineIndentation).Count -ne 1) {
    throw 'Parser worker response did not contain the requested newline indentation probe.'
  }
  $process.StandardInput.Close()
  if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
    throw "Parser worker did not exit cleanly: $($process.StandardError.ReadToEnd())"
  }
  Write-Host 'Parser worker process smoke passed.'
} finally {
  if ($process) {
    try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
    $process.Dispose()
  }
  if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
}
