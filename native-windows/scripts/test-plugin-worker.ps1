param(
  [string]$Configuration = 'Release',
  [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $nativeRoot 'src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj'
$publish = Join-Path ([IO.Path]::GetTempPath()) "lumen-plugin-worker-smoke-$([Guid]::NewGuid().ToString('N'))"
try {
  dotnet publish $project --configuration $Configuration --runtime $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:CopyLocalLockFileAssemblies=true `
    -p:TreatWarningsAsErrors=true -o $publish
  if ($LASTEXITCODE -ne 0) { throw 'Plugin worker smoke publish failed.' }
  $executable = Join-Path $publish 'LumenEditor.Windows.Worker.exe'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Plugin worker executable is missing.' }
  $source = "self.onmessage=function(e){if(e.data.type==='activate')postMessage({type:'register-command',id:'hello',title:'Hello'});if(e.data.type==='run-command')postMessage({type:'notify',text:e.data.id});}"
  $bytes = [Text.Encoding]::UTF8.GetBytes($source)
  $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($bytes))
  $permissions = '[]'
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($executable)
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardInput = $true
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  foreach ($argument in '--plugin-worker', 'smoke-worker', "sha256-$hash", $permissions) {
    $process.StartInfo.ArgumentList.Add($argument)
  }
  if (-not $process.Start()) { throw 'Plugin worker process did not start.' }
  $requests = @(
    @{ version = 1; type = 'load'; requestId = 'load'; source = $source; sourceIntegrity = "sha256-$hash" },
    @{ version = 1; type = 'activate'; requestId = 'activate'; context = @{ permissions = @() } },
    @{ version = 1; type = 'run-command'; requestId = 'run'; commandId = 'hello'; context = @{ permissions = @() } },
    @{ version = 1; type = 'deactivate'; requestId = 'deactivate'; context = @{ permissions = @() } }
  )
  foreach ($request in $requests) {
    $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
    $process.StandardInput.Flush()
    $messages = @()
    do {
      $line = $process.StandardOutput.ReadLine()
      if ($null -eq $line) { throw "Plugin worker exited early: $($process.StandardError.ReadToEnd())" }
      $response = $line | ConvertFrom-Json
      if ($response.requestId -ne $request.requestId) { throw 'Plugin worker response ID mismatch.' }
      $messages += $response
    } while ($response.type -ne 'completed')
    if ($request.type -eq 'activate' -and -not ($messages | Where-Object type -eq 'register-command')) {
      throw 'Plugin worker did not register its dynamic command.'
    }
    if ($request.type -eq 'run-command' -and -not ($messages | Where-Object { $_.type -eq 'notify' -and $_.text -eq 'hello' })) {
      throw 'Plugin worker command did not return its expected notification.'
    }
  }
  if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Plugin worker did not exit cleanly.' }
  Write-Host 'Plugin worker process smoke passed.'
} finally {
  if ($process) {
    try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
    $process.Dispose()
  }
  if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
}
