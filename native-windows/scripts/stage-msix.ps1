param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'arm64')]
  [string]$Architecture,
  [string]$SourceDirectory = '',
  [string]$DestinationDirectory = ''
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $nativeRoot
$version = [string]((Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json).version)
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) { $SourceDirectory = Join-Path $nativeRoot "artifacts/$Architecture" }
if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) { $DestinationDirectory = Join-Path $repoRoot "release/$version" }
$name = "text-editor-xujieyang-$version-native-windows-$Architecture.msix"
$source = Join-Path ([IO.Path]::GetFullPath($SourceDirectory)) $name
$destination = Join-Path ([IO.Path]::GetFullPath($DestinationDirectory)) $name
if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -le 0) {
  throw "Missing non-empty native Windows package: $source"
}
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
Copy-Item -LiteralPath $source -Destination $destination -Force
Write-Host "Staged $destination"
