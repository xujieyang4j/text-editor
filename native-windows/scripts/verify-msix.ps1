param(
  [Parameter(Mandatory = $true)]
  [string]$PackagePath,
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'arm64')]
  [string]$Architecture,
  [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $nativeRoot
$package = [IO.Path]::GetFullPath($PackagePath)
if (-not (Test-Path -LiteralPath $package -PathType Leaf)) { throw "MSIX does not exist: $package" }
if ((Get-Item -LiteralPath $package).Length -le 0) { throw "MSIX is empty: $package" }

function Get-PeMachine([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Executable is not a PE image: $Path" }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0x40 -or $peOffset -gt $stream.Length - 6) { throw "Executable has an invalid PE header: $Path" }
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw "Executable has an invalid PE signature: $Path" }
    return $reader.ReadUInt16()
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

$makeAppxCommand = Get-Command makeappx.exe -ErrorAction SilentlyContinue
$makeAppx = if ($makeAppxCommand) { $makeAppxCommand.Source } else { $null }
if (-not $makeAppx) {
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  $makeAppx = Get-ChildItem (Join-Path $programFilesX86 'Windows Kits\10\bin') -Recurse -Filter makeappx.exe |
    Where-Object { $_.Directory.Name -eq 'x64' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $makeAppx) { throw 'makeappx.exe was not found.' }

$unpack = Join-Path ([IO.Path]::GetTempPath()) "lumen-native-msix-verify-$([Guid]::NewGuid().ToString('N'))"
try {
  & $makeAppx unpack /p $package /d $unpack /o | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "makeappx could not unpack $package" }
  $manifestPath = Join-Path $unpack 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'MSIX has no AppxManifest.xml.' }
  [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
  $identity = $manifest.Package.Identity
  if ([string]$identity.Name -ne 'com.lumen.editor.native-preview.windows') { throw 'MSIX package identity is incorrect.' }
  if ([string]$identity.ProcessorArchitecture -ne $Architecture) {
    throw "MSIX architecture is $($identity.ProcessorArchitecture), expected $Architecture."
  }
  $packageVersion = [string]((Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json).version)
  $expectedVersion = "$packageVersion.0"
  if ([string]$identity.Version -ne $expectedVersion) {
    throw "MSIX version $($identity.Version) does not match package.json version $expectedVersion."
  }
  $namespace = New-Object Xml.XmlNamespaceManager($manifest.NameTable)
  $namespace.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
  $namespace.AddNamespace('rescap', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities')
  $associations = @($manifest.SelectNodes('//uap:FileType', $namespace))
  if ($associations.Count -ne 81) { throw "MSIX contains $($associations.Count) file associations, expected 81." }
  if (-not $manifest.SelectSingleNode('//rescap:Capability[@Name="runFullTrust"]', $namespace)) {
    throw 'MSIX is missing the runFullTrust capability required by native tooling.'
  }
  foreach ($asset in 'StoreLogo.png', 'Square44x44Logo.png', 'Square150x150Logo.png', 'Wide310x150Logo.png') {
    if (-not (Test-Path -LiteralPath (Join-Path $unpack "Assets/$asset") -PathType Leaf)) {
      throw "MSIX is missing Assets/$asset."
    }
  }
  $expectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
  $appExecutable = Join-Path $unpack 'LumenEditor.Windows.App.exe'
  if (-not (Test-Path -LiteralPath $appExecutable -PathType Leaf)
      -or (Get-Item -LiteralPath $appExecutable).Length -le 0) {
    throw 'MSIX is missing the native application executable.'
  }
  if ((Get-PeMachine $appExecutable) -ne $expectedMachine) {
    throw "MSIX application executable architecture does not match $Architecture."
  }
  $workerExecutables = @(Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter 'LumenEditor.Windows.Worker.exe')
  if ($workerExecutables.Count -ne 1) {
    throw "MSIX contains $($workerExecutables.Count) isolated worker executables; expected exactly one."
  }
  $workerExecutable = Join-Path $unpack 'LumenEditor.Windows.Worker.exe'
  $resolvedWorkerExecutable = [IO.Path]::GetFullPath($workerExecutables[0].FullName)
  $expectedWorkerExecutable = [IO.Path]::GetFullPath($workerExecutable)
  if (-not $resolvedWorkerExecutable.Equals(
      $expectedWorkerExecutable, [StringComparison]::OrdinalIgnoreCase)
      -or $workerExecutables[0].Length -le 0) {
    throw 'MSIX isolated worker executable must be non-empty and located at the package root.'
  }
  if ((Get-PeMachine $workerExecutable) -ne $expectedMachine) {
    throw "MSIX worker executable architecture does not match $Architecture."
  }
  if (-not (Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter 'Jint.dll')) {
    throw 'MSIX is missing the isolated worker JavaScript runtime.'
  }
  if (-not (Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter 'Markdig.dll')) {
    throw 'MSIX is missing the safe Markdown rendering runtime.'
  }
  $parserBundles = @(Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter 'CodeMirrorParserBundle.js')
  if ($parserBundles.Count -ne 1) {
    throw "MSIX contains $($parserBundles.Count) CodeMirror parser bundles; expected exactly one."
  }
  $parserBundle = $parserBundles[0]
  if ($parserBundle.Length -le 0 -or $parserBundle.Length -gt 8MB) {
    throw 'MSIX is missing the bounded CodeMirror parser bundle.'
  }
  $expectedParserBundle = Join-Path $repoRoot 'native-macos/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js'
  $packagedParserHash = (Get-FileHash -LiteralPath $parserBundle.FullName -Algorithm SHA256).Hash
  $expectedParserHash = (Get-FileHash -LiteralPath $expectedParserBundle -Algorithm SHA256).Hash
  if ($packagedParserHash -ne $expectedParserHash) {
    throw 'MSIX CodeMirror parser bundle does not match the frozen shared resource.'
  }
  Write-Host "Verified $Architecture MSIX identity, application/worker PE architecture, parser bundle, assets, and 81 file associations."
  if ($RequireSignature) {
    $signToolCommand = Get-Command signtool.exe -ErrorAction SilentlyContinue
    $signTool = if ($signToolCommand) { $signToolCommand.Source } else { $null }
    if (-not $signTool) {
      $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
      $signTool = Get-ChildItem (Join-Path $programFilesX86 'Windows Kits\10\bin') -Recurse -Filter signtool.exe |
        Where-Object { $_.Directory.Name -eq 'x64' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signTool) { throw 'signtool.exe was not found.' }
    & $signTool verify /pa /all /v $package
    if ($LASTEXITCODE -ne 0) { throw "MSIX signature verification failed: $package" }
  }
} finally {
  if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
}
